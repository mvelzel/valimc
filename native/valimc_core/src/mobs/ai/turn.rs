//! One mob as its AI sees and changes it during its tick
//! (`Valimc.AI.Self`): the mob itself (borrowed whole: its position, body,
//! living state, equipment and travel state), its mind (detached from the
//! body while the turn runs and put back when it ends), its type's AI facts
//! and dimensions, and what it reads of the world: the level (blocks,
//! light, rules, the level random), the section's sensing (players, items,
//! mobs as sensed rows), the path facts and its family's hooks. What leaves
//! the mob collects in `effects`, oldest first.

use super::effect::Effect;
use super::fmath::{self, emax, emin, f};
use super::hooks::{item_id, Hooks};
use super::mind::{LookAt, MindState, Own, Swing};
use super::Extra;
use crate::mobs::facts::ai::AiMob;
use crate::mobs::level::{Level, INVISIBLE};
use crate::mobs::model::{Control, FamilyData, Hand, Mind, NativeMob, Rung, Slot, Using};
use crate::mobs::random::LegacyRandom;
use crate::mobs::sensing::{
    self, Conditions, Entity, GameMode, Kind, Ref, Seer, Select, Sensing, SightCache, Uuid,
};
use crate::mobs::term::Value;
use crate::path::PathFacts;
use crate::physics::Aabb;
use std::mem::ManuallyDrop;

/// What a goal keeps of a sensed entity for the rest of its callback: the
/// fields the AI reads, copied out of the section's sensing.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Seen {
    pub reference: Ref,
    pub id: i32,
    pub type_id: Option<u16>,
    pub position: [f64; 3],
    pub eye: f64,
    pub width: f64,
    pub height: f64,
    /// `World.box/1`.
    pub bbox: Aabb,
    pub alive: bool,
    pub mode: Option<GameMode>,
    pub yaw: f64,
    pub pitch: f64,
    pub in_love: i32,
    pub age: i32,
    pub panicking: bool,
    pub target: Option<Ref>,
}

impl Seen {
    pub fn of(e: Entity<'_, Extra>) -> Seen {
        let (id, yaw, pitch, in_love, age, panicking, target) = match e {
            Entity::Player(p) => (p.id, p.yaw, p.pitch, 0, 0, false, None),
            Entity::Mob(m) => (
                m.id,
                m.yaw as f64,
                m.pitch as f64,
                m.in_love,
                m.age,
                m.panicking,
                m.target,
            ),
            Entity::Item(_) => (0, 0.0, 0.0, 0, 0, false, None),
        };
        let (width, height) = match e {
            Entity::Player(p) => (p.width, p.height),
            Entity::Mob(m) => (m.width, m.height),
            Entity::Item(_) => (sensing::SensedItem::WIDTH, sensing::SensedItem::HEIGHT),
        };
        Seen {
            reference: e.reference(),
            id,
            type_id: e.type_id(),
            position: e.position(),
            eye: e.eye(),
            width,
            height,
            bbox: e.bounding_box(),
            alive: e.alive(),
            mode: e.mode(),
            yaw,
            pitch,
            in_love,
            age,
            panicking,
            target,
        }
    }

    pub fn kind(&self) -> Kind {
        self.reference.kind
    }

    pub fn uuid(&self) -> Uuid {
        self.reference.uuid
    }

    /// `World.eye_y/1`.
    pub fn eye_y(&self) -> f64 {
        self.position[1] + self.eye
    }

    pub fn x(&self) -> f64 {
        self.position[0]
    }

    pub fn y(&self) -> f64 {
        self.position[1]
    }

    pub fn z(&self) -> f64 {
        self.position[2]
    }
}

/// The thinking mob as sensing reads it (`World`'s view of `Self`): what
/// targeting conditions and lines of sight need, with the mind's sight
/// cache.
pub struct Eyes<'a> {
    pub uuid: Uuid,
    pub type_id: u16,
    pub position: [f64; 3],
    pub eye_y: f64,
    pub sight: &'a mut SightCache,
    pub data: &'a FamilyData,
    pub own: &'a Own,
    pub target: Option<Ref>,
    pub hooks: &'a dyn Hooks,
}

impl Seer<Extra> for Eyes<'_> {
    fn uuid(&self) -> Uuid {
        self.uuid
    }

    fn type_id(&self) -> u16 {
        self.type_id
    }

    fn position(&self) -> [f64; 3] {
        self.position
    }

    fn eye_y(&self) -> f64 {
        self.eye_y
    }

    fn sight(&mut self) -> &mut SightCache {
        self.sight
    }

    fn can_attack_hook(&self, target: Entity<'_, Extra>) -> bool {
        self.hooks.can_attack(self, target)
    }
}

/// Which of the section's mobs a query takes (`World.mobs_in/3`'s
/// `select`): any, of these types, or a family's test of the type.
#[derive(Clone, Copy, Debug)]
pub enum Kinds<'q> {
    Any,
    Types(&'q [u16]),
    Family(super::hooks::Tag),
}

fn with_kinds<R>(
    level: &Level,
    hooks: &dyn Hooks,
    kinds: Kinds,
    f: impl FnOnce(&Select) -> R,
) -> R {
    match kinds {
        Kinds::Any => f(&Select::Any),
        Kinds::Types(types) => f(&Select::Types(types)),
        Kinds::Family(tag) => {
            let test = |ty: u16| hooks.mob_type(level, tag, ty);
            f(&Select::Where(&test))
        }
    }
}

/// A target test of the entity and the mob (`conditions.select`).
pub type Pick<'s> = &'s dyn Fn(&Level, &Eyes, Entity<'_, Extra>) -> bool;

/// `TargetingConditions` (`World.conditions/2`).
#[derive(Clone, Copy)]
pub struct Targeting<'s> {
    pub combat: bool,
    pub range: f64,
    pub sight: bool,
    pub invisible: bool,
    pub select: Option<Pick<'s>>,
}

impl<'s> Targeting<'s> {
    /// `forCombat()` / `forNonCombat()`.
    pub fn new(combat: bool) -> Targeting<'s> {
        Targeting {
            combat,
            range: -1.0,
            sight: true,
            invisible: true,
            select: None,
        }
    }

    pub fn range(mut self, range: f64) -> Self {
        self.range = range;
        self
    }

    pub fn sight(mut self, sight: bool) -> Self {
        self.sight = sight;
        self
    }

    pub fn invisible(mut self, invisible: bool) -> Self {
        self.invisible = invisible;
        self
    }

    pub fn select(mut self, select: Pick<'s>) -> Self {
        self.select = Some(select);
        self
    }
}

/// One mob's turn.
pub struct Turn<'t, 'w> {
    /// Its network id (the store id).
    pub id: i32,
    pub uuid: Uuid,
    pub type_id: u16,
    /// The mob: `mob.position` is the Elixir's `x`, `y`, `z`; its body the
    /// rotations, motion, ground flag, data and living state.
    pub mob: &'t mut NativeMob,
    /// The mind's live state.
    pub mind: ManuallyDrop<Box<MindState>>,
    /// The mind's random.
    pub random: LegacyRandom,
    memories: Option<Value>,
    pub facts: &'w AiMob,
    pub width: f64,
    pub height: f64,
    pub eye: f64,
    pub level: &'t mut Level<'w>,
    pub sensing: &'t mut Sensing<Extra>,
    pub paths: &'w PathFacts,
    pub hooks: &'w dyn Hooks,
    pub effects: Vec<Effect>,
    /// What the section gives the turn beyond the level and sensing (the
    /// kernel's probe of a goal's own move, mid-tick melee hits); None: a
    /// turn alone.
    pub outside: Option<&'t mut (dyn Outside + 't)>,
    /// The living rules and the families, where the turn runs in a
    /// section's tick (a family that makes and finalizes another mob reads
    /// them: a spider jockey's skeleton); None: a turn alone.
    pub ctx: Option<super::think::Ctx<'w>>,
    seed: u64,
}

/// What a section gives a mob's turn beyond the level and sensing
/// (`world.goal_position` and `world.melee` in the Elixir).
pub trait Outside {
    /// Where a goal's own move (`MobMotion.pre_move`) takes the mob, as the
    /// kernel would move it (`BreathAir.predicted`); None: unknown.
    fn goal_position(&mut self, _t: &Turn) -> Option<[f64; 3]> {
        None
    }

    /// A melee hit on a mob ticking with it, landed now; true when it
    /// killed it (`MobTicks.kills?`).
    fn melee(&mut self, _t: &mut Turn, _target: &Ref) -> bool {
        false
    }
}

impl Drop for Turn<'_, '_> {
    fn drop(&mut self) {
        // SAFETY: the mind is taken once, as the turn ends; nothing reads it
        // after.
        let state = unsafe { ManuallyDrop::take(&mut self.mind) };
        self.mob.body.mob.ai = Some(Mind {
            random: self.random,
            memories: self.memories.take(),
            state: Some(state),
        });
    }
}

impl<'t, 'w> Turn<'t, 'w> {
    /// The turn of `mob` (network id `id`, of type `type_id` with AI facts
    /// `facts` and `[width, height, eye]` dimensions). Its mind is detached
    /// until the turn ends (a mob without one thinks with a fresh one seeded
    /// from its uuid, `Self.fresh`; a mind without live state starts one).
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        mob: &'t mut NativeMob,
        id: i32,
        type_id: u16,
        facts: &'w AiMob,
        dimensions: [f64; 3],
        level: &'t mut Level<'w>,
        sensing: &'t mut Sensing<Extra>,
        paths: &'w PathFacts,
        hooks: &'w dyn Hooks,
    ) -> Turn<'t, 'w> {
        let uuid = mob.uuid;
        let mind = mob.body.mob.ai.take().unwrap_or_else(|| Mind {
            random: LegacyRandom::from_uuid(&uuid),
            memories: None,
            state: None,
        });
        let seed = u64::from_be_bytes(uuid[8..16].try_into().unwrap_or([0; 8]))
            ^ (level.time as u64).rotate_left(32);
        Turn {
            id,
            uuid,
            type_id,
            mob,
            mind: ManuallyDrop::new(mind.state.unwrap_or_default()),
            random: mind.random,
            memories: mind.memories,
            facts,
            width: dimensions[0],
            height: dimensions[1],
            eye: dimensions[2],
            level,
            sensing,
            paths,
            hooks,
            effects: Vec::new(),
            outside: None,
            ctx: None,
            seed,
        }
    }

    /// The mob with its mind attached (`mob.ai` as a record holds it) while
    /// `f` runs: the living rules draw on and change it there (a hurt's
    /// voice, the idle reset).
    pub fn attached<R>(&mut self, f: impl FnOnce(&mut NativeMob) -> R) -> R {
        let state = std::mem::take(&mut **self.mind);
        self.mob.body.mob.ai = Some(Mind {
            random: self.random,
            memories: self.memories.take(),
            state: Some(Box::new(state)),
        });
        let result = f(self.mob);
        if let Some(mind) = self.mob.body.mob.ai.take() {
            self.random = mind.random;
            self.memories = mind.memories;
            if let Some(state) = mind.state {
                **self.mind = *state;
            }
        }
        result
    }

    /// The mob's saved memories (a brain's).
    pub fn memories(&self) -> Option<&Value> {
        self.memories.as_ref()
    }

    // ## The mob

    pub fn x(&self) -> f64 {
        self.mob.position[0]
    }

    pub fn y(&self) -> f64 {
        self.mob.position[1]
    }

    pub fn z(&self) -> f64 {
        self.mob.position[2]
    }

    pub fn pos(&self) -> [f64; 3] {
        self.mob.position
    }

    pub fn yaw(&self) -> f64 {
        self.mob.body.yaw
    }

    pub fn pitch(&self) -> f64 {
        self.mob.body.pitch
    }

    pub fn head(&self) -> f64 {
        self.mob.body.head_yaw
    }

    pub fn on_ground(&self) -> bool {
        self.mob.body.on_ground
    }

    pub fn velocity(&self) -> [f64; 3] {
        self.mob.body.velocity
    }

    pub fn data(&self) -> &FamilyData {
        &self.mob.body.data
    }

    /// `getEyeY`.
    pub fn eye_y(&self) -> f64 {
        self.y() + self.eye
    }

    /// `blockPosition`.
    pub fn block(&self) -> [i32; 3] {
        fmath::block(self.pos())
    }

    /// `distanceToSqr` to a point.
    pub fn distance_sq(&self, p: [f64; 3]) -> f64 {
        fmath::distance_sq(self.pos(), p)
    }

    /// The mob's bounding box.
    pub fn bbox(&self) -> Aabb {
        let half = self.width / 2.0;
        let [x, y, z] = self.pos();
        Aabb {
            min: [x - half, y, z - half],
            max: [x + half, y + self.height, z + half],
        }
    }

    /// `Mob.value`: an attribute's value.
    pub fn attribute(&self, name: &str) -> f64 {
        self.hooks.attribute(self, name)
    }

    // ## Its random

    /// `nextInt(bound)`.
    pub fn int(&mut self, bound: i32) -> i32 {
        self.random.int(bound)
    }

    /// `nextFloat()`, widened.
    pub fn float(&mut self) -> f64 {
        self.random.float() as f64
    }

    /// `nextDouble()`.
    pub fn double(&mut self) -> f64 {
        self.random.double()
    }

    /// `nextBoolean()`.
    pub fn boolean(&mut self) -> bool {
        self.random.boolean()
    }

    /// `nextLong()`.
    pub fn long(&mut self) -> i64 {
        self.random.long()
    }

    /// `nextGaussian()`: the pair's second held in the mind.
    pub fn gaussian(&mut self) -> f64 {
        self.random.gaussian(&mut self.mind.gaussian)
    }

    // ## What leaves it

    pub fn effect(&mut self, effect: Effect) {
        self.effects.push(effect);
    }

    /// A sound's seed (`:crypto.strong_rand_bytes` in the Elixir: no
    /// gameplay reads it), from a stream of the turn's own.
    pub fn next_seed(&mut self) -> i64 {
        // SplitMix64.
        self.seed = self.seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.seed;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        (z ^ (z >> 31)) as i64
    }

    fn source(&self) -> i32 {
        self.level.facts.combat.mob_sounds(self.type_id).source
    }

    /// `Self.sound/4`: `Entity.playSound(sound, volume, pitch)` from the mob,
    /// in its type's source (an unknown sound plays none).
    pub fn sound(&mut self, name: &str, volume: f64, pitch: f64) {
        if let Some(id) = self.level.facts.sounds.id(name) {
            self.sound_id(id, volume, pitch);
        }
    }

    pub fn sound_id(&mut self, id: i32, volume: f64, pitch: f64) {
        let seed = self.next_seed();
        let source = self.source();
        self.effect(Effect::Sound {
            id,
            source,
            volume,
            pitch,
            seed,
        });
    }

    /// `AI.play/4`: a sound of its own pitch (no draw), both rounded.
    pub fn play(&mut self, name: &str, volume: f64, pitch: f64) {
        if let Some(id) = self.level.facts.sounds.id(name) {
            self.sound_id(id, f(volume), f(pitch));
        }
    }

    /// `AI.make_sound/2`: at the mob's volume and voice pitch (a baby's
    /// higher), drawn from its random.
    pub fn make_sound(&mut self, name: &str, base: f32) {
        let pitch = self.random.voice_pitch(base) as f64;
        if let Some(id) = self.level.facts.sounds.id(name) {
            let volume = self.facts.volume;
            self.sound_id(id, volume, pitch);
        }
    }

    /// `Entity.spawnSprintParticle`: over a block that renders, the
    /// particle's place draws twice.
    pub fn sprint_particle(&mut self) {
        let [x, y, z] = self.pos();
        let cell = [fmath::floor(x), fmath::floor(y - 0.2), fmath::floor(z)];
        if let Some(state) = self.level.block(cell) {
            if !self.level.state_flag(state, INVISIBLE) {
                self.double();
                self.double();
            }
        }
    }

    /// `addEffect` on itself.
    pub fn add_effect(&mut self, id: i32, rung: Rung) {
        let hooks = self.hooks;
        hooks.add_effect(self, id, rung);
    }

    // ## Target and aggression

    /// `Mob.setTarget`, through its type's own where it has one.
    pub fn set_target(&mut self, target: Option<Ref>) {
        let hooks = self.hooks;
        if !hooks.set_target(self, target) {
            self.put_target(target);
        }
    }

    /// `Mob.setTarget` itself.
    pub fn put_target(&mut self, target: Option<Ref>) {
        self.mind.target = target;
    }

    pub fn set_aggressive(&mut self, aggressive: bool) {
        self.mind.aggressive = aggressive;
    }

    // ## Move, jump and look controls

    /// `MoveControl.setWantedPosition` (`MobMotion.move_to/3`): a rabbit's
    /// hop keeps its own wanted place and speed; a jump in progress keeps
    /// jumping at the new speed.
    pub fn move_to(&mut self, target: [f64; 3], speed: f64) {
        let motion = &mut self.mob.body.mob.motion;
        let mut speed = speed;
        if let Some(hop) = &mut motion.hop {
            if motion.water > 0.0 {
                speed = 1.5;
            }
            hop.wanted = Some(target);
            hop.speed = speed;
            if speed > 0.0 {
                hop.next_speed = speed;
            }
        }
        motion.control = match motion.control {
            Control::Jumping { .. } => Control::Jumping { speed },
            _ => Control::MoveTo { target, speed },
        };
    }

    /// `MoveControl.setWait`.
    pub fn wait(&mut self) {
        self.mob.body.mob.motion.control = Control::Wait;
    }

    /// `getSpeed`: what the move control last set.
    pub fn speed(&self) -> f64 {
        self.mob.body.mob.motion.speed
    }

    /// `MoveControl.strafe(forwards, right)` (speed modifier 0.25).
    pub fn strafe(&mut self, forward: f64, right: f64) {
        self.mob.body.mob.motion.control = Control::Strafe {
            forward: f(forward),
            right: f(right),
            speed: 0.25,
        };
    }

    /// `JumpControl.jump`.
    pub fn jump(&mut self) {
        self.mind.jump = true;
    }

    /// `LookControl.setLookAt(x, y, z, yMax, xMax)`.
    pub fn look_at(&mut self, p: [f64; 3], y_max: f64, x_max: f64) {
        self.mind.look = Some(LookAt {
            x: p[0],
            y: p[1],
            z: p[2],
            y_max,
            x_max,
            cooldown: 2,
        });
    }

    /// `LookControl.setLookAt(x, y, z)` at its own head speed and pitch limit.
    pub fn look_at_point(&mut self, p: [f64; 3]) {
        let (y_max, x_max) = (self.facts.head_rot_speed, self.facts.max_head_x_rot);
        self.look_at(p, y_max, x_max);
    }

    /// `Mob.lookAt(entity, yMax, xMax)`: its own yaw and pitch toward the
    /// target's eyes (the middle of its box when it has none).
    pub fn look_at_entity(&mut self, target: &Seen, y_max: f64, x_max: f64) {
        let (xd, zd) = (target.x() - self.x(), target.z() - self.z());
        let yd = match target.kind() {
            Kind::Player | Kind::Mob => target.y() + target.eye - self.eye_y(),
            Kind::Item => target.y() + target.height / 2.0 - self.eye_y(),
        };
        let sd = (xd * xd + zd * zd).sqrt();
        let pitch = fmath::rotate_towards(self.pitch(), fmath::pitch(yd, sd), x_max);
        let yaw = fmath::rotate_towards(self.yaw(), fmath::yaw(xd, zd), y_max);
        // `setXRot`'s `x % 360.0F`.
        let pitch = emin(emax(f(pitch % 360.0), -90.0), 90.0);
        self.mob.body.pitch = pitch;
        self.mob.body.yaw = yaw;
    }

    // ## Items in hand

    /// `isHolding(item)` in either hand.
    pub fn holding(&self, item: i32) -> bool {
        let e = &self.mob.body.mob.equipment;
        [Slot::Mainhand, Slot::Offhand]
            .into_iter()
            .any(|s| e.get(s).and_then(item_id) == Some(item))
    }

    /// `startUsingItem(hand)`: a held item, unless it uses one already.
    pub fn start_using(&mut self, hand: Hand) {
        let mob = &mut self.mob.body.mob;
        if mob.using.is_none() {
            let slot = match hand {
                Hand::OffHand => Slot::Offhand,
                Hand::MainHand => Slot::Mainhand,
            };
            if mob.equipment.get(slot).is_some() {
                mob.using = Some(Using { hand, ticks: 0 });
            }
        }
    }

    pub fn stop_using(&mut self) {
        self.mob.body.mob.using = None;
    }

    pub fn ticks_using(&self) -> i32 {
        self.mob.body.mob.using.as_ref().map_or(0, |u| u.ticks)
    }

    pub fn using(&self) -> bool {
        self.mob.body.mob.using.is_some()
    }

    /// `LivingEntity.swing`: an arm swing unless one is in its first half.
    pub fn swing(&mut self, hand: Hand) {
        if let Some(s) = self.mind.swing {
            if s.ticks <= s.duration / 2 && s.ticks > 0 {
                return;
            }
        }
        let duration = self.swing_duration();
        self.mind.swing = Some(Swing { duration, ticks: 0 });
        self.effect(Effect::Swing(hand));
    }

    fn swing_duration(&self) -> i32 {
        let names = &self.level.facts.effects;
        let effects = &self.mob.body.mob.living.effects;
        let amplifier = |name: &str| {
            names
                .id(name)
                .and_then(|id| effects.amplifier(id as i32))
                .map(|a| a as i32)
        };
        match (
            amplifier("haste"),
            amplifier("conduit_power"),
            amplifier("mining_fatigue"),
        ) {
            (None, None, None) => 6,
            (None, None, Some(fatigue)) => 6 + (1 + fatigue) * 2,
            (haste, conduit, _) => 6 - (1 + haste.unwrap_or(0).max(conduit.unwrap_or(0))),
        }
    }

    // ## Fluids

    /// `isInWater` (where its last move left it).
    pub fn in_water(&self) -> bool {
        self.mob.body.mob.motion.water > 0.0
    }

    pub fn in_lava(&self) -> bool {
        self.mob.body.mob.motion.lava > 0.0
    }

    pub fn in_liquid(&self) -> bool {
        self.in_water() || self.in_lava()
    }

    /// The drowning test: its eyes in water outside a bubble column.
    pub fn submerged(&self) -> bool {
        let eye = self.mob.body.mob.motion.eye;
        eye.water
            && !self
                .level
                .facts
                .blocks
                .is(eye.state as u16, "minecraft:bubble_column")
    }

    /// `getFluidJumpThreshold`.
    pub fn jump_threshold(&self) -> f64 {
        if self.eye < 0.4 {
            0.0
        } else {
            0.4
        }
    }

    // ## What it senses

    /// The level, the section's sensing and the mob's eyes, borrowed apart.
    pub fn split(&mut self) -> (&Level<'w>, &Sensing<Extra>, Eyes<'_>) {
        let eye_y = self.eye_y();
        let mind: &mut MindState = &mut self.mind;
        let eyes = Eyes {
            uuid: self.uuid,
            type_id: self.type_id,
            position: self.mob.position,
            eye_y,
            sight: &mut mind.sight,
            data: &self.mob.body.data,
            own: &mind.own,
            target: mind.target,
            hooks: self.hooks,
        };
        (&*self.level, &*self.sensing, eyes)
    }

    /// `World.entity/2`.
    pub fn entity(&self, r: Option<&Ref>) -> Option<Seen> {
        self.sensing.entity(r?).map(Seen::of)
    }

    /// `World.target/1`: the mind's target while valid.
    pub fn target(&mut self) -> Option<Seen> {
        let target = self.mind.target;
        let (level, sensing, eyes) = self.split();
        sensing.target(level, &eyes, target.as_ref()).map(Seen::of)
    }

    /// `World.can_attack?/2`.
    pub fn can_attack(&mut self, r: &Ref) -> bool {
        let (level, sensing, eyes) = self.split();
        sensing
            .entity(r)
            .is_some_and(|e| sensing::can_attack(level, &eyes, e))
    }

    /// `World.sees?/2`: line of sight, cached for the tick.
    pub fn sees(&mut self, r: &Ref) -> bool {
        let (level, sensing, mut eyes) = self.split();
        match sensing.entity(r) {
            Some(e) => sensing::sees(level, &mut eyes, e),
            None => false,
        }
    }

    /// `World.test/3`.
    pub fn test(&mut self, r: &Ref, targeting: &Targeting) -> bool {
        let (level, sensing, mut eyes) = self.split();
        let Some(e) = sensing.entity(r) else {
            return false;
        };
        with_conditions(level, targeting, |c| sensing::test(level, &mut eyes, e, c))
    }

    /// `World.nearest_player/5`.
    pub fn nearest_player(&mut self, targeting: &Targeting, point: [f64; 3]) -> Option<Seen> {
        let (level, sensing, mut eyes) = self.split();
        with_conditions(level, targeting, |c| {
            sensing::nearest_player(level, sensing, &mut eyes, c, point)
                .map(|p| Seen::of(Entity::Player(p)))
        })
    }

    /// `World.nearest_mob/6`.
    pub fn nearest_mob(
        &mut self,
        kinds: Kinds,
        b: &Aabb,
        targeting: &Targeting,
        point: [f64; 3],
    ) -> Option<Seen> {
        let hooks = self.hooks;
        let (level, sensing, mut eyes) = self.split();
        with_kinds(level, hooks, kinds, |select| {
            with_conditions(level, targeting, |c| {
                sensing::nearest_mob(level, sensing, &mut eyes, select, b, c, point)
                    .map(|m| Seen::of(Entity::Mob(m)))
            })
        })
    }

    /// `World.nearest/6` over the players whose box meets `players_in` (all
    /// when None) and the section's mobs `select` takes meeting `b`, players
    /// first.
    pub fn nearest_living(
        &mut self,
        players: impl Fn(&Level, Entity<'_, Extra>) -> bool,
        kinds: Kinds,
        b: &Aabb,
        targeting: &Targeting,
        point: [f64; 3],
    ) -> Option<Seen> {
        let hooks = self.hooks;
        let (level, sensing, mut eyes) = self.split();
        let mobs = with_kinds(level, hooks, kinds, |select| sensing.mobs_in(select, b));
        let candidates = sensing
            .players
            .iter()
            .map(Entity::Player)
            .filter(|&p| players(level, p))
            .chain(mobs.into_iter().map(|i| Entity::Mob(sensing.mob_at(i))));
        with_conditions(level, targeting, |c| {
            sensing::nearest(level, &mut eyes, candidates, c, point).map(Seen::of)
        })
    }

    /// `World.mobs_in/3`: the section's mobs `select` takes meeting `b`, in
    /// the section's order.
    pub fn mobs_in(&self, kinds: Kinds, b: &Aabb) -> Vec<Seen> {
        with_kinds(self.level, self.hooks, kinds, |select| {
            self.sensing.mobs_in(select, b)
        })
        .into_iter()
        .map(|i| Seen::of(Entity::Mob(self.sensing.mob_at(i))))
        .collect()
    }

    /// `World.melee/3`: a melee hit on a mob ticking with it, which its
    /// owner lands now (`Hooks::melee`); a mob it killed is sensed dead.
    pub fn melee(&mut self, target: &Ref) {
        if target.kind == Kind::Mob {
            let killed = match self.outside.take() {
                Some(outside) => {
                    let killed = outside.melee(self, target);
                    self.outside = Some(outside);
                    killed
                }
                None => {
                    let hooks = self.hooks;
                    hooks.melee(self, target)
                }
            };
            if killed {
                self.sensing.resense(&target.uuid, |m| m.alive = false);
                let hooks = self.hooks;
                hooks.killed(self, target);
            }
        }
    }
}

fn with_conditions<'e, R>(
    level: &Level,
    targeting: &Targeting,
    f: impl FnOnce(&Conditions<'_, Extra, Eyes<'e>>) -> R,
) -> R {
    let pick = targeting.select;
    let select = move |e: Entity<'_, Extra>, eyes: &Eyes<'e>| match pick {
        Some(p) => p(level, eyes, e),
        None => true,
    };
    let conditions = Conditions {
        combat: targeting.combat,
        range: targeting.range,
        sight: targeting.sight,
        invisible: targeting.invisible,
        select: pick.map(|_| &select as &dyn Fn(Entity<'_, Extra>, &Eyes<'e>) -> bool),
    };
    f(&conditions)
}

/// `SwingState.tick` (each base tick): a swing past its length ends.
pub fn swing_tick(swing: Option<Swing>) -> Option<Swing> {
    match swing {
        Some(s) if s.ticks > s.duration => None,
        Some(s) => Some(Swing {
            duration: s.duration,
            ticks: s.ticks + 1,
        }),
        None => None,
    }
}
