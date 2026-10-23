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
use super::sweep;
use super::table::Context;
use std::collections::HashMap;

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
    /// The AI ran the mob's own move control (a fish's, a guardian's): it
    /// sets the speed and forward input (`setSpeed`) and, with `lift`,
    /// rises 0.005 while its eyes are in water.
    Set {
        speed: f64,
        lift: bool,
    },
    /// `MoveControl.strafe`: `forward` and `right` inputs at `speed` times
    /// the movement speed (VMC-043b: a skeleton circling its target; the
    /// owner already turned a step into an unwalkable block into straight
    /// ahead).
    Strafe {
        forward: f32,
        right: f32,
        speed: f64,
    },
    /// The mob's own move control did nothing this tick (an axolotl
    /// playing dead): its speed and inputs stay.
    Hold,
}

/// How a mob travels where vanilla's subclasses override it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Travel {
    Ground,
    /// `travelFlying` (a ghast's, VMC-043d): input at 0.02, no gravity, drag
    /// 0.91F in air, 0.8F in water, 0.5 in lava, and no fall.
    Flying,
    /// `AbstractFish.travelInWater`: input at 0.01, drag 0.9, sinking
    /// 0.005 a tick when `sink` (it has no target).
    Fish {
        sink: bool,
    },
    /// `Guardian.travelInWater`: input at 0.1, drag 0.9, sinking when
    /// `sink` (neither moving nor targeting).
    Guardian {
        sink: bool,
    },
    /// `Squid.travel`: it only moves by its motion.
    Squid,
    /// `Dolphin.travelInWater`: input at its speed, drag 0.9, sinking when
    /// `sink` (no target).
    Dolphin {
        sink: bool,
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
    /// The relative input (`xxa`, `yya`, `zza`) and speed the controls set.
    pub strafe: f32,
    pub up: f32,
    pub forward: f32,
    pub speed: f32,
    /// The inputs a move control of its own sets with `Control::Set`
    /// (`xxa`, `yya`, `zza`; none: `setSpeed` sets `zza` alone).
    pub set_inputs: [Option<f32>; 3],
    /// A goal moves it once before its travel (`BreathAirGoal.tick`:
    /// `moveRelative(0.02, input)` at the yaw it had then, and a move).
    pub pre_move: Option<f32>,
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
    /// A falling mob's vertical motion is scaled by this before the dead
    /// zone (a blaze's `aiStep`: 0.6; 1.0 for the rest).
    pub fall_scale: f64,
    /// The AI lifts the mob this tick, after the dead zone (a blaze's
    /// `customServerAiStep` toward a target's eyes above it).
    pub rise: bool,
    /// It walks on powder snow (`canEntityWalkOnPowderSnow`).
    pub powder_snow_walkable: bool,
    /// Its last move ended in powder snow (`wasInPowderSnow`).
    pub was_powder_snow: bool,
    /// It never moves and has no motion (a shulker's `getDeltaMovement`; a
    /// `NoAI` mob's, which does not travel).
    pub fixed: bool,
    /// Others push it (`isPushable`; a shulker's `push(Entity)` does nothing).
    pub pushable: bool,
    /// It pushes what it touches (`pushEntities`; a bat's does nothing).
    pub pushes: bool,
    /// A wall climber's `onClimbable` (VMC-043b4: a spider climbs while it
    /// bumped into something on its last move), in place of ladders; None
    /// for the others.
    pub wall_climb: Option<bool>,
    /// A rabbit's hopping controls (VMC-043c), or none.
    pub hop: Option<Hop>,
    pub travel: Travel,
    /// Flowing fluids push it (`isPushedByFluid`; not a water animal).
    pub fluid_pushed: bool,
    /// Motion its AI added after the dead zone (a move control's push).
    pub impulse: Vec<[f64; 3]>,
    /// Its last move was stopped vertically (`verticalCollision`).
    pub vertical_collision: bool,
    /// It counts the distance it moves for its steps and swim sounds (its
    /// movement emission is not `NONE`).
    pub emits: bool,
    /// The distance walked (`moveDist`) and where the next step falls.
    pub move_dist: f32,
    pub next_step: f32,
    /// A ghast's move control (`GhastMoveControl`), or none.
    pub float: Option<Float>,
    /// A slime's or magma cube's own jumps (`AbstractCubeMob`), or none.
    pub cube: Option<CubeJump>,
    /// Its own `nextStep` gap past the distance walked (a turtle's 0.15),
    /// else the next whole block.
    pub step_gap: Option<f32>,
    /// Out: its move made a step this tick.
    pub stepped: bool,
    /// It stands on lava (`canStandOnFluid`, a strider): lava sources hold
    /// it up, it travels in air in lava, and floats up out of it
    /// (`floatStrider`).
    pub lava_walker: bool,
}

/// `AbstractCubeMob.jumpFromGround`: its jump power plus `bonus` (a magma
/// cube's `size * 0.1F`), replacing its vertical motion; a magma cube's
/// `jumpInLiquid` in lava sets it to `lava`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CubeJump {
    pub bonus: f32,
    pub lava: Option<f32>,
}

/// A ghast's move control (`Ghast.GhastMoveControl`, not careful): every two
/// to six ticks a push toward where it wants to be, if nothing stands in the
/// way, else it stops wanting.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Float {
    /// Where it wants to be (`MOVE_TO`), or none (`WAIT`).
    pub wanted: Option<[f64; 3]>,
    /// `floatDuration`.
    pub duration: i32,
    /// The mob's random (a Java LCG's 48-bit seed), which the control draws on.
    pub random: u64,
    /// The push: `FLYING_SPEED * 5 / 3`.
    pub speed: f64,
}

/// `next(bits)` of a Java LCG seed.
fn java_next(seed: &mut u64, bits: u32) -> i32 {
    *seed = seed.wrapping_mul(0x5DEECE66D).wrapping_add(0xB) & ((1u64 << 48) - 1);
    ((*seed as i64) >> (48 - bits)) as i32
}

/// `nextInt(bound)` of a Java LCG seed.
fn java_int(seed: &mut u64, bound: i32) -> i32 {
    if bound & (bound - 1) == 0 {
        return ((bound as i64 * java_next(seed, 31) as i64) >> 31) as i32;
    }
    loop {
        let bits = java_next(seed, 31);
        let value = bits % bound;
        if bits.wrapping_sub(value).wrapping_add(bound - 1) >= 0 {
            return value;
        }
    }
}

/// `Vec3.normalize`.
fn normalize(v: [f64; 3]) -> [f64; 3] {
    let d = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    if d < 1.0e-5_f32 as f64 {
        [0.0; 3]
    } else {
        [v[0] / d, v[1] / d, v[2] / d]
    }
}

/// `GhastMoveControl.tick`: while it wants a place, every `floatDuration`
/// ticks a push of `speed` toward it, or giving up where the way is blocked.
fn float_control(w: &World, m: &mut Mob) -> Result<(), Fault> {
    let Some(mut f) = m.float else {
        return Ok(());
    };
    if let Some(wanted) = f.wanted {
        let before = f.duration;
        f.duration -= 1;
        if before <= 0 {
            f.duration += java_int(&mut f.random, 5) + 2;
            let travel = sub(wanted, m.position);
            if can_reach(w, m, travel)? {
                let n = normalize(travel);
                m.velocity = add(m.velocity, [n[0] * f.speed, n[1] * f.speed, n[2] * f.speed]);
            } else {
                f.wanted = None;
            }
        }
    }
    m.float = Some(f);
    Ok(())
}

/// `GhastMoveControl.canReach`: no block the box would pass on its way
/// (`forEachBlockIntersectedBetween`) collides with it moving there, those it
/// already touches aside.
fn can_reach(w: &World, m: &Mob, travel: [f64; 3]) -> Result<bool, Fault> {
    let start = m.position;
    let body = m.body(start)?;
    let destination = body.moved(travel);
    let Some(walk) = sweep::sweep(start, add(start, travel), &destination, usize::MAX) else {
        return Ok(false);
    };
    for (cell, _) in walk.visits {
        if body.intersects(&Aabb::block(cell[0], cell[1], cell[2])) {
            continue;
        }
        // A cell it cannot read (unloaded) is in the way.
        let Ok(state) = w.state(cell) else {
            return Ok(false);
        };
        let picked = w.facts.shapes.shape(state, cell, &Context::default());
        if picked.shape.is_empty() {
            continue;
        }
        let at = [
            cell[0] as f64 + picked.offset[0],
            cell[1] as f64 + picked.offset[1],
            cell[2] as f64 + picked.offset[2],
        ];
        let boxes: Vec<Aabb> = picked.shape.cells().iter().map(|b| b.moved(at)).collect();
        if sweep::collided_along(&body, travel, &boxes) {
            return Ok(false);
        }
    }
    Ok(true)
}

/// A rabbit's move and jump controls (`RabbitMoveControl`,
/// `RabbitJumpControl`, `Rabbit.getJumpPower` and `jumpFromGround`): it
/// moves only while it hops.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Hop {
    /// `LivingEntity.jumping`: set when a hop starts, cleared on landing or
    /// when the hop's duration ends (the AI's part).
    pub jumping: bool,
    /// The move control's wanted position and speed modifier, kept while it
    /// waits, and the speed of its next hop (`nextJumpSpeed`).
    pub wanted: [f64; 3],
    pub speed: f64,
    pub next_speed: f64,
    /// Its path's next node is more than half a block above it.
    pub path_up: bool,
    pub baby: bool,
    /// Out: the jump control started a hop (`startJumping`).
    pub started: bool,
    /// Out: it jumped off the ground (entity event 1).
    pub jumped: bool,
    /// Out: the speed modifier its move control gave its navigation.
    pub nav_speed: Option<f64>,
}

/// One tick's result: the mob after it and what its living rules read.
#[derive(Clone, Debug, PartialEq)]
pub struct Ticked {
    pub mob: Mob,
    pub water: bool,
    pub lava: bool,
    pub eye_water: bool,
    pub eye_state: u16,
    /// The same where the move left it: what the next tick's base tick
    /// reads before the AI (a dolphin's air).
    pub eye_after: (bool, u16),
    /// The swim sound a goal's own move made (`pre_move`).
    pub pre_swim: Option<f32>,
    /// Its move made a step (its family's step sound, `playStepSound`).
    pub step: bool,
    /// The block it stands on after the move (`getOnPosLegacy`), on the
    /// ground (`stepOn`: a turtle egg it may crush).
    pub on_block: Option<([i32; 3], u16)>,
    /// The landing block and fall distance (`Block.fallOn`), if it landed.
    pub landing: Option<(u16, f64)>,
    /// The landing block's cell (farmland's trampling, VMC-039a).
    pub landing_pos: Option<[i32; 3]>,
    pub touched: Touched,
    pub climbing: bool,
    /// Inside powder snow after the move (`isInPowderSnow`).
    pub powder_snow: bool,
    /// The fluid heights the move left (`checkFallDamage`'s sample), which
    /// the AI reads the next tick.
    pub depths: Depths,
    /// A swim sound's volume, when its move made one (`waterSwimSound`).
    pub swim: Option<f32>,
    /// The block it stands on after the move (`getBlockStateOnLegacy`,
    /// through its main supporting block; a strider's warmth, VMC-043d).
    pub support: u16,
    /// Its motion as it entered water during the move (`checkFallDamage`'s
    /// `doWaterSplashEffect`), if it did.
    pub splash: Option<[f64; 3]>,
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

/// `Rabbit.getJumpPower`: 0.3 of a jump, 0.2 at a stroll, 0.5 up a step
/// (its path's next node, a wall, or the wanted spot it jumps to).
fn hop_power(m: &Mob, hop: &Hop, at: [f64; 3], factor: f32) -> f32 {
    let mut base = if hop.speed <= 0.6 { 0.2_f32 } else { 0.3 };
    if hop.path_up || m.horizontal_collision || hop.jumping && hop.wanted[1] > at[1] + 0.5 {
        base = 0.5;
    }
    let bonus = if m.jump_boost < 0 {
        0.0
    } else {
        0.1 * (m.jump_boost as f32 + 1.0)
    };
    m.attributes.jump_strength as f32 * (base / 0.42) * factor + bonus
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
        Control::Strafe {
            forward,
            right,
            speed,
        } => {
            mob.speed = speed as f32 * attribute as f32;
            mob.forward = forward;
            mob.strafe = right;
            mob.control = Control::Wait;
            false
        }
        Control::Wait => {
            mob.forward = 0.0;
            false
        }
        Control::Hold => false,
        Control::Set { speed, .. } => {
            mob.speed = speed as f32;
            let [strafe, up, forward] = mob.set_inputs;
            mob.forward = forward.unwrap_or(mob.speed);
            mob.up = up.unwrap_or(mob.up);
            mob.strafe = strafe.unwrap_or(mob.strafe);
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
            powder_snow_walkable: self.powder_snow_walkable,
            lava_walker: self.lava_walker,
            noclip: None,
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

fn currents(
    w: &World,
    body: &Aabb,
    velocity: [f64; 3],
    pushed: bool,
) -> Result<(Depths, [f64; 3]), Fault> {
    if !rules::bounded(velocity, 64.0) {
        return Err(Fault::Limit("invalid_fluid_current"));
    }
    w.fluid_bounded(body)?;
    fluid::current(
        w.source,
        w.facts,
        body,
        velocity,
        pushed,
        false,
        Pushed::Item,
    )?
    .ok_or(Fault::Limit("invalid_fluid_box"))
}

/// One tick of `mob` (its pushes from others are applied by `tick_all`).
pub fn tick(w: &World, mob: &Mob) -> Result<Ticked, Fault> {
    if mob.fixed {
        return fixed(w, mob);
    }
    let mut m = mob.clone();
    let start = m.position;
    let body = m.body(start)?;
    // baseTick: the fluid state and its currents; water resets the fall,
    // lava halves it.
    let (depths, pushed) = currents(w, &body, m.velocity, m.fluid_pushed)?;
    m.velocity = pushed;
    let water = depths.water > 0.0;
    let lava = depths.lava > 0.0;
    if water {
        m.fall_distance = 0.0;
    }
    if lava {
        m.fall_distance *= 0.5;
    }
    // aiStep (a blaze slows its fall first).
    if !m.on_ground && m.velocity[1] < 0.0 {
        m.velocity[1] *= m.fall_scale;
    }
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
    // `customServerAiStep`'s lift: `(0.3F - y) * 0.3F` more.
    if m.rise {
        m.velocity[1] += (0.3_f32 as f64 - m.velocity[1]) * 0.3_f32 as f64;
    }
    // LivingEntity.baseTick's air reads the eye's fluid where the tick began.
    let eye = [start[0], start[1] + m.size.eye, start[2]];
    let (eye_water, _) = w.eyes(&body, eye)?;
    let eye_state = w.state(eye.map(|v| v.floor() as i32))?;
    // A goal's own move before the move control (`BreathAirGoal.tick`):
    // the rest of the tick travels from where it left the mob.
    let mut pre_swim = None;
    let (start, body) = if let Some(yaw) = m.pre_move.take() {
        let input = [m.strafe as f64, m.up as f64, m.forward as f64];
        m.velocity = add(m.velocity, input_vector(input, 0.02, yaw));
        let fall = m.fall_distance;
        pre_swim = mob_move(w, &mut m, &body, fall, water, depths)?.swim;
        let moved = m.position;
        (moved, m.body(moved)?)
    } else {
        (start, body)
    };
    // The AI's move control (a fish's): its eyes in water lift it, then its
    // push toward its target.
    if let Control::Set { lift: true, .. } = m.control {
        if eye_water {
            m.velocity[1] += 0.005;
        }
    }
    // Each add of its move control in order (a turtle's lift, then its push).
    for push in std::mem::take(&mut m.impulse) {
        m.velocity = add(m.velocity, push);
    }
    let block = feet_block(w, &m)?;
    // A rabbit's move control picks its speed before it moves: none on the
    // ground between hops.
    if let Some(hop) = m.hop.as_mut() {
        hop.started = false;
        hop.jumped = false;
        hop.nav_speed = None;
        let speed = if m.on_ground && !hop.jumping && !m.jump {
            Some(0.0)
        } else if matches!(m.control, Control::MoveTo { .. } | Control::Jumping { .. }) {
            Some(hop.next_speed)
        } else {
            None
        };
        if let Some(speed) = speed {
            hop.nav_speed = Some(speed);
            let speed = if water { 1.5 } else { speed };
            hop.speed = speed;
            if speed > 0.0 {
                hop.next_speed = speed;
            }
            m.control = match m.control {
                Control::Jumping { .. } => Control::Jumping { speed },
                _ => Control::MoveTo {
                    target: hop.wanted,
                    speed,
                },
            };
        }
    }
    // `JumpControl.tick`: the move control's jump or the AI's. The head is
    // the look control's (the AI's), before this tick. A rabbit's starts a
    // hop, which keeps it jumping.
    // A ghast's own move control replaces it (VMC-043d).
    let asked = if m.float.is_some() {
        float_control(w, &mut m)?;
        m.jump
    } else {
        control(&mut m, block, water || lava) || m.jump
    };
    let jumping = match m.hop.as_mut() {
        Some(hop) => {
            if asked {
                hop.jumping = true;
                hop.started = true;
            }
            hop.jumping
        }
        None => asked,
    };
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
                    let power = match &m.hop {
                        Some(hop) => hop_power(&m, hop, start, factor),
                        None => jump_power(m.attributes.jump_strength, factor, m.jump_boost),
                    };
                    if let Some(cube) = m.cube {
                        m.velocity[1] = (power + cube.bonus) as f64;
                    } else if power > 1.0e-5 {
                        m.velocity[1] = m.velocity[1].max(power as f64);
                    }
                    if let Some(hop) = m.hop.as_mut() {
                        // `Rabbit.jumpFromGround`: a standing hop pushes it on.
                        let [vx, _, vz] = m.velocity;
                        if hop.speed > 0.0 && vx * vx + vz * vz < 0.01 {
                            let up = if hop.baby { 0.5 } else { 1.5 };
                            m.velocity = add(m.velocity, input_vector([0.0, up, 1.0], 0.1, m.yaw));
                        }
                        hop.jumped = true;
                    }
                    m.no_jump_delay = 10;
                }
            } else if let Some(lava) = m.cube.and_then(|c| c.lava) {
                m.velocity[1] = lava as f64;
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
    let input = [m.strafe as f64, m.up as f64, m.forward as f64];
    let climbing_before = match m.wall_climb {
        Some(climbing) => climbing,
        None => {
            contacts::climb(
                w.source,
                w.facts,
                start.map(|v| v.floor() as i32),
                false,
                false,
                false,
            )?
            .0
        }
    };
    let before = w.material(&body, start, &m.context(m.fall_distance, start[1]))?;
    // `travel`: in a fluid it can stand on (a strider in lava) it travels
    // as in air.
    let stands = m.lava_walker
        && w.facts
            .fluid(w.state(start.map(|v| v.floor() as i32))?)
            .kind
            == crate::physics::facts::LAVA;
    let in_fluid = (water || lava) && !stands;
    // travel: the relative input, then the move.
    let falling = m.velocity[1] <= 0.0;
    let fluid_gravity = m.gravity(m.velocity[1]);
    let friction = if m.on_ground {
        modified_friction(before.below.friction, m.attributes.friction_modifier as f32)
    } else {
        1.0
    };
    // A fish or guardian in water travels its own way; a squid only moves.
    let own_water = water
        && matches!(
            m.travel,
            Travel::Fish { .. } | Travel::Guardian { .. } | Travel::Dolphin { .. }
        );
    let squid = m.travel == Travel::Squid;
    let speed = if own_water {
        match m.travel {
            Travel::Guardian { .. } => 0.1_f32,
            Travel::Dolphin { .. } => m.speed,
            _ => 0.01_f32,
        }
    } else if in_fluid {
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
    // `travelFlying` (a ghast's, VMC-043d): input at 0.02 in water, lava and
    // air alike.
    let flying = m.travel == Travel::Flying;
    let speed = if flying { 0.02 } else { speed };
    if !squid {
        m.velocity = add(m.velocity, input_vector(input, speed, m.yaw));
    }
    let mut fall = m.fall_distance;
    if !in_fluid && !squid && !flying {
        let (v, reset) = rules::climb_prepare(m.velocity, climbing_before, false, false)?;
        m.velocity = v;
        if reset {
            fall = 0.0;
        }
    }
    let was_on_ground = m.on_ground;
    let mut moved = mob_move(w, &mut m, &body, fall, water, depths)?;
    // A flier never falls (a ghast's `checkFallDamage` does nothing).
    if flying {
        m.fall_distance = 0.0;
        moved.landing = None;
    }
    // A strider's `checkFallDamage` in lava resets its fall.
    if m.lava_walker && lava {
        m.fall_distance = 0.0;
        moved.landing = None;
    }
    let after_body = m.body(m.position)?;
    let climbing = match m.wall_climb {
        Some(climbing) => climbing,
        None => {
            contacts::climb(
                w.source,
                w.facts,
                m.position.map(|v| v.floor() as i32),
                false,
                false,
                false,
            )?
            .0
        }
    };
    m.velocity = if squid {
        m.velocity
    } else if own_water {
        let sink = match m.travel {
            Travel::Fish { sink } | Travel::Guardian { sink } | Travel::Dolphin { sink } => sink,
            _ => false,
        };
        let v = m.velocity.map(|c| c * 0.9);
        if sink {
            // `add(0.0, -0.005, 0.0)`: a -0.0 left by a wall turns +0.0.
            [v[0] + 0.0, v[1] - 0.005, v[2] + 0.0]
        } else {
            v
        }
    } else if flying {
        // `travelFlying`'s drag: water's 0.8F, lava's 0.5, air's 0.91F.
        let drag = if water {
            0.8_f32 as f64
        } else if lava {
            0.5
        } else {
            0.91_f32 as f64
        };
        [
            m.velocity[0] * drag,
            m.velocity[1] * drag,
            m.velocity[2] * drag,
        ]
    } else if in_fluid {
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
        // A powder snow walker climbs out of the snow it was in.
        let climbs = climbing || m.was_powder_snow && m.powder_snow_walkable;
        let finished = rules::climb_finish(m.velocity, climbs, m.horizontal_collision, jumping)?;
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
    // `Strider.floatStrider` after its tick: in lava (as its base tick
    // found it, or its move's fall check re-sampled it), above the half
    // block with no lava over it, it stands; else it slows and rises.
    if m.lava_walker && moved.depths.lava > 0.0 {
        let cell = m.position.map(|v| v.floor() as i32);
        let above = w.state([cell[0], cell[1] + 1, cell[2]])?;
        if m.position[1] > cell[1] as f64 + 0.5 - 1.0e-5_f32 as f64
            && w.facts.fluid(above).kind != crate::physics::facts::LAVA
        {
            m.on_ground = true;
        } else {
            let [vx, vy, vz] = m.velocity;
            m.velocity = [vx * 0.5, vy * 0.5 + 0.05, vz * 0.5];
        }
    }
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
    let Slowing {
        multiplier,
        last,
        powder_snow,
    } = contacts::slowing(
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
    let step = std::mem::take(&mut m.stepped);
    let on_block = if m.on_ground {
        Some(moved.material.legacy)
    } else {
        None
    };
    let eye_after = [m.position[0], m.position[1] + m.size.eye, m.position[2]];
    let eye_after = (
        w.eyes(&after_body, eye_after)?.0,
        w.state(eye_after.map(|v| v.floor() as i32))?,
    );
    Ok(Ticked {
        mob: m,
        water: water || moved.depths.water > 0.0,
        lava,
        eye_water,
        eye_state,
        eye_after,
        pre_swim,
        step,
        on_block,
        landing: moved.landing,
        landing_pos: moved.landing.map(|_| moved.material.legacy.0),
        support: moved.material.legacy.1,
        touched,
        climbing,
        powder_snow,
        depths: moved.depths,
        swim: moved.swim,
        splash: moved.splash,
    })
}

/// A mob that never moves: its fluid state for the living rules, nothing
/// else.
fn fixed(w: &World, mob: &Mob) -> Result<Ticked, Fault> {
    let mut m = mob.clone();
    m.velocity = [0.0; 3];
    let body = m.body(m.position)?;
    let (depths, _) = currents(w, &body, m.velocity, m.fluid_pushed)?;
    let eye = [m.position[0], m.position[1] + m.size.eye, m.position[2]];
    let (eye_water, _) = w.eyes(&body, eye)?;
    let eye_state = w.state(eye.map(|v| v.floor() as i32))?;
    m.forward = 0.0;
    m.strafe = 0.0;
    m.jump = false;
    m.control = Control::Wait;
    let support = w.state([
        m.position[0].floor() as i32,
        (m.position[1] - 0.2_f32 as f64).floor() as i32,
        m.position[2].floor() as i32,
    ])?;
    Ok(Ticked {
        mob: m,
        water: depths.water > 0.0,
        lava: depths.lava > 0.0,
        eye_water,
        eye_state,
        eye_after: (eye_water, eye_state),
        pre_swim: None,
        step: false,
        on_block: None,
        landing: None,
        landing_pos: None,
        touched: Touched::default(),
        climbing: false,
        powder_snow: false,
        depths,
        swim: None,
        support,
        splash: None,
    })
}

/// What `Entity.move` did.
struct Moved {
    swim: Option<f32>,
    splash: Option<[f64; 3]>,
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
    // The server's own mobs always settle their ground state
    // (`isLocalInstanceAuthoritative`), still or not.
    let vertical = requested[1] != actual[1];
    m.vertical_collision = vertical;
    m.on_ground = vertical && requested[1] < 0.0;
    let after_body = m.body(m.position)?;
    let material = w.material_moved(
        &after_body,
        m.position,
        m.on_ground.then_some(actual),
        &m.context(fall, m.position[1]),
    )?;
    // checkFallDamage re-samples the fluid state (and its currents) when not
    // in water before.
    let mut splash = None;
    // A strider in lava resets its fall instead (`Strider.checkFallDamage`).
    let depths = if water_before || m.lava_walker && depths_before.lava > 0.0 {
        depths_before
    } else {
        let before = m.velocity;
        let (depths, pushed) = currents(w, &after_body, m.velocity, m.fluid_pushed)?;
        m.velocity = pushed;
        if depths.water > 0.0 {
            splash = Some(before);
        }
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
    let swim = if m.emits {
        emission(w, m, actual, water)?
    } else {
        None
    };
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
        swim,
        splash,
    })
}

/// `applyMovementEmissionAndPlaySound`: the distance moved (all of it while
/// climbing, else across), and past the next step over a block that is not
/// air, a step (no draw) on the ground or climbing, or in water a swim
/// sound, whose volume follows the motion.
fn emission(w: &World, m: &mut Mob, actual: [f64; 3], water: bool) -> Result<Option<f32>, Fault> {
    let moved = ((actual[0] * actual[0] + actual[1] * actual[1] + actual[2] * actual[2]).sqrt()
        * 0.6_f32 as f64) as f32;
    let across = ((actual[0] * actual[0] + actual[2] * actual[2]).sqrt() * 0.6_f32 as f64) as f32;
    let p = m.position;
    let below = [
        p[0].floor() as i32,
        (p[1] - 1.0e-5_f32 as f64).floor() as i32,
        p[2].floor() as i32,
    ];
    let state = w.state(below)?;
    let climbing = contacts::climb(w.source, w.facts, below, false, false, false)?.0;
    m.move_dist += if climbing { moved } else { across };
    let air = w.facts.flags(state) & 1 != 0;
    if m.move_dist <= m.next_step || air {
        return Ok(None);
    }
    if m.on_ground || climbing {
        m.next_step = next_step(m);
        m.stepped = true;
        return Ok(None);
    }
    if !water {
        return Ok(None);
    }
    m.next_step = next_step(m);
    let v = m.velocity;
    let speed = (v[0] * v[0] * 0.2_f32 as f64 + v[1] * v[1] + v[2] * v[2] * 0.2_f32 as f64).sqrt();
    Ok(Some((speed as f32 * 0.35).min(1.0)))
}

/// `Entity.nextStep`: the next whole block, or a family's own gap.
fn next_step(m: &Mob) -> f32 {
    match m.step_gap {
        Some(gap) => m.move_dist + gap,
        None => (m.move_dist as i32 + 1) as f32,
    }
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

/// One step's result: the ticked mob, and the mobs it pushed with their new
/// motion.
pub type Stepped = (Result<Ticked, Fault>, Vec<(usize, [f64; 3])>);

/// The mobs of an owner as they tick one at a time, in order (VMC-043e):
/// each travels with what its AI decided, then pushes the pushable mobs it
/// touches and is pushed by them (`LivingEntity.pushEntities`), and by the
/// players it touches. Mobs meet only within neighbouring cells of a grid
/// as wide as the widest mob, so pushing costs what is near. The owner's AI
/// thinks between steps, reading each mob's motion as the pushes so far
/// left it.
pub struct Ticker {
    pub current: Vec<Mob>,
    cell: f64,
    grid: HashMap<(i64, i64), Vec<usize>>,
    cells: Vec<(i64, i64)>,
}

impl Ticker {
    pub fn new(mobs: Vec<Mob>) -> Ticker {
        let cell = mobs.iter().map(|m| m.size.width).fold(2.0_f64, f64::max);
        let mut t = Ticker {
            current: mobs,
            cell,
            grid: HashMap::new(),
            cells: Vec::new(),
        };
        for i in 0..t.current.len() {
            let k = t.key(t.current[i].position);
            t.grid.entry(k).or_default().push(i);
            t.cells.push(k);
        }
        t
    }

    fn key(&self, p: [f64; 3]) -> (i64, i64) {
        (
            (p[0] / self.cell).floor() as i64,
            (p[2] / self.cell).floor() as i64,
        )
    }

    /// Move mob `i` to where it is now (a teleport, or its own move).
    pub fn place(&mut self, i: usize, mob: Mob) {
        let k = self.key(mob.position);
        if k != self.cells[i] {
            if let Some(v) = self.grid.get_mut(&self.cells[i]) {
                v.retain(|&j| j != i);
            }
            self.grid.entry(k).or_default().push(i);
            self.cells[i] = k;
        }
        self.current[i] = mob;
    }

    /// Mob `i`'s tick with `mob` (its AI's input): its travel, then its
    /// pushes. The ticked mob carries its motion after its own pushes; the
    /// mobs it pushed come back with their new motion.
    pub fn step(&mut self, w: &World, i: usize, mob: Mob, players: &[([f64; 3], Aabb)]) -> Stepped {
        self.place(i, mob);
        let mut result = tick(w, &self.current[i]);
        if let Ok(t) = &result {
            self.place(i, t.mob.clone());
        }
        let pushed = self.pushes(i, players);
        if let Ok(t) = &mut result {
            t.mob.velocity = self.current[i].velocity;
        }
        (result, pushed)
    }

    fn pushes(&mut self, i: usize, players: &[([f64; 3], Aabb)]) -> Vec<(usize, [f64; 3])> {
        let mut pushed = Vec::new();
        if !self.current[i].alive || !self.current[i].pushes {
            return pushed;
        }
        let Ok(own) = self.current[i].body(self.current[i].position) else {
            return pushed;
        };
        let (cx, cz) = self.cells[i];
        let mut near: Vec<usize> = (cx - 1..=cx + 1)
            .flat_map(|x| (cz - 1..=cz + 1).map(move |z| (x, z)))
            .filter_map(|k| self.grid.get(&k))
            .flatten()
            .copied()
            .filter(|&j| j != i && self.current[j].alive && self.current[j].pushable)
            .collect();
        near.sort_unstable();
        // A player it touches pushes it away (`player.push(self)`); players
        // come first in the level's entities, as they joined first.
        for (feet, player) in players {
            if self.current[i].pushable && own.intersects(player) {
                if let Some(p) = push(*feet, self.current[i].position) {
                    self.current[i].velocity = add(self.current[i].velocity, p);
                }
            }
        }
        for j in near {
            let Ok(other) = self.current[j].body(self.current[j].position) else {
                continue;
            };
            if !own.intersects(&other) {
                continue;
            }
            // `other.push(self)`: the other moves away, then this one.
            if let Some(p) = push(self.current[i].position, self.current[j].position) {
                self.current[j].velocity = add(self.current[j].velocity, p);
                self.current[i].velocity = sub(self.current[i].velocity, p);
                pushed.push((j, self.current[j].velocity));
            }
        }
        pushed
    }

    /// The players' own pushes, after every mob moved; each mob's motion
    /// for its next tick (a fixed mob has none).
    pub fn finish(mut self, players: &[([f64; 3], Aabb)]) -> Vec<[f64; 3]> {
        for (feet, player) in players {
            for m in self.current.iter_mut().filter(|m| m.alive && m.pushable) {
                let Ok(b) = m.body(m.position) else { continue };
                if b.intersects(player) {
                    if let Some(p) = push(*feet, m.position) {
                        m.velocity = add(m.velocity, p);
                    }
                }
            }
        }
        self.current
            .iter()
            .map(|m| if m.fixed { [0.0; 3] } else { m.velocity })
            .collect()
    }
}

/// One tick of every mob of an owner, in order, with no AI between them
/// (`Ticker`'s steps): each mob's result carries its motion for its next
/// tick. A mob the kernel cannot tick keeps its state (`Err`).
pub fn tick_all(
    w: &World,
    mobs: &[Mob],
    players: &[([f64; 3], Aabb)],
) -> Vec<Result<Ticked, Fault>> {
    let mut ticker = Ticker::new(mobs.to_vec());
    let mut out: Vec<Result<Ticked, Fault>> = Vec::with_capacity(mobs.len());
    for i in 0..mobs.len() {
        let mob = ticker.current[i].clone();
        out.push(ticker.step(w, i, mob, players).0);
    }
    let velocities = ticker.finish(players);
    for (result, velocity) in out.iter_mut().zip(velocities) {
        if let Ok(t) = result {
            t.mob.velocity = velocity;
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
            fall_scale: 1.0,
            rise: false,
            powder_snow_walkable: false,
            was_powder_snow: false,
            fixed: false,
            pushable: true,
            pushes: true,
            wall_climb: None,
            hop: None,
            up: 0.0,
            set_inputs: [None; 3],
            pre_move: None,
            step_gap: None,
            stepped: false,
            travel: Travel::Ground,
            fluid_pushed: true,
            impulse: Vec::new(),
            vertical_collision: false,
            emits: true,
            move_dist: 0.0,
            next_step: 1.0,
            float: None,
            cube: None,
            lava_walker: false,
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
