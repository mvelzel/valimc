//! Endermen (`Valimc.AI.Mobs.Enderman`, vanilla's `EnderMan`):
//!
//! - **Goals**: floating, freezing while its target player stares at it,
//!   melee, wandering (never preferring a spot) and looking around, putting
//!   down and picking up blocks; as targets a player who stares at it or
//!   whom it is angry at (`LookForPlayer`), whoever hurt it, endermites, and
//!   universal anger (`NeutralMob`, 20 to 39 seconds).
//! - **Staring**: a player within its follow range who looks into its eyes
//!   (`isLookingAtMe`: a narrowing cone and line of sight, no disguise on
//!   the head) angers it after a few ticks; stared at from close by it
//!   teleports away, and far from its target it teleports toward it.
//! - **Teleporting** (`randomTeleport`): down from a random spot up to 32
//!   blocks away to a block entities may teleport onto (not one endermen
//!   avoid), where it fits out of liquids and not above water; the trail
//!   (level event 2018) and the sound at both ends. By day in the open a
//!   bright spot sends it away; projectiles never hurt it (it teleports
//!   instead), and other hurts without a living attacker usually do.
//! - **Blocks**: while mobs may grief it now and then picks up a block it
//!   can reach within two blocks that endermen hold (an outline ray from its
//!   column), and later puts it down where it fits; a carried block drops on
//!   death as if mined with Silk Touch.
//!
//! A hurt's reaction waits in its mind's own fields (`EndermanOwn`) for its
//! next tick, as the Elixir's `own.hurt`.

use super::{entity, fields, flag, int, item_tag, value};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{self, f, floor};
use crate::mobs::ai::goal::{Goal, JUMP, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::neutral;
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::target::{self as target_goal, TargetFields, TargetOptions};
use crate::mobs::ai::goals::{
    Float, HurtByTarget, LookAtPlayer, MeleeAttack, MobTypes, NearestAttackableTarget,
    RandomLookAround, RandomStroll, ResetUniversalAnger, TargetKind,
};
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::navigation;
use crate::mobs::ai::turn::{Eyes, Seen, Targeting, Turn};
use crate::mobs::ai::Extra;
use crate::mobs::combat::{Event, Family, Hit};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, Registered, Registration};
use crate::mobs::level::{FluidKind, Level, AIR};
use crate::mobs::model::{Body, FamilyData, Number};
use crate::mobs::sensing::{intersects, Entity, Kind as RefKind, Ref, SensedPlayer};
use crate::mobs::term::{Atom, Value, NIL};
use crate::physics::Aabb;
use std::sync::Arc;

pub const ENDERMAN: &str = "minecraft:enderman";

/// `PERSISTENT_ANGER_TIME`: 20 to 39 seconds.
const ANGER: (i64, i64) = (400, 780);
const SPEED: &str = "minecraft:movement_speed";
const ATTACKING: &str = "minecraft:attacking";
/// The flag bit of a block whose collision fills its cell.
const FULL_COLLISION: u32 = 23;

/// A hurt's reaction on its next tick.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reaction {
    /// A projectile: 64 tries to teleport away.
    Away,
    /// A hurt without a living attacker: nine times in ten one try.
    Maybe,
}

/// An enderman's own mind fields beside its anger (`own.hurt`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct EndermanOwn {
    pub hurt: Option<Reaction>,
}

/// The enderman family.
pub struct Enderman {
    types: [&'static str; 1],
    endermite: u16,
    shared: Arc<Shared>,
}

/// What an enderman's rules and goals read (its goals hold it too).
#[derive(Debug, PartialEq)]
pub struct Shared {
    disguises: Vec<i32>,
    /// Blocks entities may teleport onto, endermen's avoided ones and the
    /// ones they hold (block registry ids).
    onto: Vec<i32>,
    avoided: Vec<i32>,
    holdable: Vec<i32>,
    bedrock: u16,
    /// Damage types tagged `is_projectile`.
    projectiles: Vec<i32>,
    scream: i32,
    teleport_sound: i32,
    /// Each holdable block's states and its item (`first`, `last`, item).
    drops: Vec<(u16, u16, i32)>,
}

impl Enderman {
    pub fn new(facts: &MobFacts) -> Result<Enderman, String> {
        let blocks = |tag: &str| {
            facts
                .tags
                .get("minecraft:block", tag)
                .map(<[i32]>::to_vec)
                .unwrap_or_default()
        };
        let holdable = blocks("minecraft:enderman_holdable");
        let drops = holdable
            .iter()
            .filter_map(|&id| {
                let block = facts.blocks.block(id as u16)?;
                let item = facts.items.id(&block.name)?;
                Some((block.first, block.last, item))
            })
            .collect();
        let shared = Shared {
            drops,
            disguises: item_tag(facts, "minecraft:gaze_disguise_equipment"),
            onto: blocks("minecraft:entities_can_teleport_to"),
            avoided: blocks("minecraft:enderman_does_not_teleport_to"),
            holdable,
            bedrock: facts
                .blocks
                .default_state("minecraft:bedrock")
                .ok_or("no bedrock")?,
            projectiles: facts
                .tags
                .get("minecraft:damage_type", "minecraft:is_projectile")
                .map(<[i32]>::to_vec)
                .unwrap_or_default(),
            scream: super::sound(facts, "minecraft:entity.enderman.scream")?,
            teleport_sound: super::sound(facts, "minecraft:entity.enderman.teleport")?,
        };
        Ok(Enderman {
            types: [ENDERMAN],
            endermite: entity(facts, "minecraft:endermite")?,
            shared: Arc::new(shared),
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[
            ("carried", NIL),
            ("creepy", Value::bool(false)),
            ("stared_at", Value::bool(false)),
            ("ticks", Value::Int(0)),
            ("target_time", Value::Int(0)),
        ])
    }
}

impl Shared {
    fn block_in(&self, level: &Level, state: u16, tag: &[i32]) -> bool {
        level
            .facts
            .blocks
            .block_id(state)
            .is_some_and(|id| tag.contains(&(id as i32)))
    }
}

// ## Staring

/// `Entity.calculateViewVector(pitch, yaw)`.
fn view_vector(pitch: f64, yaw: f64) -> [f64; 3] {
    let radians = f(std::f64::consts::PI / 180.0);
    let x_rot = f(f(pitch) * radians);
    let y_rot = f(-f(yaw) * radians);
    let (y_cos, y_sin) = (fmath::cos(y_rot), fmath::sin(y_rot));
    let (x_cos, x_sin) = (fmath::cos(x_rot), fmath::sin(x_rot));
    [f(y_sin * x_cos), -x_sin, f(y_cos * x_cos)]
}

/// `Vec3.normalize`: zero below 1.0e-5.
fn normalize([x, y, z]: [f64; 3]) -> [f64; 3] {
    let length = (x * x + y * y + z * z).sqrt();
    if length < 1.0e-5 {
        [0.0; 3]
    } else {
        [x / length, y / length, z / length]
    }
}

impl Shared {
    /// `isBeingStaredBy`: a player without a disguise on its head looking
    /// into its eyes (`isLookingAtMe(player, 0.025, true, false, eyeY)`), the
    /// enderman at `position` with its eyes at `gaze`.
    fn stared_by(&self, level: &Level, position: [f64; 3], gaze: f64, p: &SensedPlayer) -> bool {
        if p.equipped(crate::mobs::facts::Slot::Head)
            .is_some_and(|head| self.disguises.contains(&head))
        {
            return false;
        }
        let [lx, ly, lz] = normalize(view_vector(p.pitch, p.yaw));
        let [px, py, pz] = p.position;
        let peye = py + p.eye;
        let d = [position[0] - px, gaze - peye, position[2] - pz];
        let distance = (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).sqrt();
        let [nx, ny, nz] = normalize(d);
        let dot = lx * nx + ly * ny + lz * nz;
        dot > 1.0 - 0.025 / distance
            && crate::mobs::sensing::sight::line_of_sight(
                level,
                [px, peye, pz],
                [position[0], gaze, position[2]],
            )
    }

    /// `stared_by?/2` of a sensed target (only a player stares).
    fn stared_by_ref(&self, t: &Turn, r: &Ref) -> bool {
        if r.kind != RefKind::Player {
            return false;
        }
        match t.sensing.players.iter().find(|p| p.uuid == r.uuid) {
            Some(p) => self.stared_by(t.level, t.pos(), t.eye_y(), p),
            None => false,
        }
    }

    /// `inducing?/2`: a player who stares at it or whom it is angry at.
    fn inducing(&self, level: &Level, eyes: &Eyes, target: Entity<'_, Extra>) -> bool {
        let stared = match target {
            Entity::Player(p) => self.stared_by(level, eyes.position, eyes.eye_y, p),
            _ => false,
        };
        stared || neutral::angry_at(level, eyes, target)
    }
}

/// The attacking speed modifier (+0.15) on or off: one already there stays
/// where it is.
fn modify(t: &mut Turn, on: bool) {
    let attributes = &mut t.mob.body.mob.attributes;
    let present = attributes
        .get(SPEED)
        .is_some_and(|o| o.modifiers.iter().any(|m| m.id == ATTACKING));
    if on && present {
        return;
    }
    let add = on.then_some((Number::Float(f(0.15)), 0));
    attributes.toggle(SPEED, ATTACKING, add);
}

impl Shared {
    // ## Teleporting

    /// `repeatedlyTryToTeleport`: up to 64 tries.
    fn away(&self, t: &mut Turn) {
        for _ in 0..64 {
            if self.teleport(t) {
                return;
            }
        }
    }

    /// `teleport()`: a random spot up to 32 blocks away.
    pub fn teleport(&self, t: &mut Turn) -> bool {
        if !crate::mobs::living::mob::alive(&t.mob.body.mob) {
            return false;
        }
        let a = t.double();
        let n = t.int(64);
        let b = t.double();
        let [x, y, z] = t.pos();
        self.teleport_to(
            t,
            [
                x + (a - 0.5) * 64.0,
                y + (n - 32) as f64,
                z + (b - 0.5) * 64.0,
            ],
        )
    }

    /// `teleportTowards`: a spot about 16 blocks toward `target`.
    fn teleport_towards(&self, t: &mut Turn, target: &Seen) -> bool {
        let [x, y, z] = t.pos();
        let [dx, dy, dz] = normalize([
            x - target.x(),
            y + t.height * 0.5 - target.eye_y(),
            z - target.z(),
        ]);
        let a = t.double();
        let n = t.int(16);
        let b = t.double();
        self.teleport_to(
            t,
            [
                x + (a - 0.5) * 8.0 - dx * 16.0,
                y + (n - 8) as f64 - dy * 16.0,
                z + (b - 0.5) * 8.0 - dz * 16.0,
            ],
        )
    }

    // `teleport(x, y, z)` through `randomTeleport`, down the column to the
    // first block entities may teleport onto.
    fn teleport_to(&self, t: &mut Turn, [x, y, z]: [f64; 3]) -> bool {
        let (x, z) = match t.level.border {
            None => (x, z),
            Some([min_x, min_z, max_x, max_z]) => (
                fmath::emin(fmath::emax(x, min_x), max_x - 1.0e-5),
                fmath::emin(fmath::emax(z, min_z), max_z - 1.0e-5),
            ),
        };
        let (bx, mut by, bz) = (floor(x), floor(y), floor(z));
        if t.level.block([bx, by, bz]).is_none() {
            return false;
        }
        let mut y = y;
        loop {
            let below = by - 1;
            if below < t.level.min_y {
                return false;
            }
            let Some(state) = t.level.block([bx, below, bz]) else {
                return false;
            };
            if self.block_in(t.level, state, &self.onto) {
                return self.place(t, [x, y, z], state);
            }
            y -= 1.0;
            by = below;
        }
    }

    // `checkPositionAndTeleport`.
    fn place(&self, t: &mut Turn, [x, y, z]: [f64; 3], onto: u16) -> bool {
        let w = t.width / 2.0;
        let b = Aabb {
            min: [x - w, y, z - w],
            max: [x + w, y + t.height, z + w],
        };
        let level = &*t.level;
        let ok = !self.block_in(level, onto, &self.avoided)
            && level.fits(&b)
            && !liquid(level, &b)
            && !self.avoided_in(level, &b)
            && !water_below(level, [x, y, z]);
        if ok {
            self.moved(t, [x, y, z]);
        }
        ok
    }

    fn avoided_in(&self, level: &Level, b: &Aabb) -> bool {
        for x in floor(b.min[0])..=floor(b.max[0]) {
            for y in floor(b.min[1])..=floor(b.max[1]) {
                for z in floor(b.min[2])..=floor(b.max[2]) {
                    if level
                        .block([x, y, z])
                        .is_some_and(|s| self.block_in(level, s, &self.avoided))
                    {
                        return true;
                    }
                }
            }
        }
        false
    }

    // It moves there (entity event 46, its navigation stopped); the trail
    // from its old block (level event 2018) and the sound where it was and
    // where it is.
    fn moved(&self, t: &mut Turn, [x, y, z]: [f64; 3]) {
        let old = t.block();
        let new = [floor(x), floor(y), floor(z)];
        // `BlockUtil.clampedPackDifferenceInPosition(old, new, 127, 127, 127)`.
        let clamp = |d: i32| (d.clamp(-127, 127) + 127) & 255;
        let packed =
            (clamp(new[0] - old[0]) << 16) | (clamp(new[1] - old[1]) << 8) | clamp(new[2] - old[2]);
        t.effect(Effect::SoundAt {
            id: self.teleport_sound,
            source: "hostile",
            at: t.pos(),
            volume: 1.0,
            pitch: 1.0,
        });
        t.mob.position = [x, y, z];
        t.mind.snapped = Some([x, z]);
        t.effect(Effect::Event(46));
        navigation::stop(t);
        t.effect(Effect::LevelEvent {
            cell: old,
            kind: 2018,
            data: packed,
        });
        t.sound_id(self.teleport_sound, 1.0, 1.0);
    }
}

// Liquid in a cell the box covers.
fn liquid(level: &Level, b: &Aabb) -> bool {
    let cells = |lo: f64, hi: f64| floor(lo)..=(hi.ceil() as i32 - 1);
    for x in cells(b.min[0], b.max[0]) {
        for y in cells(b.min[1], b.max[1]) {
            for z in cells(b.min[2], b.max[2]) {
                if level
                    .block([x, y, z])
                    .is_some_and(|s| level.fluid_of(s) != FluidKind::Empty)
                {
                    return true;
                }
            }
        }
    }
    false
}

// `canRandomlyTeleportTo`: not onto water.
fn water_below(level: &Level, [x, y, z]: [f64; 3]) -> bool {
    level
        .block([floor(x), floor(y) - 1, floor(z)])
        .is_some_and(|s| level.fluid_of(s) == FluidKind::Water)
}

// A hurt's reaction for its next tick (only a mind that thought keeps one).
fn react(body: &mut Body, reaction: Reaction) {
    let Some(state) = body.mob.ai.as_mut().and_then(|m| m.state.as_mut()) else {
        return;
    };
    let own = &mut state.own;
    match own.family_mut::<EndermanOwn>() {
        Some(o) => o.hurt = Some(reaction),
        None => {
            own.family = Some(Box::new(EndermanOwn {
                hurt: Some(reaction),
            }))
        }
    }
}

impl Hooks for Enderman {
    /// `setTarget`: a target makes it creepy, adds the attacking speed and
    /// notes the time; none clears both flags and the speed.
    fn set_target(&self, t: &mut Turn, target: Option<Ref>) -> bool {
        t.put_target(target);
        let data = &mut t.mob.body.data;
        match target {
            None => {
                data.set("target_time", Value::Int(0));
                data.set("creepy", Value::bool(false));
                data.set("stared_at", Value::bool(false));
                modify(t, false);
            }
            Some(_) => {
                let ticks = int(data, "ticks");
                data.set("target_time", Value::Int(ticks));
                data.set("creepy", Value::bool(true));
                modify(t, true);
            }
        }
        true
    }

    /// `getWalkTargetValue`: no spot is better than another.
    fn walk_value(&self, _t: &mut Turn, _pos: [i32; 3]) -> Option<f64> {
        Some(0.0)
    }
}

impl Family for Enderman {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Enderman::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let data = &body.data;
        vec![
            value(
                "enderman_carry_state",
                data.get("carried").cloned().unwrap_or(NIL),
                NIL,
            ),
            value(
                "enderman_creepy",
                Value::bool(flag(data, "creepy")),
                Value::bool(false),
            ),
            value(
                "enderman_stared_at",
                Value::bool(flag(data, "stared_at")),
                Value::bool(false),
            ),
        ]
    }

    /// Projectiles never hurt it (`hurtServer`).
    fn ignores(&self, _body: &Body, hit: &Hit) -> bool {
        self.shared.projectiles.contains(&(hit.source as i32))
    }

    /// A projectile it turned away sends it away on its next tick.
    fn repelled(&self, body: &mut Body, hit: &Hit) {
        if self.ignores(body, hit) {
            react(body, Reaction::Away);
        }
    }

    /// `dropCustomDeathLoot`: a carried block drops as if mined with a
    /// diamond axe enchanted with Silk Touch (`ENDERMAN_LOOT_DROP`): every
    /// block endermen hold drops itself so (checked against the loot tables
    /// in `native_mob_hostile_test`).
    fn death_drops(&self, body: &Body) -> Vec<Value> {
        let Some(state) = body.data.get("carried").and_then(Value::as_int) else {
            return Vec::new();
        };
        self.shared
            .drops
            .iter()
            .find(|&&(first, last, _)| (first as i64..=last as i64).contains(&state))
            .map(|&(_, _, item)| vec![super::stack(item)])
            .unwrap_or_default()
    }

    /// A hurt without a living attacker may send it away on its next tick.
    fn hurt(&self, body: &mut Body, hit: &Hit, _events: &mut Vec<Event>) {
        if hit.attacker.is_none() {
            react(body, Reaction::Maybe);
        }
    }
}

impl Kind for Enderman {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Enderman"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered {
            goals: vec![
                Registration::new(0, "FloatGoal", JUMP, Float::new()),
                Registration::new(
                    1,
                    "EndermanFreezeWhenLookedAt",
                    MOVE | JUMP,
                    Freeze {
                        target: None,
                        e: Arc::clone(&self.shared),
                    },
                ),
                Registration::new(
                    2,
                    "MeleeAttackGoal",
                    MOVE | LOOK,
                    MeleeAttack::new(1.0, false, false),
                ),
                Registration::new(
                    7,
                    "WaterAvoidingRandomStrollGoal",
                    MOVE,
                    RandomStroll::new(
                        1.0,
                        StrollOptions {
                            water_avoiding: true,
                            probability: 0.0,
                            ..StrollOptions::default()
                        },
                    ),
                ),
                Registration::new(
                    8,
                    "LookAtPlayerGoal",
                    LOOK,
                    LookAtPlayer::new(8.0, 0.02, false, None),
                ),
                Registration::new(
                    8,
                    "RandomLookAroundGoal",
                    MOVE | LOOK,
                    RandomLookAround::new(),
                ),
                Registration::new(
                    10,
                    "EndermanLeaveBlockGoal",
                    0,
                    LeaveBlock {
                        e: Arc::clone(&self.shared),
                    },
                ),
                Registration::new(
                    11,
                    "EndermanTakeBlockGoal",
                    0,
                    TakeBlock {
                        e: Arc::clone(&self.shared),
                    },
                ),
            ],
            targets: vec![
                Registration::new(
                    1,
                    "EndermanLookForPlayerGoal",
                    TARGET,
                    LookForPlayer::new(Arc::clone(&self.shared)),
                ),
                Registration::new(
                    2,
                    "HurtByTargetGoal",
                    TARGET,
                    HurtByTarget::new(false, Vec::new(), Vec::new()),
                ),
                Registration::new(
                    3,
                    "NearestAttackableTargetGoal",
                    TARGET,
                    NearestAttackableTarget::new(
                        TargetKind::Mob,
                        Some(MobTypes::Types(vec![self.endermite])),
                        true,
                        TargetOptions::default(),
                    ),
                ),
                Registration::new(
                    4,
                    "ResetUniversalAngerTargetGoal",
                    0,
                    ResetUniversalAnger::new(ANGER),
                ),
            ],
        }
    }

    /// Before the rest of its tick: it ages, and a hurt's reaction comes
    /// now (`hurtServer`'s teleports).
    fn tick_start(&self, t: &mut Turn) {
        let ticks = int(t.data(), "ticks") + 1;
        t.mob.body.data.set("ticks", Value::Int(ticks));
        let reaction = match t.mind.own.family_mut::<EndermanOwn>() {
            Some(o) => o.hurt.take(),
            None => None,
        };
        match reaction {
            Some(Reaction::Away) => self.shared.away(t),
            // Nine times in ten one try.
            Some(Reaction::Maybe) if t.int(10) != 0 => {
                self.shared.teleport(t);
            }
            _ => {}
        }
    }

    /// `aiStep`: the anger kept up to date before its AI.
    fn before_ai(&self, t: &mut Turn) {
        neutral::update(t, true, ANGER);
    }

    /// `customServerAiStep`: by day, 30 seconds after its target last
    /// changed, a bright spot under the open sky sends it away now and then.
    fn custom_step(&self, t: &mut Turn) {
        let data = t.data();
        if !t.level.bright || int(data, "ticks") < int(data, "target_time") + 600 {
            return;
        }
        let cell = t.block();
        let bright = t.level.light(cell) as f64;
        if bright > 0.5 && t.level.sees_sky(cell) {
            let roll = t.float();
            if f(roll * 30.0) < f(f(bright - f(0.4)) * 2.0) {
                t.set_target(None);
                self.shared.teleport(t);
            }
        }
    }

    /// `getAmbientSound`: it screams while creepy.
    fn ambient_sound(&self, t: &mut Turn) -> Option<i32> {
        if flag(t.data(), "creepy") {
            return Some(self.shared.scream);
        }
        let name = t.facts.ambient_sound.as_deref()?;
        t.level.facts.sounds.id(name)
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Enderman::data_of()
    }
}

// ## Goals

/// `EndermanFreezeWhenLookedAt` (`Enderman.Freeze`): while its target is a
/// player within 16 blocks staring at it, it stands still looking at the
/// player.
#[derive(Clone, Debug, PartialEq)]
pub struct Freeze {
    target: Option<Ref>,
    e: Arc<Shared>,
}

impl Goal for Freeze {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        match t.target() {
            Some(p) if p.kind() == RefKind::Player => {
                self.target = Some(p.reference);
                t.distance_sq(p.position) <= 256.0 && self.e.stared_by_ref(t, &p.reference)
            }
            _ => {
                self.target = None;
                false
            }
        }
    }

    fn start(&mut self, t: &mut Turn) {
        navigation::stop(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        if let Some(p) = t.entity(self.target.as_ref()) {
            t.look_at_point([p.x(), p.eye_y(), p.z()]);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Enderman.Freeze"
    }
}

/// `EndermanTakeBlockGoal` (`Enderman.TakeBlock`): carrying nothing, while
/// mobs may grief, one update in ten it picks a cell within two blocks
/// around and up to three above its feet; a block endermen hold there that
/// an outline ray from its column reaches is taken and carried as its
/// block's default state.
#[derive(Clone, Debug, PartialEq)]
pub struct TakeBlock {
    e: Arc<Shared>,
}

impl Goal for TakeBlock {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if !t.data().get("carried").is_none_or(Value::is_nil) || !t.level.rules.mob_griefing {
            return false;
        }
        t.int(fmath::reduced(20) as i32) == 0
    }

    fn tick(&mut self, t: &mut Turn) {
        let a = t.double();
        let b = t.double();
        let c = t.double();
        let [bx, _, bz] = t.block();
        let [x, y, z] = t.pos();
        let cell = [
            floor(x - 2.0 + a * 4.0),
            floor(y + b * 3.0),
            floor(z - 2.0 + c * 4.0),
        ];
        let e = &self.e;
        let level = &*t.level;
        let block = level.block(cell);
        let from = [bx as f64 + 0.5, cell[1] as f64 + 0.5, bz as f64 + 0.5];
        let to = cell.map(|v| v as f64 + 0.5);
        let hit =
            crate::mobs::facts::outlines::clip(&level.facts.outlines, |p| level.block(p), from, to);
        let Some(state) = block else { return };
        if e.block_in(level, state, &e.holdable) && hit.position == cell {
            let blocks = &level.facts.blocks;
            let carried = blocks
                .block_id(state)
                .and_then(|id| blocks.block(id))
                .map(|b| b.default);
            if let Some(carried) = carried {
                t.mob.body.data.set("carried", Value::Int(carried as i64));
                t.effect(Effect::TakeBlock(Value::tuple([
                    Value::ivec3(cell.map(|v| v as i64)),
                    Value::Int(state as i64),
                ])));
            }
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Enderman.TakeBlock"
    }
}

/// `EndermanLeaveBlockGoal` (`Enderman.LeaveBlock`): carrying a block,
/// while mobs may grief, one update in a thousand it picks a cell within a
/// block around and up to two above its feet: an air cell over a full,
/// non-bedrock block with nothing in it takes the block (the owner places
/// it only where it survives, else gives it back).
#[derive(Clone, Debug, PartialEq)]
pub struct LeaveBlock {
    e: Arc<Shared>,
}

impl Goal for LeaveBlock {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if t.data().get("carried").is_none_or(Value::is_nil) || !t.level.rules.mob_griefing {
            return false;
        }
        t.int(fmath::reduced(2000) as i32) == 0
    }

    fn tick(&mut self, t: &mut Turn) {
        let a = t.double();
        let b = t.double();
        let c = t.double();
        let [x, y, z] = t.pos();
        let cell = [
            floor(x - 1.0 + a * 2.0),
            floor(y + b * 2.0),
            floor(z - 1.0 + c * 2.0),
        ];
        let e = &self.e;
        let level = &*t.level;
        let target = level.block(cell);
        let below = level.block([cell[0], cell[1] - 1, cell[2]]);
        let carried = t.data().get("carried").and_then(Value::as_int);
        let (Some(carried), Some(target), Some(below)) = (carried, target, below) else {
            return;
        };
        if level.state_flag(target, AIR)
            && !level.state_flag(below, AIR)
            && below != e.bedrock
            && level.state_flag(below, FULL_COLLISION)
            && empty(t, cell)
        {
            t.mob.body.data.set("carried", NIL);
            t.effect(Effect::PlaceCarried {
                cell,
                state: carried as i32,
            });
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Enderman.LeaveBlock"
    }
}

// No other entity in the cell (`getEntities(enderman, cube)`).
fn empty(t: &Turn, [x, y, z]: [i32; 3]) -> bool {
    let cube = Aabb {
        min: [x as f64, y as f64, z as f64],
        max: [x as f64 + 1.0, y as f64 + 1.0, z as f64 + 1.0],
    };
    let s = &*t.sensing;
    let players = s.players.iter().map(Entity::Player);
    let mobs = s.mobs().iter().map(Entity::Mob);
    let items = s.items.iter().map(Entity::Item);
    !players
        .chain(mobs)
        .chain(items)
        .any(|e| e.reference().uuid != t.uuid && intersects(&e.bounding_box(), &cube))
}

/// `EndermanLookForPlayerGoal` (`Enderman.LookForPlayer`): the nearest
/// player within its follow range who stares at it or whom it is angry at
/// becomes pending; looking at that player, after three updates it becomes
/// the target. With a target it keeps it unseen; stared at from within four
/// blocks it teleports away, and over 16 blocks from its target it
/// teleports toward it every 15 updates until one lands.
#[derive(Clone, Debug, PartialEq)]
pub struct LookForPlayer {
    fields: TargetFields,
    pending: Option<Ref>,
    aggro: i64,
    teleport: i64,
    e: Arc<Shared>,
}

impl LookForPlayer {
    fn new(e: Arc<Shared>) -> LookForPlayer {
        LookForPlayer {
            fields: TargetFields::new(false),
            pending: None,
            aggro: 0,
            teleport: 0,
            e,
        }
    }

    fn chase(&mut self, t: &mut Turn, target: &Seen) {
        let e = Arc::clone(&self.e);
        let distance = t.distance_sq(target.position);
        if e.stared_by_ref(t, &target.reference) {
            if distance < 16.0 {
                e.teleport(t);
            }
            self.teleport = 0;
        } else if distance > 256.0 {
            let waited = self.teleport;
            self.teleport = waited + 1;
            if waited >= fmath::reduced(30) && e.teleport_towards(t, target) {
                self.teleport = 0;
            }
        }
    }
}

impl Goal for LookForPlayer {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let e = Arc::clone(&self.e);
        let follow = target_goal::follow(t);
        let pick =
            |level: &Level, eyes: &Eyes, target: Entity<'_, Extra>| e.inducing(level, eyes, target);
        let targeting = Targeting::new(true).range(follow).select(&pick);
        // `getNearestPlayer(conditions, enderman)`: measured from its feet.
        let point = t.pos();
        let found = t.nearest_player(&targeting, point);
        self.pending = found.map(|p| p.reference);
        self.pending.is_some()
    }

    fn start(&mut self, t: &mut Turn) {
        self.aggro = fmath::reduced(5);
        self.teleport = 0;
        t.mob.body.data.set("stared_at", Value::bool(true));
    }

    fn stop(&mut self, t: &mut Turn) {
        self.pending = None;
        self.fields.stop(t);
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        if let Some(pending) = self.pending {
            let Some(player) = t.entity(Some(&pending)) else {
                return false;
            };
            let e = &self.e;
            let inducing = {
                let (level, sensing, eyes) = t.split();
                sensing
                    .entity(&pending)
                    .is_some_and(|target| e.inducing(level, &eyes, target))
            };
            if inducing {
                t.look_at_entity(&player, 10.0, 10.0);
                return true;
            }
            return false;
        }
        match t.entity(self.fields.target.as_ref()) {
            None => self.fields.can_continue(t),
            Some(target) => {
                let targeting = Targeting::new(true).sight(false);
                t.test(&target.reference, &targeting) || self.fields.can_continue(t)
            }
        }
    }

    fn tick(&mut self, t: &mut Turn) {
        if t.target().is_none() {
            self.fields.target = None;
        }
        if self.pending.is_some() {
            self.aggro -= 1;
            if self.aggro <= 0 {
                self.fields.target = self.pending.take();
                self.fields.start();
                t.set_target(self.fields.target);
            }
        } else if let Some(r) = self.fields.target {
            let Some(target) = t.entity(Some(&r)) else {
                return;
            };
            self.chase(t, &target);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Enderman.LookForPlayer"
    }
}
