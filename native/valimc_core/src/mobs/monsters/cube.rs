//! Slimes and magma cubes (`Valimc.AI.Mobs.Cube`, `Slime` and `MagmaCube`,
//! vanilla's `AbstractCubeMob`, `Slime` and `MagmaCube`): one family each,
//! sharing the cube's rules.
//!
//! A cube hops: its move control (`CubeMobMoveControl`) turns it toward a
//! chosen direction and, on the ground when its goals want movement, jumps
//! once its jump delay runs out, with the jump sound; its goals float it in
//! liquids, pick random directions, keep it jumping and turn it toward its
//! target, hopping faster. Its size (entity data) scales its box, health
//! and speed; landing plays its squish; a player touching a cube that deals
//! damage is hurt (`playerTouch`); one bigger than the smallest splits in
//! two to four halves when it is removed after dying (`split`).
//!
//! A magma cube waits four times as long between hops, jumps higher the
//! bigger it is and leaps out of lava; every size hurts, for its size plus
//! two, and its armour is three a size. A slime's smallest size hurts
//! nothing. Each has its own sounds, the smallest's quieter kinds.
//!
//! Its move control's state is its mind's own (`CubeOwn`): the direction,
//! jump delay, whether it hops at a target and the movement its goals want
//! this tick.

use super::{entity, fields, int, value};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{f, rotlerp};
use crate::mobs::ai::goal::{Goal, JUMP, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::target::TargetOptions;
use crate::mobs::ai::goals::{MobTypes, NearestAttackableTarget, TargetKind, TargetTest};
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::spawn;
use crate::mobs::ai::turn::Turn;
use crate::mobs::ai::Extra;
use crate::mobs::combat::{Family, Rules, SoundKind, SoundRef};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, Registered, Registration};
use crate::mobs::living::health;
use crate::mobs::model::{Body, FamilyData, Mob, MotionSet};
use crate::mobs::sensing::{self, inflate, intersects, Entity, GameMode};
use crate::mobs::term::{Atom, Value};

pub const SLIME: &str = "minecraft:slime";
pub const MAGMA_CUBE: &str = "minecraft:magma_cube";

const SPEED: &str = "minecraft:movement_speed";

/// Which cube.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CubeKind {
    Slime,
    MagmaCube,
}

/// A cube's move control state (`Mind.own`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CubeOwn {
    pub y_rot: f64,
    pub jump_delay: i64,
    pub aggressive: bool,
    /// `setWantedMovement`'s speed modifier this tick.
    pub wanted: Option<f64>,
}

/// A cube family.
pub struct Cube {
    kind: CubeKind,
    types: [&'static str; 1],
    type_id: u16,
    iron_golem: u16,
    /// Its type's width, height and eye height.
    size: [f64; 3],
    levitation: i32,
    attack_sound: i32,
}

impl Cube {
    pub fn new(facts: &MobFacts, kind: CubeKind) -> Result<Cube, String> {
        let name = match kind {
            CubeKind::Slime => SLIME,
            CubeKind::MagmaCube => MAGMA_CUBE,
        };
        let type_id = entity(facts, name)?;
        let t = facts.entities.get(type_id).ok_or("no cube type")?;
        Ok(Cube {
            kind,
            types: [name],
            type_id,
            iron_golem: entity(facts, "minecraft:iron_golem")?,
            size: [t.width, t.height, t.eye_height],
            levitation: super::effect(facts, "minecraft:levitation")?,
            attack_sound: super::sound(facts, "minecraft:entity.slime.attack")?,
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[
            ("size", Value::Int(1)),
            ("was_on_ground", Value::bool(false)),
        ])
    }

    /// `setSize`'s own attributes (`attributes/1`): attack damage its size,
    /// a magma cube's armour three a size.
    fn more(&self, size: i64) -> Vec<(&'static str, f64)> {
        let mut more = vec![("minecraft:attack_damage", size as f64)];
        if self.kind == CubeKind::MagmaCube {
            more.push(("minecraft:armor", size as f64 * 3.0));
        }
        more
    }

    /// `setSize(size, true)`: its size (1 to 127), maximum health its
    /// square, movement speed `0.2F + 0.1F * size`, its own attributes and
    /// full health.
    pub fn set_size(&self, facts: &MobFacts, mob: &mut Mob, data: &mut FamilyData, size: i64) {
        let size = size.clamp(1, 127);
        let mut bases = vec![
            ("minecraft:max_health", (size * size) as f64),
            (SPEED, f(f(0.2) + f(f(0.1) * size as f64))),
        ];
        bases.extend(self.more(size));
        for (name, base) in bases {
            mob.attributes.entry(name).base = Some(base);
        }
        let max =
            crate::mobs::ai::hooks::attribute(facts, self.type_id, mob, "minecraft:max_health");
        let h = &mut mob.living.health;
        h.maximum = max;
        h.value = crate::mobs::ai::fmath::emin(h.value, max);
        health::set(h, max);
        data.set("size", Value::Int(size));
    }

    /// `dimensions/1`: its type's scaled by its size.
    fn scaled(&self, size: i64) -> [f32; 3] {
        let s = f(size as f64);
        let [w, h, e] = self.size;
        [f(f(w) * s) as f32, f(f(h) * s) as f32, f(f(e) * s) as f32]
    }

    fn tiny(data: &FamilyData) -> bool {
        int(data, "size") <= 1
    }

    /// `canDealDamage`: a magma cube always, a slime but the smallest.
    fn deals_damage(&self, data: &FamilyData) -> bool {
        self.kind == CubeKind::MagmaCube || !Cube::tiny(data)
    }

    fn sound_name(&self, data: &FamilyData, which: &str) -> String {
        let tiny = Cube::tiny(data);
        match (self.kind, which) {
            (CubeKind::MagmaCube, "jump") => "minecraft:entity.magma_cube.jump".to_owned(),
            (CubeKind::Slime, _) if tiny => format!("minecraft:entity.slime.{which}_small"),
            (CubeKind::Slime, _) => format!("minecraft:entity.slime.{which}"),
            (CubeKind::MagmaCube, _) if tiny => {
                format!("minecraft:entity.magma_cube.{which}_small")
            }
            (CubeKind::MagmaCube, _) => format!("minecraft:entity.magma_cube.{which}"),
        }
    }

    /// `getSoundVolume`: 0.4 a size.
    fn volume(data: &FamilyData) -> f64 {
        f(f(0.4) * int(data, "size") as f64)
    }

    // `(nextFloat() - nextFloat()) * 0.2F + 1.0F`.
    fn pitch(t: &mut Turn) -> f64 {
        let a = t.float();
        let b = t.float();
        f(f(f(a - b) * f(0.2)) + 1.0)
    }

    // A sound from the cube at its volume.
    fn sound(t: &mut Turn, name: &str, pitch: f64) {
        let Some(id) = t.level.facts.sounds.id(name) else {
            return;
        };
        let volume = Cube::volume(t.data());
        t.sound_id(id, volume, f(pitch));
    }

    /// `getJumpDelay`: 10 to 29 ticks, four times that for a magma cube.
    fn jump_delay(&self, t: &mut Turn) -> i64 {
        let delay = t.int(20) as i64 + 10;
        match self.kind {
            CubeKind::Slime => delay,
            CubeKind::MagmaCube => delay * 4,
        }
    }

    /// `getAttackDamage`: its attack damage (a magma cube's and two).
    fn attack_damage(&self, t: &Turn) -> f64 {
        let damage = f(t.attribute("minecraft:attack_damage"));
        match self.kind {
            CubeKind::Slime => damage,
            CubeKind::MagmaCube => f(damage + 2.0),
        }
    }

    // `playerTouch` for each player whose box, a block wider and half a
    // block taller, meets it: `dealDamage` within melee reach and in sight,
    // the attack sound's pitch drawn as it would be.
    fn touch(&self, t: &mut Turn) {
        let own = t.bbox();
        let touching: Vec<_> = t
            .sensing
            .players
            .iter()
            .filter(|p| {
                p.alive
                    && matches!(p.mode, GameMode::Survival | GameMode::Adventure)
                    && intersects(
                        &inflate(&Entity::<Extra>::Player(p).bounding_box(), 1.0, 0.5, 1.0),
                        &own,
                    )
            })
            .map(|p| p.uuid)
            .collect();
        let reach = f(2.04).sqrt() - f(0.6);
        for uuid in touching {
            let Some(p) = t.sensing.players.iter().find(|p| p.uuid == uuid) else {
                continue;
            };
            let target = Entity::<Extra>::Player(p);
            let reference = target.reference();
            let within = intersects(&inflate(&own, reach, 0.0, reach), &target.bounding_box());
            let seen = within && {
                let (level, sensing, eyes) = t.split();
                let p = sensing.players.iter().find(|p| p.uuid == uuid);
                p.is_some_and(|p| sensing::line_of_sight(level, &eyes, Entity::Player(p)))
            };
            if !seen {
                continue;
            }
            let amount = self.attack_damage(t);
            let pitch = Cube::pitch(t);
            let sound = Value::tuple([
                Value::Int(self.attack_sound as i64),
                Value::Float(1.0),
                Value::Float(pitch),
            ]);
            t.effect(Effect::Touch {
                target: reference,
                amount,
                sound,
            });
        }
    }
}

// The cube's own state (its defaults where it has none yet).
fn own(t: &Turn) -> CubeOwn {
    t.mind.own.family::<CubeOwn>().cloned().unwrap_or_default()
}

fn put(t: &mut Turn, change: impl FnOnce(&mut CubeOwn)) {
    let mut own = own(t);
    change(&mut own);
    t.mind.own.family = Some(Box::new(own));
}

/// `setDirection(yRot, isAggressive)`.
fn direction(t: &mut Turn, y_rot: f64, aggressive: bool) {
    put(t, |o| {
        o.y_rot = y_rot;
        o.aggressive = aggressive;
    });
}

/// `setWantedMovement(speedModifier)`: move this tick.
fn want(t: &mut Turn, modifier: f64) {
    put(t, |o| o.wanted = Some(modifier));
}

// `setSpeed`: its speed and forward input.
fn set(t: &mut Turn, speed: f64) {
    t.mob.body.mob.motion.set = Some(MotionSet::Speed { speed, lift: false });
}

impl Hooks for Cube {}

impl Family for Cube {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Cube::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        vec![value(
            "cube_size",
            Value::Int(int(&body.data, "size")),
            Value::Int(1),
        )]
    }

    fn dimensions(&self, body: &Body) -> Option<[f32; 3]> {
        Some(self.scaled(int(&body.data, "size")))
    }

    fn volume(&self, body: &Body, _volume: f64) -> f64 {
        Cube::volume(&body.data)
    }

    fn sound(&self, body: &Body, which: SoundKind) -> Option<SoundRef> {
        let which = match which {
            SoundKind::Hurt => "hurt",
            SoundKind::Death => "death",
        };
        Some(SoundRef::Name(self.sound_name(&body.data, which)))
    }

    fn loot_properties(&self, body: &Body) -> Vec<(String, String)> {
        vec![(
            "cube_mob/size".to_owned(),
            int(&body.data, "size").to_string(),
        )]
    }

    fn experience(&self, body: &Body) -> Option<i32> {
        Some(int(&body.data, "size") as i32)
    }
}

impl Kind for Cube {
    fn module(&self) -> &'static str {
        match self.kind {
            CubeKind::Slime => "Valimc.AI.Mobs.Slime",
            CubeKind::MagmaCube => "Valimc.AI.Mobs.MagmaCube",
        }
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    /// `registerGoals`: floating, random directions and jumping, the cube's
    /// attack, then its targets: players within four blocks up or down,
    /// then iron golems.
    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered {
            goals: vec![
                Registration::new(1, "CubeMobFloatGoal", MOVE | JUMP, CubeFloat),
                Registration::new(
                    4,
                    "CubeMobRandomDirectionGoal",
                    LOOK,
                    RandomDirection {
                        chosen: 0.0,
                        next: 0,
                        levitation: self.levitation,
                    },
                ),
                Registration::new(5, "CubeMobKeepOnJumpingGoal", MOVE | JUMP, KeepOnJumping),
                Registration::new(
                    2,
                    "CubeMobAttackGoal",
                    LOOK,
                    Attack {
                        tired: 0,
                        magma: self.kind == CubeKind::MagmaCube,
                    },
                ),
            ],
            targets: vec![
                Registration::new(
                    1,
                    "NearestAttackableTargetGoal",
                    TARGET,
                    NearestAttackableTarget::new(
                        TargetKind::Player,
                        None,
                        true,
                        TargetOptions {
                            selector: Some(TargetTest::WithinY(4.0)),
                            ..TargetOptions::default()
                        },
                    ),
                ),
                Registration::new(
                    3,
                    "NearestAttackableTargetGoal",
                    TARGET,
                    NearestAttackableTarget::new(
                        TargetKind::Mob,
                        Some(MobTypes::Types(vec![self.iron_golem])),
                        true,
                        TargetOptions::default(),
                    ),
                ),
            ],
        }
    }

    /// `finalizeSpawn`: a mob's, then `setSpawnSize` from the level's
    /// random: 1, 2 or 4, one step bigger by half the local difficulty's
    /// special multiplier.
    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        spawn::mob(t, reason);
        let mut scale = spawn::level_int(t, 3);
        if scale < 2 && spawn::level_float(t) < f(f(0.5) * f(spawn::special(t))) {
            scale += 1;
        }
        let facts = t.level.facts;
        let body = &mut t.mob.body;
        self.set_size(facts, &mut body.mob, &mut body.data, 1 << scale);
        let [w, h, e] = self.scaled(1 << scale);
        (t.width, t.height, t.eye) = (w as f64, h as f64, e as f64);
    }

    /// `CubeMobMoveControl.tick`: it turns up to 90 degrees toward its
    /// direction, head and body with it. Asked to move, on the ground it
    /// hops when its jump delay ran out (a third of it at a target; the jump
    /// sound), else stands; in the air it keeps its speed. Otherwise it
    /// stops its forward input.
    fn move_control(&self, t: &mut Turn) {
        let o = own(t);
        let yaw = rotlerp(t.yaw(), o.y_rot, 90.0);
        t.mob.body.yaw = yaw;
        t.mob.body.head_yaw = yaw;
        t.mind.body_yaw = yaw;
        let Some(modifier) = o.wanted else {
            t.wait();
            return;
        };
        put(t, |o| o.wanted = None);
        let speed = f(modifier * t.attribute(SPEED));
        if !t.on_ground() {
            set(t, speed);
        } else if o.jump_delay > 0 {
            put(t, |o| o.jump_delay -= 1);
            set(t, 0.0);
        } else {
            let delay = self.jump_delay(t);
            let delay = if o.aggressive { delay / 3 } else { delay };
            put(t, |o| o.jump_delay = delay);
            t.jump();
            let adjuster = f(if Cube::tiny(t.data()) { 1.4 } else { 0.8 });
            let pitch = Cube::pitch(t);
            let name = self.sound_name(t.data(), "jump");
            Cube::sound(t, &name, pitch * adjuster);
            set(t, speed);
        }
    }

    /// `tick()` after its super: landing, it draws its particles' places
    /// and plays its squish; it remembers whether it was on the ground.
    /// Then the players touching it are hurt if it deals damage.
    fn after_tick(&self, t: &mut Turn) {
        let on_ground = t.on_ground();
        if on_ground && !super::flag(t.data(), "was_on_ground") {
            let size = f(t.width * 2.0);
            let bound = f(size * 16.0);
            let count = if bound == bound.trunc() {
                bound as i64
            } else {
                bound.trunc() as i64 + 1
            };
            for _ in 0..count.max(0) {
                t.float();
                t.float();
            }
            let pitch = Cube::pitch(t);
            let name = self.sound_name(t.data(), "squish");
            Cube::sound(t, &name, f(pitch / f(0.8)));
        }
        t.mob.body.data.set("was_on_ground", Value::bool(on_ground));
        if self.deals_damage(t.data()) {
            self.touch(t);
        }
    }

    /// `jumpFromGround` (a magma cube's a tenth a size more) and its
    /// `jumpInLiquid` in lava (`0.22F + size * 0.05F`), for the kernel.
    fn jump(&self, body: &Body) -> Option<(f64, Option<f64>)> {
        match self.kind {
            CubeKind::Slime => Some((0.0, None)),
            CubeKind::MagmaCube => {
                let size = int(&body.data, "size") as f64;
                Some((f(size * f(0.1)), Some(f(f(0.22) + f(size * f(0.05))))))
            }
        }
    }

    /// `remove` of a dead cube bigger than the smallest: two to four cubes
    /// of half its size (its own random), each half its width off its
    /// centre on the diagonals and half a block up, facing a random way, at
    /// full health with its name, effects and AI flag
    /// (`ConversionType.SPLIT_ON_DEATH`).
    fn split(&self, rules: &Rules, body: &Body, [x, y, z]: [f64; 3]) -> Vec<(Body, [f64; 3])> {
        let size = int(&body.data, "size");
        if size <= 1 {
            return Vec::new();
        }
        let Some(mut random) = body.mob.ai.as_ref().map(|m| m.random) else {
            return Vec::new();
        };
        let width = self.scaled(size)[0] as f64;
        let offset = f(width / 2.0);
        let half = size / 2;
        let n = random.int(3);
        (0..=1 + n)
            .map(|i| {
                let xd = f(f((i % 2) as f64 - 0.5) * offset);
                let zd = f(f((i / 2) as f64 - 0.5) * offset);
                let yaw = f(random.float() as f64 * 360.0);
                let child = self.child(rules, body, half, yaw);
                (child, [x + xd, y + 0.5, z + zd])
            })
            .collect()
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Cube::data_of()
    }
}

impl Cube {
    // A split's half: a fresh cube of `size` with the parent's effects,
    // absorption, AI flag, persistence and name.
    fn child(&self, rules: &Rules, parent: &Body, size: i64, yaw: f64) -> Body {
        let ty = crate::mobs::living::mob::Type {
            id: self.type_id,
            facts: rules
                .facts
                .entities
                .get(self.type_id)
                .expect("a cube's type"),
        };
        let mut new = crate::mobs::living::body::fresh(rules, ty);
        let (mob, data) = (&mut new.mob, &mut new.data);
        self.set_size(rules.facts, mob, data, size);
        let old = &parent.mob;
        mob.living.effects = old.living.effects.clone();
        mob.living.absorption = old.living.absorption;
        mob.no_ai = old.no_ai;
        mob.persistent = old.persistent;
        new.yaw = yaw;
        new.head_yaw = yaw;
        new.custom_name = parent.custom_name.clone();
        new
    }
}

// ## Goals

/// `CubeMobFloatGoal` (`Cube.Float`), every tick while in water or lava:
/// it jumps four times in five and moves at 1.2.
#[derive(Clone, Debug, PartialEq)]
pub struct CubeFloat;

impl Goal for CubeFloat {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        t.in_liquid()
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        if t.float() < f(0.8) {
            t.jump();
        }
        want(t, 1.2);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Cube.Float"
    }
}

/// `CubeMobRandomDirectionGoal` (`Cube.RandomDirection`), with no target
/// while on the ground, in a liquid or levitating: a whole-degree direction
/// every 40 to 99 ticks.
#[derive(Clone, Debug, PartialEq)]
pub struct RandomDirection {
    chosen: f64,
    next: i64,
    levitation: i32,
}

impl Goal for RandomDirection {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let levitating = t.mob.body.mob.living.effects.get(self.levitation).is_some();
        t.target().is_none() && (t.on_ground() || t.in_liquid() || levitating)
    }

    fn tick(&mut self, t: &mut Turn) {
        if self.next - 1 <= 0 {
            let n = t.int(60) as i64;
            let degrees = t.int(360);
            self.next = self.adjusted(40 + n);
            self.chosen = degrees as f64;
        } else {
            self.next -= 1;
        }
        direction(t, self.chosen, false);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Cube.RandomDirection"
    }
}

/// `CubeMobKeepOnJumpingGoal` (`Cube.KeepOnJumping`): it keeps moving at
/// 1.0.
#[derive(Clone, Debug, PartialEq)]
pub struct KeepOnJumping;

impl Goal for KeepOnJumping {
    fn can_use(&mut self, _t: &mut Turn) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        want(t, 1.0);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Cube.KeepOnJumping"
    }
}

/// `CubeMobAttackGoal` (`Cube.Attack`), every tick for up to 150 ticks
/// while it may attack its target: it turns toward it and hops that way,
/// aggressively while it deals damage.
#[derive(Clone, Debug, PartialEq)]
pub struct Attack {
    tired: i64,
    magma: bool,
}

impl Goal for Attack {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        match t.target() {
            Some(target) => t.can_attack(&target.reference),
            None => false,
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        match t.target() {
            Some(target) if t.can_attack(&target.reference) => {
                self.tired -= 1;
                self.tired > 0
            }
            _ => false,
        }
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn start(&mut self, _t: &mut Turn) {
        self.tired = crate::mobs::ai::fmath::reduced(300);
    }

    fn tick(&mut self, t: &mut Turn) {
        if let Some(target) = t.target() {
            t.look_at_entity(&target, 10.0, 10.0);
        }
        let deals = self.magma || !Cube::tiny(t.data());
        let yaw = t.yaw();
        direction(t, yaw, deals);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Cube.Attack"
    }
}
