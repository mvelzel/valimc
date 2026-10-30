//! Drowned (`Valimc.AI.Mobs.Drowned`, vanilla's `Drowned`), a zombie
//! (`zombie::Parts` keeps its data, babies, hits and attributes):
//!
//! - **Goals**: the zombie's turtle eggs and looks, then its own: by day out
//!   of water it heads for water ten blocks around (`GoToWater`); a trident
//!   thrower throws at its target (`Trident`, `RangedAttackGoal`), else
//!   melee (`Attack`), either only at night or at a target in water; at
//!   night in shallow water it goes ashore (`MoveToBlockGoal`) and from
//!   deeper water swims up (`SwimUp`); it wanders. Targets: whoever hurt it
//!   (not a drowned; zombified piglins join in), players it may attack,
//!   villagers, iron golems, axolotls and baby turtles.
//! - **Swimming**: underwater and wanting to swim (searching for land, or
//!   after a target in water) it swims (`DrownedMoveControl`: turning toward
//!   where it goes, easing its speed, pushed along and up; the kernel's fish
//!   travel); out of it it walks, a little heavier in the air (`-0.008`).
//! - **Spawning**: no armour; a trident (10 in 16) or fishing rod one time
//!   in ten, a nautilus shell in the off hand three times in a hundred, and
//!   the zombie nautilus a natural trident thrower may ride (its draws).
//! - Its sounds are its own, in water their watery kinds.

use super::zombie::{self, Parts, DROWNED};
use super::{fields, flag, item, item_tag};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{self, f, rotlerp};
use crate::mobs::ai::goal::{Goal, JUMP, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::move_to_block::{BlockOptions, BlockTest, MoveToBlock};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::target::TargetOptions;
use crate::mobs::ai::goals::{
    HurtByTarget, MeleeAttack, MobTypes, NearestAttackableTarget, RandomStroll, RangedAttack,
    TargetKind, TargetTest,
};
use crate::mobs::ai::hooks::{item_id, Hooks, Tag};
use crate::mobs::ai::navigation::{self, NavKind};
use crate::mobs::ai::spawn;
use crate::mobs::ai::turn::{Eyes, Seen, Turn};
use crate::mobs::ai::{random_pos, Extra};
use crate::mobs::combat::{Family, SoundKind, SoundRef};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, NavSpec, Registered, Registration};
use crate::mobs::level::{Difficulty, Level};
use crate::mobs::model::{
    Body, Control, FamilyData, Impulse, Mob, MotionSet, Slot, Travel, TravelKind,
};
use crate::mobs::sensing::Entity;
use crate::mobs::term::{Atom, Map, Value};

/// The flag bit of a block with a full top face (`collision_up`).
const COLLISION_UP: u32 = 18;

// The family's own tests and actions.
const THROW: Tag = 1;
const BEACH: Tag = 2;
const BEACH_TIME: Tag = 3;
const OK_TARGET: Tag = 4;

/// The drowned family.
pub struct Drowned {
    parts: Parts,
    types: [&'static str; 1],
    zombified_piglin: u16,
    axolotl: u16,
    trident: i32,
    fishing_rod: i32,
    shell: i32,
    spears: Vec<i32>,
    preferred: Vec<i32>,
    shoot: i32,
}

impl Drowned {
    pub fn new(facts: &MobFacts) -> Result<Drowned, String> {
        Ok(Drowned {
            parts: Parts::new(facts)?,
            types: [DROWNED],
            zombified_piglin: super::entity(facts, "minecraft:zombified_piglin")?,
            axolotl: super::entity(facts, "minecraft:axolotl")?,
            trident: item(facts, "minecraft:trident")?,
            fishing_rod: item(facts, "minecraft:fishing_rod")?,
            shell: item(facts, "minecraft:nautilus_shell")?,
            spears: item_tag(facts, "minecraft:spears"),
            preferred: item_tag(facts, "minecraft:drowned_preferred_weapons"),
            shoot: super::sound(facts, "minecraft:entity.drowned.shoot")?,
        })
    }

    fn data_of(&self) -> Vec<(Atom, Value)> {
        let mut data = self.parts.data(self.parts.drowned);
        data.extend(fields(&[
            ("searching", Value::bool(false)),
            ("swimming", Value::bool(false)),
        ]));
        data
    }

    fn trident(&self, t: &Turn) -> bool {
        t.mob
            .body
            .mob
            .equipment
            .get(Slot::Mainhand)
            .and_then(item_id)
            == Some(self.trident)
    }

    // `populateDefaultEquipmentSlots`: a trident or a fishing rod, no armour.
    fn equipment(&self, t: &mut Turn) {
        if spawn::level_float(t) > 0.9 {
            let item = if spawn::level_int(t, 16) < 10 {
                self.trident
            } else {
                self.fishing_rod
            };
            spawn::equip(t, Slot::Mainhand, Some(super::stack(item)));
        }
    }

    // The zombie nautilus's spawn: its variant for the biome, its attack
    // cooldown memory, then a mob's draws (the nautilus and riding are not
    // modelled: the owner makes none yet).
    fn nautilus(&self, t: &mut Turn, reason: &Atom) {
        if !matches!(reason.as_str(), "natural" | "structure") || !self.trident(t) {
            return;
        }
        let roll = spawn::level_float(t);
        let facts = t.level.facts;
        let biome = t.level.biome(t.block());
        if roll < f(0.5)
            && !flag(t.data(), "baby")
            && !facts.biome_in(Some(biome), "minecraft:more_frequent_drowned_spawns")
        {
            crate::mobs::animals::variants::pick_variant(t, "minecraft:zombie_nautilus_variant");
            spawn::level_int(t, 1201);
            spawn::level_double(t);
            spawn::level_double(t);
            spawn::level_float(t);
            let options = Map::from_atoms([
                ("jockey", Value::bool(true)),
                ("yaw", Value::Float(t.yaw())),
            ]);
            if let Some(nautilus) = facts.entities.id("minecraft:zombie_nautilus") {
                t.effect(Effect::Spawn {
                    type_id: nautilus,
                    options: Value::Map(options),
                });
            }
        }
    }

    // ## Swimming

    // `travelInWater`: underwater and wanting to swim, it travels as a fish
    // does (no sinking).
    fn travel(&self, t: &mut Turn) {
        let travel = (t.mob.body.mob.motion.eye_water && wants_to_swim(t)).then_some(Travel {
            kind: TravelKind::Fish,
            sink: false,
        });
        t.mob.body.mob.motion.travel = travel;
    }

    fn swim(&self, t: &mut Turn, [wx, wy, wz]: [f64; 3], modifier: f64, lift: [f64; 3]) {
        let (xd, yd, zd) = (wx - t.x(), wy - t.y(), wz - t.z());
        let dd = (xd * xd + yd * yd + zd * zd).sqrt();
        let yd = yd / dd;
        let yaw = rotlerp(t.yaw(), fmath::yaw(xd, zd), 90.0);
        t.mob.body.yaw = yaw;
        t.mind.body_yaw = yaw;
        let target = f(modifier * t.attribute("minecraft:movement_speed"));
        // `Mth.lerp(0.125F, getSpeed(), target)`.
        let current = t.speed();
        let speed = f(current + f(f(0.125) * f(target - current)));
        set(
            t,
            speed,
            vec![
                lift,
                [speed * xd * 0.005, speed * yd * 0.1, speed * zd * 0.005],
            ],
        );
    }

    // ## Throwing

    /// `performRangedAttack`: a trident (its own, or a new one) thrown from
    /// its eyes at the target's lower third, and its sound.
    fn throw(&self, t: &mut Turn, target: &Seen) {
        let stack = t
            .mob
            .body
            .mob
            .equipment
            .get(Slot::Mainhand)
            .cloned()
            .unwrap_or_else(|| super::stack(self.trident));
        let from_y = t.eye_y() - 0.10000000149011612;
        let xd = target.x() - t.x();
        let yd = target.y() + target.height * 0.3333333333333333 - from_y;
        let zd = target.z() - t.z();
        let dist = (xd * xd + zd * zd).sqrt();
        let roll = t.float();
        let pitch = f(1.0 / f(f(roll * f(0.4)) + f(0.8)));
        // `RangedAttackMob.rangedAttackUncertainty`: `14 - difficulty * 4`.
        let level = match t.level.difficulty {
            Difficulty::Peaceful => 0,
            Difficulty::Easy => 1,
            Difficulty::Normal => 2,
            Difficulty::Hard => 3,
        };
        let throw = Map::from_atoms([
            ("stack", stack),
            ("from", Value::vec3([t.x(), from_y, t.z()])),
            ("direction", Value::vec3([xd, yd + dist * f(0.2), zd])),
            ("velocity", Value::Float(1.6)),
            ("uncertainty", Value::Float((14 - level * 4) as f64)),
        ]);
        t.effect(Effect::ThrowTrident(Value::Map(throw)));
        t.sound_id(self.shoot, 1.0, pitch);
    }
}

/// `wantsToSwim`: searching for land, or after a target in water.
fn wants_to_swim(t: &mut Turn) -> bool {
    if flag(t.data(), "searching") {
        return true;
    }
    match t.target() {
        Some(target) => t.level.in_water(&target.bbox),
        None => false,
    }
}

/// `okTarget`: at night any, by day only one in water.
fn ok_target(level: &Level, target: Option<&crate::physics::Aabb>) -> bool {
    target.is_some_and(|b| !level.bright || level.in_water(b))
}

// `setSpeed` and its pushes this tick.
fn set(t: &mut Turn, speed: f64, impulse: Vec<[f64; 3]>) {
    let motion = &mut t.mob.body.mob.motion;
    motion.set = Some(MotionSet::Speed { speed, lift: false });
    motion.impulse = Impulse::List(impulse);
}

impl Hooks for Drowned {
    fn voice(&self, type_id: u16, data: &FamilyData) -> f32 {
        self.parts.voice(type_id, data)
    }

    fn hit(&self, t: &mut Turn, target: &Seen) {
        self.parts.hit(t, target);
    }

    fn perform(&self, t: &mut Turn, tag: Tag, target: &Seen, _power: f64) {
        if tag == THROW {
            self.throw(t, target);
        }
    }

    /// `DrownedGoToBeachGoal`'s guard: at night in water near the surface.
    fn test(&self, t: &mut Turn, tag: Tag) -> bool {
        tag == BEACH_TIME
            && !t.level.bright
            && t.in_water()
            && t.y() >= (t.level.sea_level - 3) as f64
    }

    /// `DrownedGoToBeachGoal.isValidTarget`: a block it can stand on with
    /// two empty blocks above.
    fn block(&self, t: &mut Turn, tag: Tag, [x, y, z]: [i32; 3], _goal: &mut MoveToBlock) -> bool {
        tag == BEACH
            && t.level.air([x, y + 1, z])
            && t.level.air([x, y + 2, z])
            && t.level
                .block([x, y, z])
                .is_some_and(|s| t.level.state_flag(s, COLLISION_UP))
    }

    fn target(&self, level: &Level, _eyes: &Eyes, tag: Tag, target: Entity<'_, Extra>) -> bool {
        tag == OK_TARGET && ok_target(level, Some(&target.bounding_box()))
    }
}

impl Family for Drowned {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(self.data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        self.parts.values(self.parts.drowned, &body.data)
    }

    fn voice(&self, body: &Body) -> f32 {
        self.parts.voice(self.parts.drowned, &body.data)
    }

    fn dimensions(&self, body: &Body) -> Option<[f32; 3]> {
        self.parts.dimensions(body)
    }

    fn sound(&self, body: &Body, which: SoundKind) -> Option<SoundRef> {
        let name = match which {
            SoundKind::Hurt => "minecraft:entity.drowned.hurt",
            SoundKind::Death => "minecraft:entity.drowned.death",
        };
        let name = if body.mob.motion.water > 0.0 {
            format!("{name}_water")
        } else {
            name.to_owned()
        };
        Some(SoundRef::Name(name))
    }
}

impl Kind for Drowned {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Drowned"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    /// `AmphibiousPathNavigation`.
    fn navigation(&self, _type_id: u16) -> NavSpec {
        NavSpec {
            kind: NavKind::Amphibious,
            ..NavSpec::default()
        }
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        let p = &self.parts;
        let mut goals = p.common_goals();
        goals.extend([
            Registration::new(1, "DrownedGoToWaterGoal", MOVE, GoToWater::default()),
            Registration::new(
                2,
                "DrownedTridentAttackGoal",
                MOVE | LOOK,
                Trident {
                    ranged: RangedAttack::new(1.0, 40, 40, 10.0, THROW),
                    trident: self.trident,
                },
            ),
            Registration::new(
                2,
                "DrownedAttackGoal",
                MOVE | LOOK,
                Attack {
                    melee: MeleeAttack::new(1.0, false, true),
                },
            ),
            Registration::new(
                5,
                "DrownedGoToBeachGoal",
                MOVE | JUMP,
                MoveToBlock::new(
                    1.0,
                    8,
                    BlockTest::Family(BEACH),
                    BlockOptions {
                        vertical: 2,
                        guard: Some(BEACH_TIME),
                        ..BlockOptions::default()
                    },
                ),
            ),
            Registration::new(6, "DrownedSwimUpGoal", 0, SwimUp::default()),
            Registration::new(
                7,
                "RandomStrollGoal",
                MOVE,
                RandomStroll::new(1.0, StrollOptions::default()),
            ),
        ]);
        let mob = |priority, types: Vec<u16>, must_see, interval| {
            Registration::new(
                priority,
                "NearestAttackableTargetGoal",
                TARGET,
                NearestAttackableTarget::new(
                    TargetKind::Mob,
                    Some(MobTypes::Types(types)),
                    must_see,
                    TargetOptions {
                        interval,
                        ..TargetOptions::default()
                    },
                ),
            )
        };
        let targets = vec![
            Registration::new(
                1,
                "HurtByTargetGoal",
                TARGET,
                HurtByTarget::new(true, vec![self.zombified_piglin], vec![p.drowned]),
            ),
            Registration::new(
                2,
                "NearestAttackableTargetGoal",
                TARGET,
                NearestAttackableTarget::new(
                    TargetKind::Player,
                    None,
                    true,
                    TargetOptions {
                        selector: Some(TargetTest::Family(OK_TARGET)),
                        ..TargetOptions::default()
                    },
                ),
            ),
            mob(3, p.villagers.clone(), false, 10),
            mob(3, vec![p.iron_golem], true, 10),
            mob(3, vec![self.axolotl], true, 10),
            // `Turtle.BABY_ON_LAND_SELECTOR`: any turtle yet.
            p.turtle_target(),
        ];
        Registered { goals, targets }
    }

    /// `finalizeSpawn`: a zombie's with its own equipment, then a nautilus
    /// shell now and then, then the zombie nautilus a natural adult trident
    /// thrower may ride outside the warm oceans' frequent spawns.
    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        self.parts
            .finalize(t, reason, |_, t| self.equipment(t), true);
        let roll = spawn::level_float(t);
        if t.mob.body.mob.equipment.get(Slot::Offhand).is_none() && roll < f(0.03) {
            spawn::equip(t, Slot::Offhand, Some(super::stack(self.shell)));
            let facts = t.level.facts;
            super::put_drop_chance(facts, &mut t.mob.body.mob, Slot::Offhand, 2.0);
        }
        self.nautilus(t, reason);
    }

    /// `updateSwimming`: underwater and wanting to swim it swims.
    fn before_ai(&self, t: &mut Turn) {
        let swimming = t.mob.body.mob.motion.eye_water && wants_to_swim(t);
        t.mob.body.data.set("swimming", Value::bool(swimming));
    }

    /// `DrownedMoveControl.tick`.
    fn move_control(&self, t: &mut Turn) {
        let control = t.mob.body.mob.motion.control.clone();
        if wants_to_swim(t) && t.in_water() {
            let up = match t.target() {
                Some(target) if target.y() > t.y() => 0.002,
                _ if flag(t.data(), "searching") => 0.002,
                _ => 0.0,
            };
            self.travel(t);
            // Its lift is its own step before the push.
            let lift = [0.0, up, 0.0];
            match control {
                Control::MoveTo { target, speed } if !t.mind.navigation.done() => {
                    self.swim(t, target, speed, lift)
                }
                _ => set(t, 0.0, vec![lift]),
            }
        } else {
            let down = if t.on_ground() { 0.0 } else { -0.008 };
            t.mob.body.mob.motion.impulse = Impulse::List(vec![[0.0, down, 0.0]]);
            self.travel(t);
        }
    }

    fn ambient_sound(&self, t: &mut Turn) -> Option<i32> {
        if t.in_water() {
            return t
                .level
                .facts
                .sounds
                .id("minecraft:entity.drowned.ambient_water");
        }
        let name = t.facts.ambient_sound.as_deref()?;
        t.level.facts.sounds.id(name)
    }

    fn swim_sound(&self) -> Option<&'static str> {
        Some("minecraft:entity.drowned.swim")
    }

    /// `wantsToPickUp`: no spears; a zombie's otherwise.
    fn wants(&self, _t: &Turn, item: i32) -> bool {
        !self.spears.contains(&item) && item != self.parts.glow_ink
    }

    /// `canReplaceCurrentItem`: a nautilus shell stays.
    fn can_hold(&self, t: &Turn, _item: i32) -> bool {
        t.mob
            .body
            .mob
            .equipment
            .get(Slot::Offhand)
            .and_then(item_id)
            != Some(self.shell)
    }

    fn preferred_weapons(&self, _type_id: u16) -> Option<&[i32]> {
        Some(&self.preferred)
    }

    fn baby(&self, body: &Body) -> bool {
        flag(&body.data, "baby")
    }

    fn set_baby(&self, mob: &mut Mob, data: &mut FamilyData, baby: bool) {
        zombie::set_baby(mob, data, baby);
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        self.data_of()
    }
}

// ## Goals

/// `DrownedGoToWaterGoal` (`Drowned.GoToWater`): by day out of water it
/// tries ten spots within ten blocks around and two above to six below for
/// water and heads for the first.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct GoToWater {
    wanted: Option<[f64; 3]>,
}

impl Goal for GoToWater {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if !t.level.bright || t.in_water() {
            return false;
        }
        let water = t.level.facts.blocks.id("minecraft:water");
        for _ in 0..10 {
            let [bx, by, bz] = t.block();
            let a = t.int(20);
            let b = t.int(8);
            let c = t.int(20);
            let cell = [bx + a - 10, by + 2 - b, bz + c - 10];
            let block = t.level.block(cell);
            if block.is_some_and(|s| t.level.facts.blocks.block_id(s) == water) {
                let [x, y, z] = cell;
                self.wanted = Some([x as f64 + 0.5, y as f64, z as f64 + 0.5]);
                return true;
            }
        }
        false
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        !t.mind.navigation.done()
    }

    fn start(&mut self, t: &mut Turn) {
        if let Some(p) = self.wanted {
            navigation::move_to(t, p, 1.0);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Drowned.GoToWater"
    }
}

/// `DrownedAttackGoal` (`Drowned.Attack`): a zombie's attack, only at
/// targets it may go after (`okTarget`).
#[derive(Clone, Debug, PartialEq)]
pub struct Attack {
    melee: MeleeAttack,
}

fn target_ok(t: &mut Turn) -> bool {
    let target = t.target().map(|s| s.bbox);
    ok_target(t.level, target.as_ref())
}

impl Goal for Attack {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        self.melee.can_use(t) && target_ok(t)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        self.melee.can_continue(t) && target_ok(t)
    }

    fn start(&mut self, t: &mut Turn) {
        self.melee.start(t);
    }

    fn stop(&mut self, t: &mut Turn) {
        self.melee.stop(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        self.melee.tick(t);
    }

    fn every_tick(&self) -> bool {
        self.melee.every_tick()
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Drowned.Attack"
    }
}

/// `DrownedTridentAttackGoal` (`Drowned.Trident`): `RangedAttackGoal`
/// (every 40 ticks within ten blocks) while it holds a trident, aggressive
/// and using it while it runs.
#[derive(Clone, Debug, PartialEq)]
pub struct Trident {
    ranged: RangedAttack,
    trident: i32,
}

impl Goal for Trident {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        self.ranged.can_use(t)
            && t.mob
                .body
                .mob
                .equipment
                .get(Slot::Mainhand)
                .and_then(item_id)
                == Some(self.trident)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        self.ranged.can_continue(t)
    }

    fn start(&mut self, t: &mut Turn) {
        self.ranged.start(t);
        t.set_aggressive(true);
        t.start_using(crate::mobs::model::Hand::MainHand);
    }

    fn stop(&mut self, t: &mut Turn) {
        self.ranged.stop(t);
        t.stop_using();
        t.set_aggressive(false);
    }

    fn tick(&mut self, t: &mut Turn) {
        self.ranged.tick(t);
    }

    fn every_tick(&self) -> bool {
        self.ranged.every_tick()
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Drowned.Trident"
    }
}

/// `DrownedSwimUpGoal` (`Drowned.SwimUp`): at night in water two blocks
/// below sea level it searches for land, swimming up toward a spot below
/// the surface whenever it has nowhere to go or is close to it; with none
/// to be found it is stuck and stops.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SwimUp {
    stuck: bool,
}

fn swim_up_usable(t: &Turn) -> bool {
    !t.level.bright && t.in_water() && t.y() < (t.level.sea_level - 2) as f64
}

// `closeToNextPos`: within two blocks of its path's end.
fn close(t: &Turn) -> bool {
    match &t.mind.navigation.path {
        Some(path) => {
            let [x, y, z] = path.target.map(|v| v as f64);
            let (dx, dy, dz) = (x - t.x(), y - t.y(), z - t.z());
            dx * dx + dy * dy + dz * dz < 4.0
        }
        None => false,
    }
}

impl Goal for SwimUp {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        swim_up_usable(t)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        swim_up_usable(t) && !self.stuck
    }

    fn start(&mut self, t: &mut Turn) {
        self.stuck = false;
        t.mob.body.data.set("searching", Value::bool(true));
    }

    fn stop(&mut self, t: &mut Turn) {
        t.mob.body.data.set("searching", Value::bool(false));
    }

    fn tick(&mut self, t: &mut Turn) {
        let sea = t.level.sea_level;
        if t.y() < (sea - 1) as f64 && (t.mind.navigation.done() || close(t)) {
            let radians = f(std::f64::consts::PI / 2.0);
            let towards = [t.x(), (sea - 1) as f64, t.z()];
            match random_pos::default_towards(t, 4, 8, towards, radians) {
                None => self.stuck = true,
                Some(p) => {
                    navigation::move_to(t, p, 1.0);
                }
            }
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Drowned.SwimUp"
    }
}
