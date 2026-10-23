//! A mob's tick (VMC-015i): vanilla `Entity.baseTick`'s fluid state, then
//! `LivingEntity.aiStep` for a living body that is not a player — the dead
//! zone, input decay, `MoveControl` and `JumpControl`, jumps, `travel` with
//! `moveRelative` (dry, water and lava), `Entity.move` with the type's step
//! height, landing, climbing and slowing blocks — and `pushEntities` across
//! the bodies an owner ticks together. The arithmetic is the player's
//! (`player::rules`); the geometry is the kernel's. Living effects (fall
//! damage, air, burning, lava) come back as observations.

use super::aabb::Aabb;
use super::collide::{self, Extra};
use super::fluid::{self, Depths, Pushed};
use super::player::contacts::{self, Body, Slowing, Touched, Toucher};
use super::player::kinetics::Material;
use super::player::paths;
use super::player::pose::{self, Dimensions};
use super::player::rules::{self, Air, FluidMotion, EPSILON, SIN_SCALE};
use super::player::{Fault, World};
use super::response::{self, Response};
use super::table::Context;

/// `FenceBlock`s and `DoorBlock`s (flag bits 47 and 48): `MoveControl` does
/// not jump onto them.
const FENCE: u64 = 1 << 47;
const DOOR: u64 = 1 << 48;

/// `MoveControl`'s operation.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Control {
    Wait,
    /// Toward `target` at `speed` times the movement speed.
    MoveTo {
        target: [f64; 3],
        speed: f64,
    },
    /// After a jump `MoveControl` asked for, until the mob lands.
    Jumping {
        speed: f64,
    },
}

/// The attributes travel reads.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Attributes {
    pub movement_speed: f64,
    pub jump_strength: f64,
    pub gravity: f64,
    pub step_height: f64,
    pub water_efficiency: f64,
    pub friction_modifier: f64,
    pub air_drag_modifier: f64,
}

impl Default for Attributes {
    fn default() -> Attributes {
        Attributes {
            movement_speed: 0.7,
            jump_strength: 0.41999998688697815,
            gravity: 0.08,
            step_height: 0.6,
            water_efficiency: 0.0,
            friction_modifier: 1.0,
            air_drag_modifier: 1.0,
        }
    }
}

/// A mob's movement state, kept by its owner between ticks.
#[derive(Clone, Debug, PartialEq)]
pub struct Mob {
    pub position: [f64; 3],
    pub yaw: f32,
    pub head_yaw: f32,
    pub velocity: [f64; 3],
    pub on_ground: bool,
    pub horizontal_collision: bool,
    pub fall_distance: f64,
    pub no_jump_delay: i32,
    pub stuck_multiplier: [f64; 3],
    /// The relative input (`xxa`, `zza`) and speed the controls set.
    pub strafe: f32,
    pub forward: f32,
    pub speed: f32,
    pub control: Control,
    pub size: Dimensions,
    pub attributes: Attributes,
    pub no_gravity: bool,
    pub slow_falling: bool,
    pub levitation: Option<i32>,
    pub jump_boost: i32,
    /// Alive and not climbing: others push it (`isPushable`).
    pub alive: bool,
    /// `JumpControl.jump()` from the AI this tick (`FloatGoal`).
    pub jump: bool,
}

/// One tick's result: the mob after it and what its living rules read.
#[derive(Clone, Debug, PartialEq)]
pub struct Ticked {
    pub mob: Mob,
    pub water: bool,
    pub lava: bool,
    pub eye_water: bool,
    pub eye_state: u16,
    /// The landing block and fall distance (`Block.fallOn`), if it landed.
    pub landing: Option<(u16, f64)>,
    pub touched: Touched,
    pub climbing: bool,
    /// The fluid heights the move left (`checkFallDamage`'s sample), which
    /// the AI reads the next tick.
    pub depths: Depths,
}

fn add(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

/// `Mth.wrapDegrees` for floats.
fn wrap(d: f32) -> f32 {
    let mut d = d % 360.0;
    if d >= 180.0 {
        d -= 360.0;
    }
    if d < -180.0 {
        d += 360.0;
    }
    d
}

/// `MoveControl.rotlerp`.
fn rotlerp(a: f32, b: f32, max: f32) -> f32 {
    let diff = wrap(b - a).clamp(-max, max);
    let r = a + diff;
    if r < 0.0 {
        r + 360.0
    } else if r > 360.0 {
        r - 360.0
    } else {
        r
    }
}

/// `Mth.atan2`: vanilla's table approximation, not the platform's atan2.
pub fn atan2(y: f64, x: f64) -> f64 {
    use crate::worldgen::java;
    use std::sync::OnceLock;
    static TABLES: OnceLock<([f64; 257], [f64; 257])> = OnceLock::new();
    let (asin_tab, cos_tab) = TABLES.get_or_init(|| {
        let mut a = [0.0; 257];
        let mut c = [0.0; 257];
        for i in 0..257 {
            a[i] = java::asin(i as f64 / 256.0);
            c[i] = java::cos(a[i]);
        }
        (a, c)
    });
    const FRAC_BIAS: f64 = f64::from_bits(4_805_340_802_404_319_232);
    let d2 = x * x + y * y;
    if d2.is_nan() {
        return f64::NAN;
    }
    let (mut x, mut y) = (x, y);
    let neg_y = y < 0.0;
    if neg_y {
        y = -y;
    }
    let neg_x = x < 0.0;
    if neg_x {
        x = -x;
    }
    let steep = y > x;
    if steep {
        std::mem::swap(&mut x, &mut y);
    }
    // `fastInvSqrt`.
    let half = 0.5 * d2;
    let guess =
        f64::from_bits((6_910_469_410_427_058_090_i64 - ((d2.to_bits() as i64) >> 1)) as u64);
    let rinv = guess * (1.5 - half * guess * guess);
    x *= rinv;
    y *= rinv;
    let yp = FRAC_BIAS + y;
    let index = yp.to_bits() as i32 as usize;
    let phi = asin_tab[index];
    let c_phi = cos_tab[index];
    let s_phi = yp - FRAC_BIAS;
    let sd = y * c_phi - x * s_phi;
    let d = (6.0 + sd * sd) * sd * 0.16666666666666666;
    let mut theta = phi + d;
    if steep {
        theta = std::f64::consts::FRAC_PI_2 - theta;
    }
    if neg_x {
        theta = std::f64::consts::PI - theta;
    }
    if neg_y {
        theta = -theta;
    }
    theta
}

/// `Entity.getInputVector`: relative input turned by the yaw, at `speed`.
pub fn input_vector(input: [f64; 3], speed: f32, yaw: f32) -> [f64; 3] {
    let length = input[0] * input[0] + input[1] * input[1] + input[2] * input[2];
    if length < 1.0e-7 {
        return [0.0; 3];
    }
    let base = if length > 1.0 {
        let l = length.sqrt();
        if l < 1.0e-5 {
            [0.0; 3]
        } else {
            input.map(|v| v / l)
        }
    } else {
        input
    };
    let m = base.map(|v| v * speed as f64);
    let a = rules::angle(yaw as f64);
    let sin = rules::trig((a * SIN_SCALE) as i64);
    let cos = rules::trig((a * SIN_SCALE + 16_384.0) as i64);
    [m[0] * cos - m[2] * sin, m[1], m[2] * cos + m[0] * sin]
}

/// `LivingEntity.getFrictionInfluencedSpeed`: on the ground the speed, cut
/// on slippery blocks; in the air the flying speed.
pub fn friction_speed(speed: f32, friction: f32, on_ground: bool) -> f32 {
    if !on_ground {
        0.02
    } else if friction > 0.6 {
        speed * (0.21600002 / (friction * friction * friction))
    } else {
        speed
    }
}

/// `LivingEntity.computeModifiedFriction`.
fn modified_friction(base: f32, modifier: f32) -> f32 {
    (1.0 - (1.0 - base) * modifier).clamp(0.0, 1.0)
}

/// `LivingEntity.getJumpPower` over the block's jump factor.
pub fn jump_power(strength: f64, factor: f32, jump_boost: i32) -> f32 {
    let bonus = if jump_boost < 0 {
        0.0
    } else {
        0.1 * (jump_boost as f32 + 1.0)
    };
    strength as f32 * 1.0 * factor + bonus
}

/// `MoveControl.tick` then `JumpControl.tick`: the yaw, speed and forward
/// input, the next operation and whether the mob jumps.
pub fn control(mob: &mut Mob, block: Option<(f64, u64)>, in_liquid: bool) -> bool {
    let attribute = mob.attributes.movement_speed;
    match mob.control {
        Control::MoveTo { target, speed } => {
            mob.control = Control::Wait;
            let [xd, yd, zd] = sub(target, mob.position);
            let dd = xd * xd + yd * yd + zd * zd;
            if dd < 2.500_000_3e-7_f32 as f64 {
                mob.forward = 0.0;
                return false;
            }
            // `180.0F / (float)Math.PI`, folded by javac into one double.
            let wanted = (atan2(zd, xd) * 57.2957763671875) as f32 - 90.0;
            mob.yaw = rotlerp(mob.yaw, wanted, 90.0);
            mob.speed = (speed * attribute) as f32;
            mob.forward = mob.speed;
            let width = mob.size.width as f32;
            let blocked = match block {
                Some((top, flags)) => mob.position[1] < top && flags & (FENCE | DOOR) == 0,
                None => false,
            };
            if yd > mob.attributes.step_height as f32 as f64
                && xd * xd + zd * zd < width.max(1.0) as f64
                || blocked
            {
                mob.control = Control::Jumping { speed };
                return true;
            }
            false
        }
        Control::Jumping { speed } => {
            mob.speed = (speed * attribute) as f32;
            mob.forward = mob.speed;
            if mob.on_ground || in_liquid {
                mob.control = Control::Wait;
            }
            false
        }
        Control::Wait => {
            mob.forward = 0.0;
            false
        }
    }
}

impl Mob {
    fn catalog(&self) -> [Dimensions; 1] {
        [self.size]
    }

    fn context(&self, fall: f64, bottom: f64) -> Context {
        Context {
            entity: true,
            bottom,
            descending: false,
            placement: false,
            entity_present: true,
            fall_distance: fall,
            falling_block: false,
            powder_snow_walkable: false,
        }
    }

    fn body(&self, at: [f64; 3]) -> Result<Aabb, Fault> {
        Ok(pose::geometry(&self.catalog(), 0, at)?.body)
    }

    fn gravity(&self, velocity_y: f64) -> f64 {
        if self.no_gravity {
            0.0
        } else {
            rules::gravity(self.attributes.gravity, velocity_y, self.slow_falling)
        }
    }

    /// `getFluidJumpThreshold`.
    fn jump_threshold(&self) -> f64 {
        if self.size.eye < 0.4 {
            0.0
        } else {
            0.4
        }
    }
}

/// The colliding block at the mob's feet, as `MoveControl` reads it: its
/// shape's top in world Y and its flags, or nil for an empty shape.
fn feet_block(w: &World, mob: &Mob) -> Result<Option<(f64, u64)>, Fault> {
    let p = mob.position.map(|v| v.floor() as i32);
    let state = w.state(p)?;
    let picked = w.facts.shapes.shape(state, p, &Context::default());
    Ok(picked
        .shape
        .bounds()
        .map(|b| (b.max[1] + p[1] as f64, w.facts.flags(state))))
}

fn currents(w: &World, body: &Aabb, velocity: [f64; 3]) -> Result<(Depths, [f64; 3]), Fault> {
    if !rules::bounded(velocity, 64.0) {
        return Err(Fault::Limit("invalid_fluid_current"));
    }
    w.fluid_bounded(body)?;
    fluid::current(w.source, w.facts, body, velocity, true, false, Pushed::Item)?
        .ok_or(Fault::Limit("invalid_fluid_box"))
}

/// One tick of `mob` (its pushes from others are applied by `tick_all`).
pub fn tick(w: &World, mob: &Mob) -> Result<Ticked, Fault> {
    let mut m = mob.clone();
    let start = m.position;
    let body = m.body(start)?;
    // baseTick: the fluid state and its currents; water resets the fall,
    // lava halves it.
    let (depths, pushed) = currents(w, &body, m.velocity)?;
    m.velocity = pushed;
    let water = depths.water > 0.0;
    let lava = depths.lava > 0.0;
    if water {
        m.fall_distance = 0.0;
    }
    if lava {
        m.fall_distance *= 0.5;
    }
    // aiStep.
    if m.no_jump_delay > 0 {
        m.no_jump_delay -= 1;
    }
    let [vx, vy, vz] = m.velocity;
    m.velocity = [
        if vx.abs() < 0.003 { 0.0 } else { vx },
        if vy.abs() < 0.003 { 0.0 } else { vy },
        if vz.abs() < 0.003 { 0.0 } else { vz },
    ];
    m.strafe *= 0.98;
    m.forward *= 0.98;
    // LivingEntity.baseTick's air reads the eye's fluid where the tick began.
    let eye = [start[0], start[1] + m.size.eye, start[2]];
    let (eye_water, _) = w.eyes(&body, eye)?;
    let eye_state = w.state(eye.map(|v| v.floor() as i32))?;
    let block = feet_block(w, &m)?;
    // `JumpControl.tick`: the move control's jump or the AI's. The head is
    // the look control's (the AI's), before this tick.
    let jumping = control(&mut m, block, water || lava) || m.jump;
    m.jump = false;
    if jumping {
        let height = if lava { depths.lava } else { depths.water };
        let in_water = water && height > 0.0;
        let threshold = m.jump_threshold();
        if !in_water || m.on_ground && height <= threshold {
            if !lava || m.on_ground && depths.lava <= threshold {
                if (m.on_ground || in_water && height <= threshold) && m.no_jump_delay == 0 {
                    let footing =
                        w.material(&body, start, &m.context(m.fall_distance, start[1]))?;
                    let factor = if footing.feet.jump_factor == 1.0 {
                        footing.below.jump_factor
                    } else {
                        footing.feet.jump_factor
                    };
                    let power = jump_power(m.attributes.jump_strength, factor, m.jump_boost);
                    if power > 1.0e-5 {
                        m.velocity[1] = m.velocity[1].max(power as f64);
                    }
                    m.no_jump_delay = 10;
                }
            } else {
                m.velocity[1] += 0.04_f32 as f64;
            }
        } else {
            m.velocity[1] += 0.04_f32 as f64;
        }
    } else {
        m.no_jump_delay = 0;
    }
    if m.slow_falling || m.levitation.is_some() {
        m.fall_distance = 0.0;
    }
    let input = [m.strafe as f64, 0.0, m.forward as f64];
    let climbing_before = contacts::climb(
        w.source,
        w.facts,
        start.map(|v| v.floor() as i32),
        false,
        false,
        false,
    )?
    .0;
    let before = w.material(&body, start, &m.context(m.fall_distance, start[1]))?;
    let in_fluid = water || lava;
    // travel: the relative input, then the move.
    let falling = m.velocity[1] <= 0.0;
    let fluid_gravity = m.gravity(m.velocity[1]);
    let friction = if m.on_ground {
        modified_friction(before.below.friction, m.attributes.friction_modifier as f32)
    } else {
        1.0
    };
    let speed = if in_fluid {
        if water {
            let mut efficiency = m.attributes.water_efficiency as f32;
            if !m.on_ground {
                efficiency *= 0.5;
            }
            let speed = 0.02_f32;
            if efficiency > 0.0 {
                speed + (m.speed - speed) * efficiency
            } else {
                speed
            }
        } else {
            0.02
        }
    } else {
        friction_speed(m.speed, friction, m.on_ground)
    };
    m.velocity = add(m.velocity, input_vector(input, speed, m.yaw));
    let mut fall = m.fall_distance;
    if !in_fluid {
        let (v, reset) = rules::climb_prepare(m.velocity, climbing_before, false, false)?;
        m.velocity = v;
        if reset {
            fall = 0.0;
        }
    }
    let was_on_ground = m.on_ground;
    let moved = mob_move(w, &mut m, &body, fall, water, depths)?;
    let after_body = m.body(m.position)?;
    let climbing = contacts::climb(
        w.source,
        w.facts,
        m.position.map(|v| v.floor() as i32),
        false,
        false,
        false,
    )?
    .0;
    m.velocity = if in_fluid {
        let (v, escape) = rules::fluid_motion(
            m.velocity,
            &FluidMotion {
                lava: !water,
                gravity: fluid_gravity,
                falling,
                on_ground: m.on_ground,
                sprint: false,
                water_efficiency: m.attributes.water_efficiency,
                horizontal_collision: m.horizontal_collision,
                climbable: m.horizontal_collision && water && climbing,
                shallow: moved.depths.lava <= m.jump_threshold(),
                old_y: start[1],
                new_y: m.position[1],
                ..FluidMotion::default()
            },
        )?;
        let free = match escape {
            None => false,
            Some(offset) => w.free(
                &after_body.moved(offset),
                &m.context(moved.fall, m.position[1]),
                m.position,
            )?,
        };
        rules::fluid_finish(v, escape, free)
    } else {
        let finished = rules::climb_finish(m.velocity, climbing, m.horizontal_collision, jumping)?;
        rules::air_step(
            finished,
            &Air {
                on_ground: was_on_ground,
                friction: before.below.friction as f64,
                friction_modifier: m.attributes.friction_modifier,
                air_drag_modifier: m.attributes.air_drag_modifier,
                gravity: m.gravity(m.velocity[1]),
                levitation: m.levitation,
                ..Air::default()
            },
        )
    };
    if !rules::bounded(m.velocity, 64.0) {
        return Err(Fault::Limit("kinetic_velocity_limit"));
    }
    // applyEffectsFromBlocks: slowing blocks for the next move, fire and
    // hazards for the living rules.
    let mut recorded = Vec::new();
    paths::record(&mut recorded, start, moved.actual, moved.requested);
    let visited = paths::collect(&recorded, start, m.position);
    let catalog = m.catalog();
    let feet = Body {
        pose: 0,
        feet: m.position,
        flying: false,
        spectator: false,
        weaving: false,
    };
    let Slowing { multiplier, last } = contacts::slowing(
        w.source,
        w.facts,
        &catalog,
        &visited,
        &m.context(moved.fall, m.position[1]),
        &feet,
    )?;
    if let Some(mult) = multiplier {
        m.stuck_multiplier = mult;
    }
    if last.is_some() {
        m.fall_distance = 0.0;
    }
    let touched = contacts::touched(
        w.source,
        w.facts,
        &catalog,
        &visited,
        &m.context(m.fall_distance, m.position[1]),
        &Toucher {
            body: feet,
            grounded: m.on_ground,
            careful: false,
            known_movement: moved.actual,
            support_state: moved.material.legacy.1,
        },
    )?;
    m.alive = mob.alive;
    Ok(Ticked {
        mob: m,
        water: water || moved.depths.water > 0.0,
        lava,
        eye_water,
        eye_state,
        landing: moved.landing,
        touched,
        climbing,
        depths: moved.depths,
    })
}

/// What `Entity.move` did.
struct Moved {
    requested: [f64; 3],
    actual: [f64; 3],
    fall: f64,
    landing: Option<(u16, f64)>,
    /// The fluid depths after the move (re-sampled unless in water before).
    depths: Depths,
    material: Material,
}

/// `Entity.move` for a mob: the slowing multiplier, collision with step-up,
/// the position, ground and collision flags, the fluid state after the move
/// (`LivingEntity.checkFallDamage`), the fall and landing, restitution and the
/// block's speed factor.
fn mob_move(
    w: &World,
    m: &mut Mob,
    body: &Aabb,
    fall: f64,
    water_before: bool,
    depths_before: Depths,
) -> Result<Moved, Fault> {
    let start = m.position;
    let mut requested = m.velocity;
    let multiplier = m.stuck_multiplier;
    if multiplier[0] * multiplier[0] + multiplier[1] * multiplier[1] + multiplier[2] * multiplier[2]
        > 1.0e-7
    {
        requested = [
            requested[0] * multiplier[0],
            requested[1] * multiplier[1],
            requested[2] * multiplier[2],
        ];
        m.stuck_multiplier = [0.0; 3];
        m.velocity = [0.0; 3];
    }
    if !rules::bounded(requested, 64.0) {
        return Err(Fault::Limit("kinetic_query_limit"));
    }
    let ctx = m.context(fall, start[1]);
    let extra = Extra {
        entities: Vec::new(),
        border: w.border,
        subject: [start[0], start[2]],
    };
    let moved = collide::collide(
        w.source,
        &w.facts.shapes,
        body,
        requested,
        &ctx,
        &extra,
        m.attributes.step_height as f32,
        m.on_ground,
    )?;
    let actual = moved.actual;
    if paths::records(actual, requested) {
        m.position = add(start, actual);
    }
    let x_collision = (requested[0] - actual[0]).abs() >= EPSILON;
    let z_collision = (requested[2] - actual[2]).abs() >= EPSILON;
    m.horizontal_collision = x_collision || z_collision;
    let vertical = requested[1] != actual[1];
    if requested[1].abs() > 0.0 {
        m.on_ground = vertical && requested[1] < 0.0;
    }
    let after_body = m.body(m.position)?;
    let material = w.material(&after_body, m.position, &m.context(fall, m.position[1]))?;
    // checkFallDamage re-samples the fluid state (and its currents) when not
    // in water before.
    let depths = if water_before {
        depths_before
    } else {
        let (depths, pushed) = currents(w, &after_body, m.velocity)?;
        m.velocity = pushed;
        depths
    };
    let water = depths.water > 0.0;
    let mut fall = fall;
    if water {
        fall = 0.0;
    }
    let (next, landed) = rules::fall_step(fall, actual[1], m.on_ground, water);
    m.fall_distance = next;
    let landing = landed.map(|d| (material.legacy.1, d));
    if requested[1].abs() > 0.0 && vertical || m.horizontal_collision {
        let r = response::respond(
            m.velocity,
            actual[1],
            &Response {
                x_collision,
                z_collision,
                vertical_collision: vertical,
                below: vertical && requested[1] < 0.0,
                suppress_bounce: false,
                block_suppresses_bounce: material.below.suppresses_bounce,
                block_bounciness: material.below.bounciness as f64,
                ..Response::default()
            },
        );
        m.velocity = r.velocity;
    }
    let factor = if material.feet.speed_factor == 1.0 {
        material.below.speed_factor
    } else {
        material.feet.speed_factor
    } as f64;
    m.velocity = [
        m.velocity[0] * factor,
        m.velocity[1],
        m.velocity[2] * factor,
    ];
    Ok(Moved {
        requested,
        actual,
        fall: m.fall_distance,
        landing,
        depths,
        material,
    })
}

/// `Entity.push` between a pusher at `from` and a body at `to`: the push the
/// body gets (the pusher gets its negation), or none when they are too close
/// together on both axes.
pub fn push(from: [f64; 3], to: [f64; 3]) -> Option<[f64; 3]> {
    let mut xa = to[0] - from[0];
    let mut za = to[2] - from[2];
    let mut dd = xa.abs().max(za.abs());
    if dd < 0.01_f32 as f64 {
        return None;
    }
    dd = dd.sqrt();
    xa /= dd;
    za /= dd;
    let pow = (1.0 / dd).min(1.0);
    xa *= pow;
    za *= pow;
    xa *= 0.05_f32 as f64;
    za *= 0.05_f32 as f64;
    Some([xa, 0.0, za])
}

/// One tick of every mob of an owner, in order: each travels, then pushes
/// the pushable mobs it touches and is pushed by them
/// (`LivingEntity.pushEntities`); `players` (feet and box) push the mobs they
/// touch. Mobs meet only within neighbouring cells of a grid as wide as the
/// widest mob, so pushing costs what is near. A mob the kernel cannot tick
/// keeps its state (`Err`).
pub fn tick_all(
    w: &World,
    mobs: &[Mob],
    players: &[([f64; 3], Aabb)],
) -> Vec<Result<Ticked, Fault>> {
    use std::collections::HashMap;
    let mut current: Vec<Mob> = mobs.to_vec();
    let cell = mobs.iter().map(|m| m.size.width).fold(2.0_f64, f64::max);
    let key = |p: [f64; 3]| ((p[0] / cell).floor() as i64, (p[2] / cell).floor() as i64);
    let mut grid: HashMap<(i64, i64), Vec<usize>> = HashMap::new();
    let mut cells: Vec<(i64, i64)> = Vec::with_capacity(mobs.len());
    for (i, m) in current.iter().enumerate() {
        let k = key(m.position);
        grid.entry(k).or_default().push(i);
        cells.push(k);
    }
    let mut out: Vec<Result<Ticked, Fault>> = Vec::with_capacity(mobs.len());
    for i in 0..mobs.len() {
        let result = tick(w, &current[i]);
        if let Ok(t) = &result {
            current[i] = t.mob.clone();
            let k = key(current[i].position);
            if k != cells[i] {
                if let Some(v) = grid.get_mut(&cells[i]) {
                    v.retain(|&j| j != i);
                }
                grid.entry(k).or_default().push(i);
                cells[i] = k;
            }
        }
        out.push(result);
        if !current[i].alive {
            continue;
        }
        let Ok(own) = current[i].body(current[i].position) else {
            continue;
        };
        let (cx, cz) = cells[i];
        let mut near: Vec<usize> = (cx - 1..=cx + 1)
            .flat_map(|x| (cz - 1..=cz + 1).map(move |z| (x, z)))
            .filter_map(|k| grid.get(&k))
            .flatten()
            .copied()
            .filter(|&j| j != i && current[j].alive)
            .collect();
        near.sort_unstable();
        for j in near {
            let Ok(other) = current[j].body(current[j].position) else {
                continue;
            };
            if !own.intersects(&other) {
                continue;
            }
            // `other.push(self)`: the other moves away, then this one.
            if let Some(p) = push(current[i].position, current[j].position) {
                current[j].velocity = add(current[j].velocity, p);
                current[i].velocity = sub(current[i].velocity, p);
            }
        }
        // A player it touches pushes it away (`player.push(self)`).
        for (feet, player) in players {
            if own.intersects(player) {
                if let Some(p) = push(*feet, current[i].position) {
                    current[i].velocity = add(current[i].velocity, p);
                }
            }
        }
    }
    // Players push the mobs they touch (their own `pushEntities`).
    for (feet, player) in players {
        for m in current.iter_mut().filter(|m| m.alive) {
            let Ok(b) = m.body(m.position) else { continue };
            if b.intersects(player) {
                if let Some(p) = push(*feet, m.position) {
                    m.velocity = add(m.velocity, p);
                }
            }
        }
    }
    // The pushes land in each mob's velocity for its next tick.
    for (result, mob) in out.iter_mut().zip(current) {
        if let Ok(t) = result {
            t.mob.velocity = mob.velocity;
        }
    }
    out
}

impl Default for Mob {
    fn default() -> Mob {
        Mob {
            position: [0.0; 3],
            yaw: 0.0,
            head_yaw: 0.0,
            velocity: [0.0; 3],
            on_ground: false,
            horizontal_collision: false,
            fall_distance: 0.0,
            no_jump_delay: 0,
            stuck_multiplier: [0.0; 3],
            strafe: 0.0,
            forward: 0.0,
            speed: 0.0,
            control: Control::Wait,
            size: Dimensions {
                width: 0.6,
                height: 1.95,
                eye: 1.74,
            },
            attributes: Attributes::default(),
            no_gravity: false,
            slow_falling: false,
            levitation: None,
            jump_boost: -1,
            alive: true,
            jump: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn atan2_is_vanilla_table() {
        // `Mth.atan2` at the axes and a diagonal, as `MoveControl` turns.
        assert_eq!(atan2(0.0, -0.034369283456992), std::f64::consts::PI);
        assert_eq!(atan2(0.0, 1.0), 0.0);
        // An approximation: within a millionth of a radian on a diagonal.
        assert!((atan2(1.0, 1.0) - std::f64::consts::FRAC_PI_4).abs() < 1.0e-6);
        assert!(atan2(f64::NAN, 1.0).is_nan());
    }

    #[test]
    fn rotlerp_turns_at_most_max_and_wraps() {
        assert_eq!(rotlerp(270.0, 90.0, 90.0), 180.0);
        assert_eq!(rotlerp(270.0, 89.99998, 90.0), 360.0);
        assert_eq!(rotlerp(10.0, -30.0, 90.0), 330.0);
        assert_eq!(rotlerp(0.0, 45.0, 90.0), 45.0);
    }

    #[test]
    fn input_below_threshold_is_none_and_long_input_is_normalized() {
        assert_eq!(input_vector([1.0e-4, 0.0, 1.0e-4], 0.1, 0.0), [0.0; 3]);
        let v = input_vector([3.0, 0.0, 4.0], 1.0, 0.0);
        assert!((v[0] - 0.6).abs() < 1.0e-6 && (v[2] - 0.8).abs() < 1.0e-6);
    }

    #[test]
    fn pushes_apart_unless_on_top_of_each_other() {
        assert_eq!(push([0.0; 3], [0.005, 0.0, 0.0]), None);
        let p = push([0.0; 3], [0.25, 0.0, 0.0]).unwrap();
        assert!(p[0] > 0.0 && p[1] == 0.0 && p[2] == 0.0);
    }

    #[test]
    fn move_control_jumps_for_a_step_up_close_by() {
        let mut m = Mob {
            position: [0.5, 64.0, 0.5],
            control: Control::MoveTo {
                target: [1.2, 65.0, 0.5],
                speed: 1.0,
            },
            ..Mob::default()
        };
        assert!(control(&mut m, None, false));
        assert_eq!(m.control, Control::Jumping { speed: 1.0 });
        m.on_ground = true;
        assert!(!control(&mut m, None, false));
        assert_eq!(m.control, Control::Wait);
    }
}
