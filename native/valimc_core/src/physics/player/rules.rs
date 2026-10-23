//! The player's pure travel arithmetic (vanilla `LivingEntity.travel` and
//! `Player.travel` pieces): jumps, dry-air drag and gravity, fluid controls
//! and fluid travel, climbing clamps, swimming steering and transitions,
//! slowing contacts, sneaking at edges, travel exhaustion and the server's
//! move acceptance. Every function is checked bit for bit by an oracle stage.

use super::Fault;
use crate::physics::aabb::Aabb;

#[inline]
pub fn f32r(v: f64) -> f64 {
    v as f32 as f64
}

pub(crate) const SIN_SCALE: f64 = 10_430.378350470453;
pub const EPSILON: f64 = 9.999999747378752e-6;

/// `Mth.sin` of a table index.
pub(crate) fn trig(index: i64) -> f64 {
    f32r(((index & 65_535) as f64 / SIN_SCALE).sin())
}

pub(crate) fn angle(degrees: f64) -> f64 {
    f32r(f32r(degrees) * f32r(0.017453292))
}

/// Whether every component lies within `bound`.
pub fn bounded(v: [f64; 3], bound: f64) -> bool {
    v.iter().all(|c| c.abs() <= bound)
}

/// The jump power for a block's jump factor and Jump Boost's amplifier (-1
/// for none).
pub fn jump_power(factor: f64, amplifier: i32) -> f64 {
    let bonus = if amplifier < 0 {
        0.0
    } else {
        f32r(f32r(0.1) * (amplifier + 1) as f64)
    };
    f32r(f32r(f32r(0.42) * f32r(factor)) + bonus)
}

/// `LivingEntity.jumpFromGround`: sprinting adds a push along the yaw.
pub fn jump(
    v: [f64; 3],
    factor: f64,
    sprint: bool,
    yaw: f64,
    amplifier: i32,
) -> Result<[f64; 3], Fault> {
    if !bounded(v, 64.0)
        || !(0.0..=4.0).contains(&factor)
        || yaw.abs() > 1_000_000.0
        || !(-1..=255).contains(&amplifier)
    {
        return Err(Fault::Limit("invalid_velocity"));
    }
    let power = jump_power(factor, amplifier);
    let [x, y, z] = v;
    Ok(if power <= EPSILON {
        v
    } else if sprint {
        let a = angle(yaw);
        let sin = trig((a * SIN_SCALE) as i64);
        let cos = trig((a * SIN_SCALE + 16_384.0) as i64);
        [x + -sin * 0.2, y.max(power) + 0.0, z + cos * 0.2]
    } else {
        [x, y.max(power), z]
    })
}

/// Gravity at the native selection point: Slow Falling caps it while falling.
pub fn gravity(base: f64, velocity_y: f64, slow: bool) -> f64 {
    if slow && velocity_y <= 0.0 {
        base.min(0.01)
    } else {
        base
    }
}

/// What dry-air travel reads after collision.
#[derive(Clone, Copy, Debug)]
pub struct Air {
    pub on_ground: bool,
    pub friction: f64,
    pub friction_modifier: f64,
    pub air_drag_modifier: f64,
    pub gravity: f64,
    pub levitation: Option<i32>,
    pub discard_friction: bool,
    pub omnidirectional: bool,
}

impl Default for Air {
    fn default() -> Air {
        Air {
            on_ground: false,
            friction: 0.6,
            friction_modifier: 1.0,
            air_drag_modifier: 1.0,
            gravity: 0.08,
            levitation: None,
            discard_friction: false,
            omnidirectional: false,
        }
    }
}

fn modified(base: f64, modifier: f64) -> f64 {
    f32r(1.0 - f32r(f32r(1.0 - f32r(base)) * f32r(modifier))).clamp(0.0, 1.0)
}

/// The post-collision dry-air velocity update (gravity or Levitation, then
/// floor friction and air drag).
pub fn air_step(v: [f64; 3], f: &Air) -> [f64; 3] {
    let [x, y, z] = v;
    let next_y = match f.levitation {
        None => y - f.gravity,
        Some(level) => y + (0.05 * (level + 1) as f64 - y) * 0.2,
    };
    if f.discard_friction {
        return [x, next_y, z];
    }
    let floor = if f.on_ground {
        modified(f.friction, f.friction_modifier)
    } else {
        1.0
    };
    let air = modified(0.91, f.air_drag_modifier);
    let horizontal = f32r(floor * air);
    let vertical = if f.omnidirectional {
        air
    } else {
        modified(0.98, f.air_drag_modifier)
    };
    [x * horizontal, next_y * vertical, z * horizontal]
}

/// `Player.travel`'s air step; flying keeps 0.6 of the pre-travel Y.
pub fn air(resolved: [f64; 3], old_y: f64, f: &Air, flying: bool) -> [f64; 3] {
    let [x, y, z] = air_step(resolved, f);
    [x, if flying { old_y * 0.6 } else { y }, z]
}

/// The player's dead zone: tiny horizontal and vertical velocities zero.
pub fn normalize(v: [f64; 3]) -> [f64; 3] {
    let [x, y, z] = v;
    let (x, z) = if x * x + z * z < 9.0e-6 {
        (0.0, 0.0)
    } else {
        (x, z)
    };
    [
        x + 0.0,
        if y.abs() < 0.003 { 0.0 } else { y } + 0.0,
        z + 0.0,
    ]
}

/// What the player's vertical fluid intent reads.
#[derive(Clone, Copy, Debug)]
pub struct FluidControls {
    pub water: f64,
    pub lava: f64,
    pub threshold: f64,
    pub on_ground: bool,
    pub jump: bool,
    pub shift: bool,
    pub flying: bool,
}

impl Default for FluidControls {
    fn default() -> FluidControls {
        FluidControls {
            water: 0.0,
            lava: 0.0,
            threshold: 0.4,
            on_ground: false,
            jump: false,
            shift: false,
            flying: false,
        }
    }
}

const PUSH: f64 = 0.03999999910593033;

/// Sinking by Shift in water, the dead zone, then floating or a ground jump:
/// `(velocity, ground_jump)`.
pub fn fluid_controls(v: [f64; 3], f: &FluidControls) -> Result<([f64; 3], bool), Fault> {
    if !bounded(v, 64.0) {
        return Err(Fault::Limit("invalid_fluid_controls"));
    }
    let [x, mut y, z] = v;
    if f.water > 0.0 && f.shift && !f.flying {
        y -= PUSH;
    }
    let [x, y, z] = normalize([x, y, z]);
    let depth = if f.lava > 0.0 { f.lava } else { f.water };
    #[derive(PartialEq)]
    enum Action {
        None,
        Float,
        Ground,
    }
    let action = if !f.jump || f.flying {
        Action::None
    } else if (f.water > 0.0 && depth > 0.0 && (!f.on_ground || depth > f.threshold))
        || (f.lava > 0.0 && (!f.on_ground || f.lava > f.threshold))
    {
        Action::Float
    } else if f.on_ground || (f.water > 0.0 && depth <= f.threshold) {
        Action::Ground
    } else {
        Action::None
    };
    let next = [x, if action == Action::Float { y + PUSH } else { y }, z];
    if !bounded(next, 64.0) {
        return Err(Fault::Limit("fluid_input_limit"));
    }
    Ok((next, action == Action::Ground))
}

/// What water and lava travel read after collision.
#[derive(Clone, Copy, Debug)]
pub struct FluidMotion {
    pub lava: bool,
    pub falling: bool,
    pub on_ground: bool,
    pub sprint: bool,
    pub dolphins_grace: bool,
    pub water_efficiency: f64,
    pub gravity: f64,
    pub horizontal_collision: bool,
    pub climbable: bool,
    pub shallow: bool,
    pub old_y: f64,
    pub new_y: f64,
}

impl Default for FluidMotion {
    fn default() -> FluidMotion {
        FluidMotion {
            lava: false,
            falling: true,
            on_ground: false,
            sprint: false,
            dolphins_grace: false,
            water_efficiency: 0.0,
            gravity: 0.08,
            horizontal_collision: false,
            climbable: false,
            shallow: false,
            old_y: 0.0,
            new_y: 0.0,
        }
    }
}

fn sinking(y: f64, f: &FluidMotion) -> f64 {
    if f.gravity == 0.0 || f.sprint {
        y
    } else if f.falling && (y - 0.005).abs() >= 0.003 && (y - f.gravity / 16.0).abs() < 0.003 {
        -0.003
    } else {
        y - f.gravity / 16.0
    }
}

/// Fluid drag and sinking, and the surface escape to try when blocked
/// horizontally: `(velocity, escape offset)`.
pub fn fluid_motion(v: [f64; 3], f: &FluidMotion) -> Result<([f64; 3], Option<[f64; 3]>), Fault> {
    if !bounded(v, 64.0) || (f.new_y - f.old_y).abs() > 64.0 {
        return Err(Fault::Limit("invalid_fluid_motion"));
    }
    let [x, y, z] = v;
    let next = if f.lava {
        let y = if f.shallow {
            sinking(y * f32r(0.8), f)
        } else {
            y * 0.5
        };
        [
            x * 0.5,
            if f.gravity == 0.0 {
                y
            } else {
                y + -f.gravity / 4.0
            },
            z * 0.5,
        ]
    } else {
        let base = f32r(if f.sprint { 0.9 } else { 0.8 });
        let mut efficiency = f32r(f.water_efficiency);
        if !f.on_ground {
            efficiency = f32r(efficiency * f32r(0.5));
        }
        let mut drag = if efficiency > 0.0 {
            f32r(base + f32r(f32r(f32r(0.54600006) - base) * efficiency))
        } else {
            base
        };
        if f.dolphins_grace {
            drag = f32r(0.96);
        }
        let y = if f.horizontal_collision && f.climbable {
            0.2
        } else {
            y
        };
        [x * drag, sinking(y * f32r(0.8), f), z * drag]
    };
    let escape = f.horizontal_collision.then(|| {
        [
            next[0],
            next[1] + 0.6000000238418579 - f.new_y + f.old_y,
            next[2],
        ]
    });
    if escape.is_some_and(|e| !bounded(e, 64.0)) {
        return Err(Fault::Limit("fluid_escape_limit"));
    }
    Ok((next, escape))
}

/// The escaped velocity when the surface escape is free.
pub fn fluid_finish(v: [f64; 3], escape: Option<[f64; 3]>, free: bool) -> [f64; 3] {
    if escape.is_some() && free {
        [v[0], 0.30000001192092896, v[2]]
    } else {
        v
    }
}

const CLIMB: f64 = 0.15000000596046448;

/// Climbing's clamps before collision: `(velocity, reset_fall)`.
pub fn climb_prepare(
    v: [f64; 3],
    climbing: bool,
    shift: bool,
    scaffolding: bool,
) -> Result<([f64; 3], bool), Fault> {
    if !bounded(v, 64.0) {
        return Err(Fault::Limit("invalid_climb_motion"));
    }
    if !climbing {
        return Ok((v, false));
    }
    let y = v[1].max(-CLIMB);
    Ok((
        [
            v[0].clamp(-CLIMB, CLIMB),
            if y < 0.0 && shift && !scaffolding {
                0.0
            } else {
                y
            },
            v[2].clamp(-CLIMB, CLIMB),
        ],
        true,
    ))
}

/// Climbing's boost after collision.
pub fn climb_finish(
    v: [f64; 3],
    climbing: bool,
    horizontal: bool,
    jump: bool,
) -> Result<[f64; 3], Fault> {
    if !bounded(v, 64.0) {
        return Err(Fault::Limit("invalid_climb_motion"));
    }
    Ok([
        v[0],
        if climbing && (horizontal || jump) {
            0.2
        } else {
            v[1]
        },
        v[2],
    ])
}

/// The Y of the look vector at `pitch` degrees.
pub fn look_y(pitch: f64) -> Result<f64, Fault> {
    if pitch.abs() > 1_000_000.0 {
        return Err(Fault::Limit("invalid_swim_pitch"));
    }
    let a = angle(pitch);
    Ok(-f32r(
        (((a * SIN_SCALE) as i64 & 65_535) as f64 / SIN_SCALE).sin(),
    ))
}

/// Swimming's pre-travel blend toward the look vector.
pub fn swim_steer(
    v: [f64; 3],
    look: f64,
    swimming: bool,
    jump: bool,
    above_fluid: bool,
    passenger: bool,
) -> Result<[f64; 3], Fault> {
    if !bounded(v, 64.0) || look.abs() > 1.0 {
        return Err(Fault::Limit("invalid_swim_steering"));
    }
    let [x, mut y, z] = v;
    if swimming && !passenger && (look <= 0.0 || jump || above_fluid) {
        y += (look - y) * if look < -0.2 { 0.085 } else { 0.06 };
    }
    Ok([x, y, z])
}

/// `Player.updateSwimming`: whether the player swims next.
pub fn swimming_next(
    previous: bool,
    sprint: bool,
    water: bool,
    underwater: bool,
    feet_water: bool,
    passenger: bool,
) -> bool {
    sprint
        && !passenger
        && if previous {
            water
        } else {
            underwater && feet_water
        }
}

/// A slowing block a body is in (`stuck` kinds).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stuck {
    None,
    Cobweb,
    BerryBush,
    PowderSnow,
}

/// The multiplier a slowing contact sets on the player (none for flight).
pub fn player_contact(
    kind: Stuck,
    weaving: bool,
    powder_feet: bool,
    flying: bool,
) -> Option<[f64; 3]> {
    match if flying { Stuck::None } else { kind } {
        Stuck::Cobweb if weaving => Some([0.5, 0.25, 0.5]),
        Stuck::Cobweb => Some([0.25, 0.05000000074505806, 0.25]),
        Stuck::BerryBush => Some([0.800000011920929, 0.75, 0.800000011920929]),
        Stuck::PowderSnow if powder_feet => Some([0.8999999761581421, 1.5, 0.8999999761581421]),
        _ => None,
    }
}

/// A move with its slowing multiplier consumed (it scales the move once and
/// clears the velocity).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Step {
    pub requested: [f64; 3],
    pub velocity: [f64; 3],
    pub multiplier: [f64; 3],
}

pub fn stuck_prepare(
    requested: [f64; 3],
    velocity: [f64; 3],
    multiplier: [f64; 3],
) -> Result<Step, Fault> {
    if !bounded(requested, 64.0)
        || !bounded(velocity, 64.0)
        || !multiplier.iter().all(|m| (0.0..=4.0).contains(m))
    {
        return Err(Fault::Limit("invalid_stuck_motion"));
    }
    let [mx, my, mz] = multiplier;
    Ok(if mx * mx + my * my + mz * mz > 1.0e-7 {
        Step {
            requested: [requested[0] * mx, requested[1] * my, requested[2] * mz],
            velocity: [0.0; 3],
            multiplier: [0.0; 3],
        }
    } else {
        Step {
            requested,
            velocity,
            multiplier,
        }
    })
}

/// What travel exhaustion reads.
#[derive(Clone, Copy, Debug, Default)]
pub struct FoodContact {
    pub passenger: bool,
    pub swimming: bool,
    pub underwater: bool,
    pub water: bool,
    pub climbing: bool,
    pub grounded: bool,
    pub sprinting: bool,
}

fn food_distance(x: f64, y: f64, z: f64, factor: f64) -> f64 {
    let rounded = (f32r(f32r((x * x + y * y + z * z).sqrt()) * 100.0) + 0.5)
        .floor()
        .min(2_147_483_647.0);
    f32r(f32r(factor * f32r(rounded)) * f32r(0.01))
}

/// `Player.checkMovementStatistics`' exhaustion for a move.
pub fn food_travel(m: [f64; 3], c: &FoodContact) -> f64 {
    let [x, y, z] = m;
    if c.passenger || (x == 0.0 && y == 0.0 && z == 0.0) {
        0.0
    } else if c.swimming || c.underwater {
        food_distance(x, y, z, f32r(0.01))
    } else if c.water {
        food_distance(x, 0.0, z, f32r(0.01))
    } else if c.climbing {
        0.0
    } else if c.grounded && c.sprinting {
        food_distance(x, 0.0, z, f32r(0.1))
    } else {
        0.0
    }
}

/// A jump's exhaustion.
pub fn food_jump(sprinting: bool) -> f64 {
    f32r(if sprinting { 0.2 } else { 0.05 })
}

/// "moved wrongly": more than 0.25 blocks horizontally off for a player
/// that is not changing dimension, under an impulse or in creative or
/// spectator mode.
pub fn moved_wrongly(requested: [f64; 3], moved: [f64; 3], creative_or_spectator: bool) -> bool {
    let (dx, dz) = (requested[0] - moved[0], requested[2] - moved[2]);
    !creative_or_spectator && dx * dx + dz * dz > 0.0625
}

/// `handleMovePlayer`'s decision: a move into a new collision is rejected,
/// and so is one that moved wrongly from a clear box; no-physics players
/// (spectators) are never rejected.
pub fn rejected(no_physics: bool, wrongly: bool, old_clear: bool, new_collision: bool) -> bool {
    !no_physics && ((wrongly && old_clear) || new_collision)
}

/// The fall step: each downward delta counts as a float (`fallDistance`),
/// water resets it, ground lands it: `(distance, landed)`.
pub fn fall_step(distance: f64, dy: f64, ground: bool, water: bool) -> (f64, Option<f64>) {
    let distance = if dy < 0.0 && !water {
        distance - f32r(dy)
    } else {
        distance
    };
    let landed = (ground && distance > 0.0).then_some(distance);
    (if ground { 0.0 } else { distance }, landed)
}

/// What sneaking at an edge reads.
#[derive(Clone, Copy, Debug)]
pub struct SneakEdges {
    pub flying: bool,
    pub shift: bool,
    pub on_ground: bool,
    pub fall_distance: f64,
    pub max_step: f64,
    /// Only players and self-moved entities back off edges.
    pub player: bool,
}

impl Default for SneakEdges {
    fn default() -> SneakEdges {
        SneakEdges {
            flying: false,
            shift: false,
            on_ground: false,
            fall_distance: 0.0,
            max_step: 0.6000000238418579,
            player: true,
        }
    }
}

const MAX_EDGE_QUERIES: usize = 4096;

/// `Player.maybeBackOffFromEdge`: the move shortened in 0.05 steps while
/// the ground under the moved body is free; `free` answers a query box.
/// `(requested, queries)`.
pub fn sneak_edges(
    body: &Aabb,
    requested: [f64; 3],
    f: &SneakEdges,
    free: &mut dyn FnMut(&Aabb) -> Result<bool, Fault>,
) -> Result<([f64; 3], usize), Fault> {
    if !bounded(requested, 64.0)
        || !(0.0..=60_000_000.0).contains(&f.fall_distance)
        || !(0.0..=4.0).contains(&f.max_step)
    {
        return Err(Fault::Limit("invalid_sneak_edges"));
    }
    let [mut x, y, mut z] = requested;
    if f.flying || y > 0.0 || !f.player || !f.shift {
        return Ok((requested, 0));
    }
    let step = f32r(f.max_step);
    let mut queries = 0usize;
    let mut query = |x: f64, z: f64, drop: f64, queries: &mut usize| -> Result<bool, Fault> {
        if *queries >= MAX_EDGE_QUERIES {
            return Err(Fault::Limit("sneak_query_limit"));
        }
        let q = Aabb {
            min: [
                body.min[0] + 1.0e-7 + x,
                body.min[1] - drop - 1.0e-7,
                body.min[2] + 1.0e-7 + z,
            ],
            max: [
                body.max[0] - 1.0e-7 + x,
                body.min[1],
                body.max[2] - 1.0e-7 + z,
            ],
        };
        if !(q.min[0] <= q.max[0] && q.min[1] <= q.max[1] && q.min[2] <= q.max[2]) {
            return Err(Fault::Limit("sneak_query_limit"));
        }
        let r = free(&q)?;
        *queries += 1;
        Ok(r)
    };
    let above = if f.on_ground {
        true
    } else if f.fall_distance >= step {
        false
    } else {
        !query(0.0, 0.0, step - f.fall_distance, &mut queries)?
    };
    if above {
        let sign = |v: f64| {
            if v < 0.0 {
                -1.0
            } else if v > 0.0 {
                1.0
            } else {
                0.0
            }
        };
        let shrink = |v: f64, s: f64| if v.abs() <= 0.05 { 0.0 } else { v - s };
        let mut reduce = |mut x: f64,
                          mut z: f64,
                          sx: f64,
                          sz: f64,
                          queries: &mut usize|
         -> Result<(f64, f64), Fault> {
            loop {
                if (sx == 0.0 || x == 0.0) && (sz == 0.0 || z == 0.0) {
                    return Ok((x, z));
                }
                if sx != 0.0 && sz != 0.0 && (x == 0.0 || z == 0.0) {
                    return Ok((x, z));
                }
                if query(x, z, step, queries)? {
                    x = shrink(x, sx);
                    z = shrink(z, sz);
                } else {
                    return Ok((x, z));
                }
            }
        };
        let (nx, _) = reduce(x, 0.0, sign(x) * 0.05, 0.0, &mut queries)?;
        let (_, nz) = reduce(0.0, z, 0.0, sign(z) * 0.05, &mut queries)?;
        x = nx;
        z = nz;
        if x != 0.0 && z != 0.0 {
            let (dx, dz) = reduce(x, z, sign(x) * 0.05, sign(z) * 0.05, &mut queries)?;
            x = dx;
            z = dz;
        }
    }
    Ok(([x, y, z], queries))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_standing_jump_rises_by_the_jump_power() {
        let v = jump([0.0, 0.0, 0.0], 1.0, false, 0.0, -1).unwrap();
        assert_eq!(v[1], jump_power(1.0, -1));
    }

    #[test]
    fn the_dead_zone_zeroes_tiny_velocities() {
        assert_eq!(normalize([0.001, 0.002, 0.001]), [0.0, 0.0, 0.0]);
    }
}
