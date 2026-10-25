//! Fluids around a body: contacts and depths (vanilla's
//! `updateFluidHeightAndDoFluidPushing` scan), the eye test, the flow vector
//! of one fluid cell (`FlowingFluid.getFlow`) and the current a body's
//! contacts push it with.

use super::aabb::Aabb;
use super::facts::{Facts, Fluid, EMPTY, LAVA, WATER};
use super::source::{BlockSource, Unreadable};

const INSET: f64 = 0.001;

#[inline]
fn f32r(v: f64) -> f64 {
    v as f32 as f64
}

fn fluid_at<'f>(
    source: &dyn BlockSource,
    facts: &'f Facts,
    p: [i32; 3],
) -> Result<(u16, &'f Fluid), Unreadable> {
    let state = source.state(p[0], p[1], p[2]).ok_or(Unreadable(p))?;
    Ok((state, facts.fluid(state)))
}

/// One cell of fluid a body touches, and how deep it reaches into the body.
#[derive(Clone, Copy, Debug)]
pub struct Contact {
    pub position: [i32; 3],
    pub fluid: Fluid,
    pub depth: f64,
}

/// The cells a body scan covers, in vanilla's order (x, then y, then z).
fn positions(b: &Aabb, inset: f64) -> Option<Vec<[i32; 3]>> {
    if !(b.max[0] - b.min[0] > 2.0 * inset
        && b.max[1] - b.min[1] > 2.0 * inset
        && b.max[2] - b.min[2] > 2.0 * inset)
    {
        return None;
    }
    let lo: [i32; 3] = std::array::from_fn(|i| (b.min[i] + inset).floor() as i32);
    let hi: [i32; 3] = std::array::from_fn(|i| (b.max[i] - inset).ceil() as i32 - 1);
    let mut out = Vec::new();
    for x in lo[0]..=hi[0] {
        for y in lo[1]..=hi[1] {
            for z in lo[2]..=hi[2] {
                out.push([x, y, z]);
            }
        }
    }
    Some(out)
}

/// The height of a fluid cell's surface: full under the same fluid.
fn surface(
    source: &dyn BlockSource,
    facts: &Facts,
    p: [i32; 3],
    fluid: &Fluid,
) -> Result<f64, Unreadable> {
    if fluid.kind == EMPTY {
        return Ok(0.0);
    }
    let (_, above) = fluid_at(source, facts, [p[0], p[1] + 1, p[2]])?;
    Ok(if above.kind == fluid.kind {
        1.0
    } else {
        fluid.height as f64
    })
}

/// The fluid cells whose surface reaches the body's bottom (plus the inset),
/// in scan order. `None` for a degenerate body.
pub fn contacts(
    source: &dyn BlockSource,
    facts: &Facts,
    body: &Aabb,
) -> Result<Option<Vec<Contact>>, Unreadable> {
    let Some(cells) = positions(body, INSET) else {
        return Ok(None);
    };
    let mut out = Vec::new();
    for p in cells {
        let (_, fluid) = fluid_at(source, facts, p)?;
        let top = surface(source, facts, p, fluid)?;
        if fluid.kind != EMPTY && p[1] as f64 + top >= body.min[1] + INSET {
            out.push(Contact {
                position: p,
                fluid: *fluid,
                depth: p[1] as f64 + top - body.min[1],
            });
        }
    }
    Ok(Some(out))
}

/// Depths of water and lava over the body.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Depths {
    pub water: f64,
    pub lava: f64,
}

pub fn depths(contacts: &[Contact]) -> Depths {
    let mut d = Depths::default();
    for c in contacts {
        match c.fluid.kind {
            WATER => d.water = d.water.max(c.depth),
            LAVA => d.lava = d.lava.max(c.depth),
            _ => {}
        }
    }
    d
}

/// Whether the eye at `eye` is under water and lava: a source under a sturdy
/// downward face fills its cell.
pub fn eyes(
    source: &dyn BlockSource,
    facts: &Facts,
    body: &Aabb,
    eye: [f64; 3],
) -> Result<Option<(bool, bool)>, Unreadable> {
    let Some(found) = contacts(source, facts, body)? else {
        return Ok(None);
    };
    eyes_in(source, facts, &found, eye).map(Some)
}

/// Eye immersion from the body's already observed fluid contacts. A mob's
/// pre-AI sample needs both depths and eyes over the same immutable view.
pub fn eyes_in(
    source: &dyn BlockSource,
    facts: &Facts,
    found: &[Contact],
    eye: [f64; 3],
) -> Result<(bool, bool), Unreadable> {
    let column = (eye[0].floor() as i32, eye[2].floor() as i32);
    let (mut water, mut lava) = (false, false);
    for c in found {
        let [px, py, pz] = c.position;
        if (px, pz) != column || eye[1] < py as f64 {
            continue;
        }
        let height = if c.fluid.source && sturdy(source, facts, [px, py + 1, pz], 0)? {
            1.0
        } else {
            surface(source, facts, c.position, &c.fluid)?
        };
        let under = eye[1] <= py as f64 + height;
        match c.fluid.kind {
            WATER => water |= under,
            LAVA => lava |= under,
            _ => {}
        }
    }
    Ok((water, lava))
}

/// Whether any cell of the body (no inset) holds fluid.
pub fn any_liquid(
    source: &dyn BlockSource,
    facts: &Facts,
    body: &Aabb,
) -> Result<Option<bool>, Unreadable> {
    let Some(cells) = positions(body, 0.0) else {
        return Ok(None);
    };
    for p in cells {
        if fluid_at(source, facts, p)?.1.kind != EMPTY {
            return Ok(Some(true));
        }
    }
    Ok(Some(false))
}

/// `isFaceSturdy` for flow and eyes; without block entities a piston's faces
/// are not sturdy and a shulker box's are.
pub fn sturdy(
    source: &dyn BlockSource,
    facts: &Facts,
    p: [i32; 3],
    direction: usize,
) -> Result<bool, Unreadable> {
    let state = source.state(p[0], p[1], p[2]).ok_or(Unreadable(p))?;
    Ok(match facts.boundary(state).context {
        1 => false,
        2 => true,
        _ => facts.sturdy(state, direction),
    })
}

/// North, east, south, west: offsets and their `Direction` ids.
const DIRECTIONS: [(i32, i32, usize); 4] = [(0, -1, 2), (1, 0, 5), (0, 1, 3), (-1, 0, 4)];

pub fn normalize(v: [f64; 3]) -> [f64; 3] {
    let length = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    if length < 1.0e-5 {
        [0.0; 3]
    } else {
        [v[0] / length, v[1] / length, v[2] / length]
    }
}

/// The flow of the fluid at `p` (`FlowingFluid.getFlow`).
pub fn flow(source: &dyn BlockSource, facts: &Facts, p: [i32; 3]) -> Result<[f64; 3], Unreadable> {
    let (_, fluid) = fluid_at(source, facts, p)?;
    if fluid.kind == EMPTY {
        return Ok([0.0; 3]);
    }
    let own = fluid.height;
    let (mut vx, mut vz) = (0.0f64, 0.0f64);
    for (dx, dz, _) in DIRECTIONS {
        let n = [p[0] + dx, p[1], p[2] + dz];
        let (state, neighbor) = fluid_at(source, facts, n)?;
        let difference: f32 = if neighbor.kind != EMPTY && neighbor.kind != fluid.kind {
            0.0
        } else if neighbor.height > 0.0 {
            own - neighbor.height
        } else if facts.boundary(state).blocks_flow {
            0.0
        } else {
            let (_, below) = fluid_at(source, facts, [n[0], n[1] - 1, n[2]])?;
            if (below.kind == EMPTY || below.kind == fluid.kind) && below.height > 0.0 {
                own - (below.height - 0.8888889f32)
            } else {
                0.0
            }
        };
        vx += (dx as f32 * difference) as f64;
        vz += (dz as f32 * difference) as f64;
    }
    let mut falls = false;
    if fluid.falling {
        for (dx, dz, direction) in DIRECTIONS {
            let side = [p[0] + dx, p[1], p[2] + dz];
            if solid(source, facts, side, fluid, direction)?
                || solid(
                    source,
                    facts,
                    [side[0], side[1] + 1, side[2]],
                    fluid,
                    direction,
                )?
            {
                falls = true;
                break;
            }
        }
    }
    let [x, _, z] = if falls {
        normalize([vx, 0.0, vz])
    } else {
        [vx, 0.0, vz]
    };
    Ok(normalize([x, if falls { -6.0 } else { 0.0 }, z]))
}

fn solid(
    source: &dyn BlockSource,
    facts: &Facts,
    p: [i32; 3],
    fluid: &Fluid,
    direction: usize,
) -> Result<bool, Unreadable> {
    let (state, neighbor) = fluid_at(source, facts, p)?;
    if neighbor.kind == fluid.kind || facts.boundary(state).ice {
        return Ok(false);
    }
    sturdy(source, facts, p, direction)
}

/// Who a current pushes: players average their contacts' flows, items
/// normalize the sum.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Pushed {
    Player,
    Item,
}

#[derive(Clone, Copy, Debug, Default)]
struct Accumulator {
    height: f64,
    sum: [f64; 3],
    count: u32,
}

/// The current's effect on a body: its velocity after the push and the water
/// and lava depths (`updateFluidHeightAndDoFluidPushing`).
pub fn current(
    source: &dyn BlockSource,
    facts: &Facts,
    body: &Aabb,
    velocity: [f64; 3],
    pushed: bool,
    fast_lava: bool,
    kind: Pushed,
) -> Result<Option<(Depths, [f64; 3])>, Unreadable> {
    let Some(found) = contacts(source, facts, body)? else {
        return Ok(None);
    };
    let mut water = Accumulator::default();
    let mut lava = Accumulator::default();
    for c in &found {
        let acc = if c.fluid.kind == WATER {
            &mut water
        } else {
            &mut lava
        };
        let height = acc.height.max(c.depth);
        let mut f = if pushed {
            flow(source, facts, c.position)?
        } else {
            [0.0; 3]
        };
        if height < 0.4 {
            f = f.map(|v| v * height);
        }
        acc.height = height;
        acc.sum = [acc.sum[0] + f[0], acc.sum[1] + f[1], acc.sum[2] + f[2]];
        if pushed {
            acc.count += 1;
        }
    }
    let lava_factor = if fast_lava {
        0.007
    } else {
        0.0023333333333333335
    };
    let next = apply(
        apply(velocity, &water, 0.014, kind),
        &lava,
        lava_factor,
        kind,
    );
    Ok(Some((
        Depths {
            water: water.height,
            lava: lava.height,
        },
        next,
    )))
}

fn apply(velocity: [f64; 3], acc: &Accumulator, factor: f64, kind: Pushed) -> [f64; 3] {
    if acc.count == 0 {
        return velocity;
    }
    let [sx, sy, sz] = acc.sum;
    if sx * sx + sy * sy + sz * sz < 9.999999747378752e-6 {
        return velocity;
    }
    let current = match kind {
        Pushed::Item => normalize(acc.sum),
        Pushed::Player => acc.sum.map(|v| v * (1.0 / acc.count as f64)),
    };
    let mut push = current.map(|v| v * factor);
    let length = (push[0] * push[0] + push[1] * push[1] + push[2] * push[2]).sqrt();
    if velocity[0].abs() < 0.003 && velocity[2].abs() < 0.003 && length < 0.0045000000000000005 {
        push = normalize(push).map(|v| v * 0.0045000000000000005);
    }
    [
        velocity[0] + push[0],
        velocity[1] + push[1],
        velocity[2] + push[2],
    ]
}

#[allow(dead_code)]
fn round(v: f64) -> f64 {
    f32r(v)
}
