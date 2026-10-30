//! Shulkers (`Valimc.AI.Mobs.Shulker`, vanilla's `Shulker`): a box on a
//! block face that never moves. It peeks now and then and opens fully to
//! shoot bullets at its target (`Attack`, `Peek`); while closed it has 20
//! more armour, arrows glance off and it is silent. Each tick it checks it
//! can stay where it is, else it finds another face of its block or
//! teleports up to eight blocks away, as it may when hurt below half health
//! or hit by a bullet (which can bring a second shulker).
//!
//! Its data: the face it is attached to (`Direction`'s 3D value, down by
//! default), its raw peek (0, 30 or 100), the peek it has opened to
//! (`currentPeekAmount`, 0.05 a tick toward the raw one), and its colour
//! (16 for none). Its box is the cube on its block opened by its physical
//! peek away from its face, solid to others while it lives; its head turns
//! in the frame of its face. Its lid's opening pushes what it sweeps
//! (`{:shulker_push, area, delta}`).
//!
//! A hurt's reaction waits in its mind's own fields (`ShulkerOwn`) for its
//! next tick, as the Elixir's `own.hurt`.

use super::{entity, fields, int};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{self, emax, emin, f};
use crate::mobs::ai::goal::{Goal, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::target::TargetOptions;
use crate::mobs::ai::goals::{
    HurtByTarget, Idle, LookAtPlayer, NearestAttackableTarget, RandomLookAround, TargetKind,
};
use crate::mobs::ai::hooks::{attribute, Hooks};
use crate::mobs::ai::mind::LookAt;
use crate::mobs::ai::shapes;
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::combat::{Event, Family, Hit, Rules, SoundKind, SoundRef};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Emission, Kind, KindMotion, Registered, Registration};
use crate::mobs::level::{Level, AIR};
use crate::mobs::model::{Body, FamilyData, Modifier, Number};
use crate::mobs::sensing::{inflate, intersects, Entity};
use crate::mobs::term::{Atom, Map, Value};
use crate::physics::Aabb;
use std::sync::Arc;

pub const SHULKER: &str = "minecraft:shulker";

const ARMOR: &str = "minecraft:armor";
const COVERED: &str = "minecraft:covered";

/// A hurt's reaction on its next tick.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reaction {
    Teleport,
    Bullet,
}

/// A shulker's own mind fields (`own.hurt`; an empty map once taken).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ShulkerOwn {
    pub hurt: Option<Reaction>,
}

/// What a shulker's rules and goals read (its goals hold it too).
#[derive(Debug, PartialEq)]
pub struct Shared {
    type_id: u16,
    /// Its type's width, height and eye height.
    dimensions: [f32; 3],
    /// `BlockTags.SHULKER_DOES_NOT_TELEPORT_TO`: block registry ids.
    no_teleport: Vec<i32>,
    moving_piston: u16,
    hostile: i32,
    open: i32,
    close: i32,
    shoot: i32,
    teleport: i32,
    hurt: i32,
    /// Damage types tagged `is_projectile`.
    projectiles: Vec<i32>,
    /// The face frames (`Facts.shulker_look`).
    look: Vec<[f32; 6]>,
}

/// The shulker family.
pub struct Shulker {
    types: [&'static str; 1],
    shared: Arc<Shared>,
}

impl Shulker {
    pub fn new(facts: &MobFacts) -> Result<Shulker, String> {
        let type_id = entity(facts, SHULKER)?;
        let e = facts.entities.get(type_id).ok_or("no shulker")?;
        let shared = Shared {
            type_id,
            dimensions: [e.width as f32, e.height as f32, e.eye_height as f32],
            no_teleport: facts
                .tags
                .get("minecraft:block", "minecraft:shulker_does_not_teleport_to")
                .map(<[i32]>::to_vec)
                .unwrap_or_default(),
            moving_piston: facts
                .blocks
                .default_state("minecraft:moving_piston")
                .ok_or("no moving piston")?,
            hostile: facts.sounds.source("hostile").ok_or("no hostile source")?,
            open: super::sound(facts, "minecraft:entity.shulker.open")?,
            close: super::sound(facts, "minecraft:entity.shulker.close")?,
            shoot: super::sound(facts, "minecraft:entity.shulker.shoot")?,
            teleport: super::sound(facts, "minecraft:entity.shulker.teleport")?,
            hurt: super::sound(facts, "minecraft:entity.shulker.hurt")?,
            projectiles: facts
                .tags
                .get("minecraft:damage_type", "minecraft:is_projectile")
                .map(<[i32]>::to_vec)
                .unwrap_or_default(),
            look: facts.ai.shulker_look.clone(),
        };
        Ok(Shulker {
            types: [SHULKER],
            shared: Arc::new(shared),
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[
            ("attach_face", Value::Int(0)),
            ("peek", Value::Int(0)),
            ("peek_amount", Value::Float(0.0)),
            ("color", Value::Int(16)),
        ])
    }
}

// ## Its data and box

fn face(data: &FamilyData) -> usize {
    int(data, "attach_face").clamp(0, 5) as usize
}

fn peek_amount(data: &FamilyData) -> f64 {
    data.get("peek_amount")
        .and_then(Value::as_float)
        .unwrap_or(0.0)
}

/// `isClosed`.
fn closed(data: &FamilyData) -> bool {
    int(data, "peek") == 0
}

/// `getPhysicalPeek`: `0.5F - Mth.sin((0.5F + amount) * (float)Math.PI) *
/// 0.5F`.
fn physical(amount: f64) -> f64 {
    let angle = f(f(0.5 + amount) * f(std::f64::consts::PI));
    f(0.5 - f(fmath::sin(angle) * 0.5))
}

/// `getProgressAabb(1, direction, progress, position)`.
fn progress_box(direction: usize, progress: f64, [x, y, z]: [f64; 3]) -> Aabb {
    let [dx, dy, dz] = shapes::step(direction);
    let grow = |low: f64, high: f64, d: i32| {
        if d > 0 {
            (low, high + d as f64 * progress)
        } else {
            (low + d as f64 * progress, high)
        }
    };
    let (x0, x1) = grow(-0.5, 0.5, dx);
    let (y0, y1) = grow(0.0, 1.0, dy);
    let (z0, z1) = grow(-0.5, 0.5, dz);
    Aabb {
        min: [x0 + x, y0 + y, z0 + z],
        max: [x1 + x, y1 + y, z1 + z],
    }
}

/// `makeBoundingBox` at `position`: the cube on its block, opened by its
/// physical peek away from the face it holds.
fn physical_box(data: &FamilyData, position: [f64; 3]) -> Aabb {
    progress_box(
        shapes::opposite(face(data)),
        physical(peek_amount(data)),
        position,
    )
}

fn six(b: Aabb) -> [f64; 6] {
    [b.min[0], b.min[1], b.min[2], b.max[0], b.max[1], b.max[2]]
}

fn deflate(b: Aabb) -> Aabb {
    Aabb {
        min: b.min.map(|v| v + 1.0e-6),
        max: b.max.map(|v| v - 1.0e-6),
    }
}

/// `opening/4`: the swept lid slab and its float displacement while it
/// opens from `previous` to `current`; None while unchanged or closing.
pub fn opening(
    face: usize,
    previous: f64,
    current: f64,
    [x, y, z]: [f64; 3],
) -> Option<([f64; 6], [f64; 3])> {
    let old = physical(previous);
    let now = physical(current);
    let amount = f(now - old);
    if amount <= 0.0 {
        return None;
    }
    let direction = shapes::opposite(face);
    let [dx, dy, dz] = shapes::step(direction);
    let b = progress_box(direction, now, [0.0; 3]);
    // `AABB.contract(-direction * (1 + previous))`: only the added face.
    let cut = 1.0 + old;
    let lo = |v: i32| v.max(0) as f64 * cut;
    let hi = |v: i32| v.min(0) as f64 * cut;
    let area = [
        b.min[0] + lo(dx) + x,
        b.min[1] + lo(dy) + y,
        b.min[2] + lo(dz) + z,
        b.max[0] + hi(dx) + x,
        b.max[1] + hi(dy) + y,
        b.max[2] + hi(dz) + z,
    ];
    let delta = [
        f(amount * dx as f64),
        f(amount * dy as f64),
        f(amount * dz as f64),
    ];
    Some((area, delta))
}

impl Shared {
    /// `Entity.playSound` at the mob, its pitch drawn by the caller.
    fn play(&self, t: &mut Turn, sound: i32, volume: f64, pitch: f64) {
        let seed = t.next_seed();
        t.effect(Effect::Sound {
            id: sound,
            source: self.hostile,
            volume: f(volume),
            pitch: f(pitch),
            seed,
        });
    }

    /// `setRawPeekAmount`: the covered armour while closed, the lid's
    /// sound.
    fn set_peek(&self, t: &mut Turn, amount: i64) {
        let armor = t.mob.body.mob.attributes.entry(ARMOR);
        armor.modifiers.retain(|m| m.id != COVERED);
        let sound = if amount == 0 {
            armor.modifiers.push(Modifier {
                id: COVERED.to_owned(),
                amount: Number::Float(20.0),
                operation: 0,
            });
            self.close
        } else {
            self.open
        };
        t.mob.body.data.set("peek", Value::Int(amount));
        self.play(t, sound, 1.0, 1.0);
    }

    /// `canStayAt`: its cell is free, the face holds and the open box fits.
    fn stays(&self, t: &Turn, cell: [i32; 3], face: usize) -> bool {
        let opposite = shapes::opposite(face);
        let [x, y, z] = cell;
        let bottom = [x as f64 + 0.5, y as f64, z as f64 + 0.5];
        !self.blocked(t, cell)
            && shapes::face_full(t.level, shapes::relative(cell, face), opposite)
            && self.free(t, deflate(progress_box(opposite, 1.0, bottom)))
    }

    // `isPositionBlocked`: anything but air, unless a moving piston where
    // it is.
    fn blocked(&self, t: &Turn, cell: [i32; 3]) -> bool {
        match t.level.block(cell) {
            None => true,
            Some(state) => {
                !t.level.state_flag(state, AIR)
                    && !(state == self.moving_piston && cell == t.block())
            }
        }
    }

    // `findAttachableSurface`: the first face, in `Direction` order, it can
    // stay on.
    fn surface(&self, t: &Turn, cell: [i32; 3]) -> Option<usize> {
        (0..6).find(|&face| self.stays(t, cell, face))
    }

    // The other living shulkers whose box meets `b`.
    fn others<'a>(&self, t: &'a Turn, b: &'a Aabb) -> impl Iterator<Item = ()> + 'a {
        let uuid = t.uuid;
        t.sensing.mobs_of(self.type_id).filter_map(move |m| {
            let e = Entity::Mob(m);
            (m.uuid != uuid && m.alive && intersects(&e.bounding_box(), b)).then_some(())
        })
    }

    // `noCollision`: blocks, the border and the other shulkers.
    fn free(&self, t: &Turn, b: Aabb) -> bool {
        shapes::free(t.level, &b) && self.others(t, &b).next().is_none()
    }

    /// `teleportSomewhere`: five tries at a random empty cell within eight
    /// blocks that it can stay in, onto a face whose block it may teleport
    /// to.
    fn teleport(&self, t: &mut Turn) -> bool {
        if t.mob.body.mob.no_ai {
            return false;
        }
        let old = t.block();
        for _ in 0..5 {
            let dx = t.int(17) - 8;
            let dy = t.int(17) - 8;
            let dz = t.int(17) - 8;
            let target = [old[0] + dx, old[1] + dy, old[2] + dz];
            if let Some(face) = self.landing(t, target) {
                self.moved(t, old, target, face);
                return true;
            }
        }
        false
    }

    fn landing(&self, t: &Turn, target: [i32; 3]) -> Option<usize> {
        let level: &Level = t.level;
        if target[1] <= level.min_y {
            return None;
        }
        let state = level.block(target)?;
        if !level.state_flag(state, AIR) || !within_border(level, target) {
            return None;
        }
        let [x, y, z] = target.map(f64::from);
        let cube = Aabb {
            min: [x, y, z],
            max: [x + 1.0, y + 1.0, z + 1.0],
        };
        if !self.free(t, deflate(cube)) {
            return None;
        }
        let face = self.surface(t, target)?;
        // `getBlockState(target.relative(face)).is(SHULKER_DOES_NOT_TELEPORT_TO)`.
        let onto = level.block(shapes::relative(target, face))?;
        let block = level.facts.blocks.block_id(onto)? as i32;
        (!self.no_teleport.contains(&block)).then_some(face)
    }

    // It plays the teleport sound where it was, moves, and the level shows
    // its trail (level event 2016); its lid shuts at once and it forgets
    // its target.
    fn moved(&self, t: &mut Turn, old: [i32; 3], target: [i32; 3], face: usize) {
        let packed = (((target[0] - old[0] + 8) & 255) << 16)
            | (((target[1] - old[1] + 8) & 255) << 8)
            | ((target[2] - old[2] + 8) & 255);
        t.effect(Effect::SoundAt {
            id: self.teleport,
            source: "hostile",
            at: t.pos(),
            volume: 1.0,
            pitch: 1.0,
        });
        t.mob.position = [
            target[0] as f64 + 0.5,
            target[1] as f64,
            target[2] as f64 + 0.5,
        ];
        let data = &mut t.mob.body.data;
        data.set("attach_face", Value::Int(face as i64));
        data.set("peek", Value::Int(0));
        t.effect(Effect::LevelEvent {
            cell: old,
            kind: 2016,
            data: packed,
        });
        t.set_target(None);
    }

    /// `hitByShulkerBullet`: an open shulker that teleports may leave a
    /// second one where it was, less likely the more shulkers are near (the
    /// level's random).
    fn hit_by_bullet(&self, t: &mut Turn) {
        let old = t.pos();
        let old_box = physical_box(t.data(), old);
        if closed(t.data()) || !self.teleport(t) {
            return;
        }
        let area = inflate(&old_box, 8.0, 8.0, 8.0);
        let others = self.others(t, &area).count() as f64;
        let now = physical_box(t.data(), t.pos());
        let me = if intersects(&now, &area) { 1.0 } else { 0.0 };
        let failure = f((others + me - 1.0) / 5.0);
        let roll = t.level.random.float() as f64;
        if roll >= failure {
            let color = int(t.data(), "color");
            t.effect(Effect::SpawnMob(Value::tuple([
                Value::Binary(SHULKER.as_bytes().to_vec()),
                Value::vec3(old),
                Value::Map(Map::from_atoms([("color", Value::Int(color))])),
            ])));
        }
    }

    /// `updatePeekAmount` and the opening-only push of its lid.
    fn peek(&self, t: &mut Turn) {
        let data = t.data();
        let target = f(int(data, "peek") as f64 * f(0.01));
        let current = peek_amount(data);
        let step = f(0.05);
        let amount = if current == target {
            current
        } else if current > target {
            f(emin(emax(f(current - step), target), 1.0))
        } else {
            f(emax(emin(f(current + step), target), 0.0))
        };
        let face = face(t.data());
        t.mob.body.data.set("peek_amount", Value::Float(amount));
        if let Some((area, delta)) = opening(face, current, amount, t.pos()) {
            t.effect(Effect::ShulkerPush(Value::tuple([
                Value::Tuple(area.iter().map(|&v| Value::Float(v)).collect()),
                Value::vec3(delta),
            ])));
        }
    }
}

fn within_border(level: &Level, [x, _, z]: [i32; 3]) -> bool {
    match level.border {
        None => true,
        Some([min_x, min_z, max_x, max_z]) => {
            let (x, z) = (x as f64, z as f64);
            x >= min_x && x < max_x && z >= min_z && z < max_z
        }
    }
}

// A hurt's reaction for its next tick (only a mind that thought keeps one).
fn react(body: &mut Body, reaction: Reaction) {
    let Some(state) = body.mob.ai.as_mut().and_then(|m| m.state.as_mut()) else {
        return;
    };
    state.own.family = Some(Box::new(ShulkerOwn {
        hurt: Some(reaction),
    }));
}

// `Vector3f.dot`: x * x' + (y * y' + z * z'), in floats.
fn dot([a, b, c]: [f64; 3], [x, y, z]: [f64; 3]) -> f64 {
    f(f(a * x) + f(f(b * y) + f(c * z)))
}

impl Hooks for Shulker {
    /// The head's wanted yaw measured in the frame of its face
    /// (`getYRotD`), the pitch always level (`getXRotD`).
    fn look_rotations(&self, t: &Turn, look: &LookAt) -> Option<(Option<f64>, Option<f64>)> {
        let frame = self
            .shared
            .look
            .get(face(t.data()))
            .copied()
            .unwrap_or_default()
            .map(f64::from);
        let out = [f(look.x - t.x()), f(look.y - t.eye_y()), f(look.z - t.z())];
        let right = dot([frame[3], frame[4], frame[5]], out);
        let forward = dot([frame[0], frame[1], frame[2]], out);
        let near = f(1.0e-5);
        let yaw = (right.abs() > near || forward.abs() > near)
            .then(|| f(fmath::atan2(-right, forward) * fmath::DEGREES));
        Some((yaw, Some(0.0)))
    }

    fn clamps_head(&self, _type_id: u16) -> bool {
        false
    }

    fn turns_body(&self, _type_id: u16) -> bool {
        false
    }
}

impl Family for Shulker {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Shulker::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let data = &body.data;
        vec![
            super::value(
                "shulker_attach_face",
                Value::Int(int(data, "attach_face")),
                Value::Int(0),
            ),
            super::value("shulker_peek", Value::Int(int(data, "peek")), Value::Int(0)),
            super::value(
                "shulker_color",
                Value::Int(int(data, "color")),
                Value::Int(16),
            ),
        ]
    }

    /// `getDefaultDimensions`: one opening upward is taller by its peek,
    /// its eye with it.
    fn dimensions(&self, body: &Body) -> Option<[f32; 3]> {
        let peek = peek_amount(&body.data);
        if face(&body.data) != 0 || peek <= 0.0 {
            return None;
        }
        let scale = (1.0 + peek) as f32;
        let [w, h, e] = self.shared.dimensions;
        Some([w, h * scale, e * scale])
    }

    fn bounding_box(&self, body: &Body, position: [f64; 3]) -> Option<[f64; 6]> {
        Some(six(physical_box(&body.data, position)))
    }

    /// A closed shulker takes nothing from arrows.
    fn ignores(&self, body: &Body, hit: &Hit) -> bool {
        closed(&body.data)
            && hit.direct.as_ref().is_some_and(|d| {
                matches!(
                    d.entity_type.as_str(),
                    "minecraft:arrow" | "minecraft:spectral_arrow" | "minecraft:trident"
                )
            })
    }

    /// Its hurt sound: muffled while closed.
    fn sound(&self, body: &Body, which: SoundKind) -> Option<SoundRef> {
        (which == SoundKind::Hurt && !closed(&body.data)).then_some(SoundRef::Id(self.shared.hurt))
    }

    /// After a hurt: below half health one in four teleports; otherwise a
    /// bullet's hit may (both on its next tick).
    fn hurt_with(&self, rules: &Rules, body: &mut Body, hit: &Hit, _events: &mut Vec<Event>) {
        if !body.mob.ai.as_ref().is_some_and(|m| m.state.is_some()) {
            return;
        }
        let max = attribute(
            rules.facts,
            self.shared.type_id,
            &body.mob,
            "minecraft:max_health",
        );
        let mut reaction = None;
        if body.mob.living.health.value < max * 0.5 {
            if let Some(mind) = body.mob.ai.as_mut() {
                if mind.random.int(4) == 0 {
                    reaction = Some(Reaction::Teleport);
                }
            }
        }
        if reaction.is_none()
            && self.shared.projectiles.contains(&(hit.source as i32))
            && hit
                .direct
                .as_ref()
                .is_some_and(|d| d.entity_type == "minecraft:shulker_bullet")
        {
            reaction = Some(Reaction::Bullet);
        }
        if let Some(r) = reaction {
            react(body, r);
        }
    }
}

impl Kind for Shulker {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Shulker"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        let type_id = self.shared.type_id;
        Registered {
            goals: vec![
                Registration::new(
                    1,
                    "LookAtPlayerGoal",
                    LOOK,
                    LookAtPlayer::new(8.0, 0.02, true, None),
                ),
                Registration::new(
                    4,
                    "ShulkerAttackGoal",
                    MOVE | LOOK,
                    Attack {
                        time: 0,
                        s: Arc::clone(&self.shared),
                    },
                ),
                Registration::new(
                    7,
                    "ShulkerPeekGoal",
                    0,
                    Peek {
                        time: 0,
                        s: Arc::clone(&self.shared),
                    },
                ),
                Registration::new(
                    8,
                    "RandomLookAroundGoal",
                    MOVE | LOOK,
                    RandomLookAround::new(),
                ),
            ],
            targets: vec![
                Registration::new(
                    1,
                    "HurtByTargetGoal",
                    TARGET,
                    HurtByTarget::new(true, vec![type_id], vec![type_id]),
                ),
                Registration::new(
                    2,
                    "ShulkerNearestAttackGoal",
                    TARGET,
                    NearestAttackableTarget::new(
                        TargetKind::Player,
                        None,
                        true,
                        TargetOptions {
                            peaceful: false,
                            ..TargetOptions::default()
                        },
                    ),
                ),
                // Only a shulker on a team defends others (`getTeam() ==
                // null`).
                Registration::new(
                    3,
                    "ShulkerDefenseAttackGoal",
                    TARGET,
                    Idle::new("ShulkerDefenseAttackGoal"),
                ),
            ],
        }
    }

    fn kernel_motion(&self) -> KindMotion {
        KindMotion {
            fixed: true,
            pushable: false,
            emission: Emission::None,
            ..KindMotion::default()
        }
    }

    /// A living shulker is solid to other entities (`canBeCollidedWith`).
    fn collider(&self, body: &Body, position: [f64; 3]) -> Option<[f64; 6]> {
        crate::mobs::living::mob::alive(&body.mob).then(|| six(physical_box(&body.data, position)))
    }

    /// A hurt's reaction comes now (`hurtServer`'s teleport).
    fn tick_start(&self, t: &mut Turn) {
        let reaction = match t.mind.own.family_mut::<ShulkerOwn>() {
            Some(o) => o.hurt.take(),
            None => None,
        };
        match reaction {
            Some(Reaction::Teleport) => {
                self.shared.teleport(t);
            }
            Some(Reaction::Bullet) => self.shared.hit_by_bullet(t),
            None => {}
        }
    }

    /// After its tick: if it cannot stay on its face it finds another or
    /// teleports, then its peek moves toward the raw one.
    fn after_tick(&self, t: &mut Turn) {
        let s = &self.shared;
        let cell = t.block();
        if !s.stays(t, cell, face(t.data())) {
            match s.surface(t, cell) {
                None => {
                    s.teleport(t);
                }
                Some(face) => {
                    t.mob.body.data.set("attach_face", Value::Int(face as i64));
                }
            }
        }
        s.peek(t);
    }

    /// It is silent while closed (`playAmbientSound`).
    fn ambient_sound(&self, t: &mut Turn) -> Option<i32> {
        if closed(t.data()) {
            return None;
        }
        let name = t.facts.ambient_sound.as_deref()?;
        t.level.facts.sounds.id(name)
    }

    fn still(&self) -> bool {
        true
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Shulker::data_of()
    }
}

// ## Goals

/// `ShulkerPeekGoal` (`Shulker.Peek`): with no target, one update in twenty
/// a shulker that can stay where it is opens a little (raw peek 30) for 20,
/// 40 or 60 ticks.
#[derive(Clone, Debug, PartialEq)]
pub struct Peek {
    time: i64,
    s: Arc<Shared>,
}

impl Goal for Peek {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if t.mind.target.is_some() {
            return false;
        }
        let n = t.int(fmath::reduced(40) as i32);
        n == 0 && self.s.stays(t, t.block(), face(t.data()))
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        t.mind.target.is_none() && self.time > 0
    }

    fn start(&mut self, t: &mut Turn) {
        let n = t.int(3) as i64;
        self.time = self.adjusted(20 * (1 + n));
        self.s.set_peek(t, 30);
    }

    fn stop(&mut self, t: &mut Turn) {
        if t.mind.target.is_none() {
            self.s.set_peek(t, 0);
        }
    }

    fn tick(&mut self, _t: &mut Turn) {
        self.time -= 1;
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Shulker.Peek"
    }
}

/// `ShulkerAttackGoal` (`Shulker.Attack`): with a living target, unless
/// peaceful, the shulker opens fully, looks at it and, while it is within
/// 20 blocks, shoots a bullet every 20 to 110 ticks (the first after 20);
/// farther away it loses it.
#[derive(Clone, Debug, PartialEq)]
pub struct Attack {
    time: i64,
    s: Arc<Shared>,
}

impl Attack {
    fn shoot(&mut self, t: &mut Turn, target: &Seen) {
        let n = t.int(10) as i64;
        self.time = 20 + n * 20 / 2;
        let b = physical_box(t.data(), t.pos());
        let center = [0, 1, 2].map(|a| b.min[a] + 0.5 * (b.max[a] - b.min[a]));
        let r = target.reference;
        let kind = match r.kind {
            crate::mobs::sensing::Kind::Player => "player",
            crate::mobs::sensing::Kind::Mob => "mob",
            crate::mobs::sensing::Kind::Item => "item",
        };
        t.effect(Effect::ShootBullet(Value::tuple([
            Value::vec3(center),
            Value::tuple([Value::atom(kind), Value::Binary(r.uuid.to_vec())]),
            Value::Int(shapes::axis(face(t.data())) as i64),
        ])));
        let a = t.float();
        let b = t.float();
        let pitch = f(f(f(a - b) * f(0.2)) + 1.0);
        self.s.play(t, self.s.shoot, 2.0, pitch);
    }
}

impl Goal for Attack {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let peaceful = t.level.difficulty == crate::mobs::level::Difficulty::Peaceful;
        t.target().is_some_and(|target| target.alive) && !peaceful
    }

    fn start(&mut self, t: &mut Turn) {
        self.time = 20;
        self.s.set_peek(t, 100);
    }

    fn stop(&mut self, t: &mut Turn) {
        self.s.set_peek(t, 0);
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        if t.level.difficulty == crate::mobs::level::Difficulty::Peaceful {
            return;
        }
        self.time -= 1;
        let Some(target) = t.target() else { return };
        t.look_at([target.x(), target.eye_y(), target.z()], 180.0, 180.0);
        if t.distance_sq(target.position) >= 400.0 {
            t.set_target(None);
        } else if self.time <= 0 {
            self.shoot(t, &target);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Shulker.Attack"
    }
}
