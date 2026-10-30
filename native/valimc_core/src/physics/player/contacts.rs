//! What the blocks a player is in or passes do to it: climbing contact,
//! slowing blocks (cobweb, berry bushes, powder snow), fire, lava and water
//! contact with the immediate block hazards, and powder snow occupancy.
//! Effects that need the player's living state (burning, damage) are
//! returned as observations for the owner to apply.

use super::paths::{Path, Visit, Visits, Walked};
use super::pose::{self, Dimensions};
use super::rules::{self, Stuck};
use super::Fault;
use crate::physics::aabb::Aabb;
use crate::physics::cells::CellSet;
use crate::physics::collide;
use crate::physics::facts::{Facts, Hazard, InsideKind, InsideShape, EMPTY, LAVA};
use crate::physics::source::BlockSource;
use crate::physics::sweep::collided_along;
use crate::physics::table::Context;

fn state(source: &dyn BlockSource, p: [i32; 3]) -> Result<u16, Fault> {
    source.state(p[0], p[1], p[2]).ok_or(Fault::Unreadable(p))
}

fn floor(p: [f64; 3]) -> [i32; 3] {
    p.map(|v| v.floor() as i32)
}

/// Whether the block at `p` lets a non-flying, non-spectating player climb
/// (an open trapdoor over a ladder facing the same way counts), and whether
/// it is scaffolding.
pub fn climb(
    source: &dyn BlockSource,
    facts: &Facts,
    p: [i32; 3],
    flying: bool,
    spectator: bool,
    gliding: bool,
) -> Result<(bool, bool), Fault> {
    if flying || spectator {
        return Ok((false, false));
    }
    let c = facts.player.climb(state(source, p)?);
    let climbing = if c.glide_through && gliding {
        false
    } else if c.climbable {
        true
    } else if c.trapdoor_open && (2..=5).contains(&c.trapdoor_facing) {
        let below = facts.player.climb(state(source, [p[0], p[1] - 1, p[2]])?);
        below.ladder_facing == c.trapdoor_facing
    } else {
        false
    };
    Ok((climbing, c.scaffolding))
}

/// The slowing kind of a state.
pub fn stuck(facts: &Facts, state: u16) -> Stuck {
    match facts.player.inside(state).kind {
        InsideKind::Cobweb => Stuck::Cobweb,
        InsideKind::BerryBush => Stuck::BerryBush,
        InsideKind::PowderSnow => Stuck::PowderSnow,
        _ => Stuck::None,
    }
}

/// The last slowing block a tick's paths met.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Slowed {
    pub position: [i32; 3],
    pub state: u16,
    pub multiplier: [f64; 3],
}

/// What a body's slowing contacts set: the last block's multiplier, which
/// also resets the fall distance, and whether it was inside powder snow
/// (`setIsInPowderSnow`).
pub struct Slowing {
    pub multiplier: Option<[f64; 3]>,
    pub last: Option<Slowed>,
    pub powder_snow: bool,
}

/// Facts about the body that a contact sample needs.
#[derive(Clone, Copy, Debug)]
pub struct Body {
    pub pose: u8,
    pub feet: [f64; 3],
    pub flying: bool,
    pub spectator: bool,
    pub weaving: bool,
}

/// The slowing blocks met along `paths` in order (`checkInsideBlocks` for
/// cobwebs, berry bushes and powder snow).
pub fn slowing(
    source: &dyn BlockSource,
    facts: &Facts,
    catalog: &[Dimensions],
    paths: &[Path],
    ctx: &Context,
    b: &Body,
) -> Result<Slowing, Fault> {
    slowing_walked(source, facts, catalog, paths, &Walked::new(), ctx, b)
}

/// `slowing` over the visits `walked` keeps for the paths (walked on first
/// use), which the tick's other contact rules share.
pub fn slowing_walked(
    source: &dyn BlockSource,
    facts: &Facts,
    catalog: &[Dimensions],
    paths: &[Path],
    walked: &Walked,
    ctx: &Context,
    b: &Body,
) -> Result<Slowing, Fault> {
    if b.flying || b.spectator || paths.is_empty() {
        return Ok(Slowing {
            multiplier: None,
            last: None,
            powder_snow: false,
        });
    }
    pose::geometry(catalog, b.pose, b.feet)?;
    let feet = stuck(facts, state(source, floor(b.feet))?);
    let mut ctx = *ctx;
    let mut seen = CellSet::new();
    let mut last: Option<Slowed> = None;
    let mut powder_snow = false;
    let visits = walked.get_or_init(|| Visits::walk(catalog, paths, b.pose));
    visits.replay(&mut |v: &Visit| {
        if seen.contains(&v.position) {
            return Ok(());
        }
        let s = state(source, v.position)?;
        let kind = stuck(facts, s);
        let hit = match kind {
            Stuck::None => false,
            Stuck::Cobweb | Stuck::BerryBush => true,
            Stuck::PowderSnow => {
                collide::inside_shape(&facts.shapes, s, v.position, &ctx, &v.body, v.delta)
            }
        };
        let multiplier = rules::player_contact(
            if hit { kind } else { Stuck::None },
            b.weaving,
            feet == Stuck::PowderSnow,
            false,
        );
        if hit {
            seen.insert(v.position);
            powder_snow |= kind == Stuck::PowderSnow;
        }
        if let Some(m) = multiplier {
            last = Some(Slowed {
                position: v.position,
                state: s,
                multiplier: m,
            });
            ctx.fall_distance = 0.0;
        }
        Ok(())
    })?;
    Ok(Slowing {
        multiplier: last.map(|l| l.multiplier),
        last,
        powder_snow,
    })
}

/// A contact the burning rules order: fire, soul fire, powder snow, lava or
/// water.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Contact {
    Fire,
    SoulFire,
    PowderSnow,
    Lava,
    Water,
}

/// A hazard's damage source.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    HotFloor,
    Campfire,
    Cactus,
    SweetBerryBush,
}

/// What a player's paths touched: immediate damage in order, the contacts
/// grouped by crossing step (for the burning rules), and whether any of it
/// keeps acting.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Touched {
    pub immediate: Vec<(Source, f64)>,
    pub steps: Vec<Vec<Contact>>,
    pub active: bool,
}

/// `BlockBehaviour.entityInside` hazards for a player: magma (unless
/// careful), lit campfires, cactus, and grown berry bushes while moving.
pub fn hazard(
    facts: &Facts,
    state: u16,
    careful: bool,
    movement: [f64; 3],
) -> Option<(Source, f64)> {
    const THRESHOLD: f64 = 0.003000000026077032;
    match facts.player.hazard(state)? {
        Hazard::Magma if !careful => Some((Source::HotFloor, 1.0)),
        Hazard::Campfire(amount) if amount > 0.0 => Some((Source::Campfire, amount)),
        Hazard::Cactus => Some((Source::Cactus, 1.0)),
        Hazard::Berry(age) if age > 0 => (movement[0].abs() >= THRESHOLD
            || movement[2].abs() >= THRESHOLD)
            .then_some((Source::SweetBerryBush, 1.0)),
        _ => None,
    }
}

/// Facts about the player a contact sample needs beyond its body.
#[derive(Clone, Copy, Debug)]
pub struct Toucher {
    pub body: Body,
    pub grounded: bool,
    pub careful: bool,
    pub known_movement: [f64; 3],
    pub support_state: u16,
}

fn fluid_hit(
    source: &dyn BlockSource,
    facts: &Facts,
    s: u16,
    p: [i32; 3],
    body: &Aabb,
    delta: [f64; 3],
) -> Result<Option<Contact>, Fault> {
    let fluid = facts.fluid(s);
    if fluid.kind == EMPTY {
        return Ok(None);
    }
    let above = facts.fluid(state(source, [p[0], p[1] + 1, p[2]])?);
    let height = if above.kind == fluid.kind {
        1.0
    } else {
        fluid.height as f64
    };
    let (x, y, z) = (p[0] as f64, p[1] as f64, p[2] as f64);
    let cell = Aabb {
        min: [x, y, z],
        max: [x + 1.0, y + height, z + 1.0],
    };
    Ok(
        collided_along(body, delta, &[cell]).then_some(if fluid.kind == LAVA {
            Contact::Lava
        } else {
            Contact::Water
        }),
    )
}

/// The fire, fluid and hazard contacts along `paths` in order
/// (`checkInsideBlocks` and `stepOn`'s support hazard).
pub fn touched(
    source: &dyn BlockSource,
    facts: &Facts,
    catalog: &[Dimensions],
    paths: &[Path],
    ctx: &Context,
    t: &Toucher,
) -> Result<Touched, Fault> {
    touched_walked(source, facts, catalog, paths, &Walked::new(), ctx, t)
}

/// `touched` over the visits `walked` keeps for the paths (walked on first
/// use).
pub fn touched_walked(
    source: &dyn BlockSource,
    facts: &Facts,
    catalog: &[Dimensions],
    paths: &[Path],
    walked: &Walked,
    ctx: &Context,
    t: &Toucher,
) -> Result<Touched, Fault> {
    let b = &t.body;
    if b.spectator || paths.is_empty() {
        return Ok(Touched::default());
    }
    pose::geometry(catalog, b.pose, b.feet)?;
    let feet = stuck(facts, state(source, floor(b.feet))?);
    let support = hazard(facts, t.support_state, t.careful, t.known_movement);
    let hot = t.grounded && matches!(support, Some((Source::HotFloor, _)));
    let mut out = Touched {
        immediate: if hot {
            vec![support.expect("hot floor")]
        } else {
            Vec::new()
        },
        steps: Vec::new(),
        active: hot,
    };
    let mut ctx = *ctx;
    let mut seen = CellSet::new();
    let mut step: Option<u32> = None;
    let mut current: Vec<Contact> = Vec::new();
    let visits = walked.get_or_init(|| Visits::walk(catalog, paths, b.pose));
    visits.replay(&mut |v: &Visit| {
        if seen.contains(&v.position) {
            return Ok(());
        }
        let s = state(source, v.position)?;
        if facts.flags(s) & crate::facts::AIR != 0 {
            return Ok(());
        }
        let inside = facts.player.inside(s);
        let block_hit = match &inside.shape {
            InsideShape::Full => true,
            InsideShape::Context => {
                collide::inside_shape(&facts.shapes, s, v.position, &ctx, &v.body, v.delta)
            }
            InsideShape::Boxes(boxes) => {
                let placed: Vec<Aabb> = boxes
                    .iter()
                    .map(|b| b.moved(v.position.map(|c| c as f64)))
                    .collect();
                collided_along(&v.body, v.delta, &placed)
            }
        };
        let fluid = fluid_hit(source, facts, s, v.position, &v.body, v.delta)?;
        let request = hazard(facts, s, t.careful, t.known_movement);
        if !block_hit && fluid.is_none() {
            return Ok(());
        }
        match step {
            Some(current_step) if current_step == v.step => {}
            None => step = Some(v.step),
            Some(_) => {
                out.steps.push(std::mem::take(&mut current));
                step = Some(v.step);
            }
        }
        if block_hit {
            match inside.kind {
                InsideKind::Fire => current.push(Contact::Fire),
                InsideKind::SoulFire => current.push(Contact::SoulFire),
                InsideKind::PowderSnow => current.push(Contact::PowderSnow),
                _ => {}
            }
        }
        if let Some(f) = fluid {
            current.push(f);
        }
        if block_hit {
            if let Some(r) = request {
                if r.0 != Source::HotFloor {
                    out.immediate.push(r);
                }
            }
        }
        seen.insert(v.position);
        out.active = out.active
            || matches!(inside.kind, InsideKind::Fire | InsideKind::SoulFire)
            || !out.immediate.is_empty();
        let slow = rules::player_contact(
            if block_hit {
                stuck(facts, s)
            } else {
                Stuck::None
            },
            b.weaving,
            feet == Stuck::PowderSnow,
            false,
        );
        if slow.is_some() && !b.flying {
            ctx.fall_distance = 0.0;
        }
        Ok(())
    })?;
    if step.is_some() {
        out.steps.push(current);
    }
    Ok(out)
}

/// Whether any cell the body covers holds powder snow (every cell must be
/// readable).
pub fn powder_snow(source: &dyn BlockSource, facts: &Facts, b: &Aabb) -> Result<bool, Fault> {
    const E: f64 = 9.999999747378752e-6;
    let lo: [f64; 3] = std::array::from_fn(|i| b.min[i] + E);
    let hi: [f64; 3] = std::array::from_fn(|i| b.max[i] - E);
    if !(0..3).all(|i| lo[i] < hi[i]) {
        return Err(Fault::Limit("environment_body_limit"));
    }
    let a = lo.map(|v| v.floor() as i32);
    let z = hi.map(|v| v.floor() as i32);
    let count: i64 = (0..3).map(|i| (z[i] - a[i] + 1) as i64).product();
    if !(1..=512).contains(&count) {
        return Err(Fault::Limit("environment_body_limit"));
    }
    let mut found = false;
    for x in a[0]..=z[0] {
        for y in a[1]..=z[1] {
            for zz in a[2]..=z[2] {
                if stuck(facts, state(source, [x, y, zz])?) == Stuck::PowderSnow {
                    found = true;
                }
            }
        }
    }
    Ok(found)
}
