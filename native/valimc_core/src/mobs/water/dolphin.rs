//! Dolphins (`Valimc.AI.Mobs.Dolphin`, vanilla's `Dolphin`): smart swimmers
//! that breathe air.
//!
//! - **Moving**: to random spots in water by its smooth swimming move
//!   control (turning ten degrees a tick, pitching up to 85 toward its
//!   target, its input split between forward and up) and look control; it
//!   travels as a dolphin, sinking slowly without a target, and leaps out of
//!   the water now and then (`Jump`).
//! - **Air**: it holds its breath for 4,800 ticks and swims up for air below
//!   140 (`BreathAirGoal`); out of water it dries out over 2,400 ticks (rain
//!   keeps it moist), flopping about, hurt each tick once dry.
//! - **Players**: it swims along with a swimming player, giving it Dolphin's
//!   Grace now and then (`SwimWithPlayer`); hurt by one it bites back. It
//!   shies from guardians, plays with free items in the water (one in its
//!   mouth, tossed again: `MoveToItem`, `PlayWithItems`) and eats fish from
//!   a player's hand, after which it looks for treasure (`Treasure`: a
//!   structure query, answered at once where the level has a `Locator`,
//!   else deferred to its owner as `Effect::Locate`, whose answer comes back
//!   in `Level::located`).
//!
//! Its moistness, whether it got fish and its treasure are its data (saved),
//! with an ageable mob's age.

use super::{entity, fields, flag, int, sound, value};
use crate::mobs::ai::control::smooth_swimming::{self, SmoothSwimming};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{self, f, reduced};
use crate::mobs::ai::goal::{Goal, JUMP, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::{
    AvoidEntity, BreathAir, EntityTest, FollowRidden, HurtByTarget, LookAtPlayer, MeleeAttack,
    RandomLookAround, RandomStroll, TryFindLiquid,
};
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::navigation::{self, NavKind};
use crate::mobs::ai::turn::{Eyes, Seen, Targeting, Turn};
use crate::mobs::ai::{random_pos, spawn, Extra};
use crate::mobs::animals::{self, age, can_age_up};
use crate::mobs::combat::Family;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::interact::{Done, Hand, InteractEvent, Interaction, Outcome};
use crate::mobs::kinds::{Kind, KindMotion, NavSpec, Registered, Registration};
use crate::mobs::level::{FluidKind, Query};
use crate::mobs::living::items;
use crate::mobs::model::{Body, FamilyData, Slot, Travel, TravelKind};
use crate::mobs::sensing::{inflate, intersects, Entity, Kind as RefKind, Ref, SensedItem};
use crate::mobs::term::{Atom, Map, Value, NIL};
use crate::path::SWIMMABLE;

pub const DOLPHIN: &str = "minecraft:dolphin";

pub const MAX_AIR: i32 = 4800;
const MOIST: i64 = 2400;
/// `(float)Math.PI / 180.0F`, widened.
const RADIANS: f64 = (std::f64::consts::PI / 180.0) as f32 as f64;

const CONTROLS: SmoothSwimming = SmoothSwimming {
    max_x: 85.0,
    max_y: 10.0,
    in_water: 0.02,
    out: 0.1,
    gravity: true,
};

/// The dolphin family.
pub struct Dolphin {
    types: [&'static str; 1],
    type_id: u16,
    guardians: Vec<u16>,
    baby: [f32; 3],
    fishes: Vec<i32>,
    blocks_jump: Vec<i32>,
    breathing: [i32; 3],
    grace: i32,
    eat: i32,
    dry_out: u16,
}

impl Dolphin {
    pub fn new(facts: &MobFacts) -> Result<Dolphin, String> {
        let type_id = entity(facts, DOLPHIN)?;
        let baby = facts
            .animal
            .water_ageable
            .get(&type_id)
            .map(|(_, dims)| *dims)
            .ok_or("no water ageable facts for the dolphin")?;
        let effect = |name| super::effect(facts, name);
        Ok(Dolphin {
            types: [DOLPHIN],
            type_id,
            guardians: vec![
                entity(facts, "minecraft:guardian")?,
                entity(facts, "minecraft:elder_guardian")?,
            ],
            baby,
            fishes: crate::mobs::monsters::item_tag(facts, "minecraft:fishes"),
            blocks_jump: facts
                .tags
                .get("minecraft:block", "minecraft:blocks_dolphin_jump")
                .map(<[i32]>::to_vec)
                .unwrap_or_default(),
            breathing: [
                effect("minecraft:water_breathing")?,
                effect("minecraft:conduit_power")?,
                effect("minecraft:breath_of_the_nautilus")?,
            ],
            grace: effect("minecraft:dolphins_grace")?,
            eat: sound(facts, "minecraft:entity.dolphin.eat")?,
            dry_out: facts
                .damage_types
                .id("minecraft:dry_out")
                .ok_or("no dry_out damage")?,
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[
            ("age", Value::Int(0)),
            ("forced_age", Value::Int(0)),
            ("age_locked", Value::bool(false)),
            ("got_fish", Value::bool(false)),
            ("moistness", Value::Int(MOIST)),
            ("treasure", NIL),
        ])
    }

    /// `Living.Air.breathes?/1`.
    fn breathes(&self, t: &Turn) -> bool {
        let effects = &t.mob.body.mob.living.effects;
        self.breathing.iter().any(|&id| effects.get(id).is_some())
    }

    // `hurt(dryOut(), 1)`, through the one hurt path.
    fn dry(&self, t: &mut Turn) {
        let Some(ctx) = t.ctx else { return };
        let rules = ctx.rules;
        let source = self.dry_out;
        let (events, _) = t.attached(|mob| crate::mobs::combat::hurt_mob(rules, mob, source, 1.0));
        t.effects.extend(events.into_iter().map(Effect::Living));
    }

    /// `Dolphin.tick` after its super: moist in water or rain, else drying
    /// (hurt each tick once dry) and flopping on the ground.
    fn moisten(&self, t: &mut Turn) {
        let [x, y, z] = t.pos();
        let top = y + t.height;
        if t.in_water() || t.level.rain([x, y, z], top) {
            t.mob.body.data.set("moistness", Value::Int(MOIST));
            return;
        }
        let moistness = int(t.data(), "moistness") - 1;
        t.mob.body.data.set("moistness", Value::Int(moistness));
        if moistness <= 0 {
            self.dry(t);
        }
        if t.on_ground() {
            let a = t.float();
            let b = t.float();
            let side = |v: f64| f(f(f(v * 2.0) - 1.0) * f(0.2));
            let [vx, vy, vz] = t.velocity();
            let roll = t.float();
            t.mob.body.velocity = [vx + side(a), vy + 0.5, vz + side(b)];
            t.mob.body.yaw = f(roll * 360.0);
            t.mob.body.on_ground = false;
        }
    }
}

/// The items it may play with: free, in the water, within eight blocks.
pub fn items(t: &Turn) -> Vec<SensedItem> {
    let b = inflate(&t.bbox(), 8.0, 8.0, 8.0);
    t.sensing
        .items
        .iter()
        .filter(|i| {
            i.count > 0
                && i.pickup_delay == 0
                && intersects(&Entity::<Extra>::Item(i).bounding_box(), &b)
                && i.in_water
        })
        .cloned()
        .collect()
}

/// `ItemGoal.dropItem`: what is in its mouth, tossed ahead from below its
/// eyes (40 ticks before anyone may take it); false with nothing there.
fn toss(t: &mut Turn) -> bool {
    let Some(stack) = t.mob.body.mob.equipment.get(Slot::Mainhand).cloned() else {
        return false;
    };
    let dir = t.float();
    let dir = f(dir * f(std::f64::consts::PI * 2.0));
    let p = t.float();
    let pow = f(f(0.02) * p);
    let yaw = f(t.yaw() * RADIANS);
    let pitch = f(t.pitch() * RADIANS);
    let speed = f(0.3);
    let (sin, cos) = (fmath::sin, fmath::cos);
    let velocity = [
        f(f(f(speed * -sin(yaw)) * cos(pitch)) + f(cos(dir) * pow)),
        f(f(speed * sin(pitch)) * f(1.5)),
        f(f(f(speed * cos(yaw)) * cos(pitch)) + f(sin(dir) * pow)),
    ];
    let at = [t.x(), t.eye_y() - f(0.3), t.z()];
    t.mob.body.mob.equipment.set(Slot::Mainhand, None);
    t.effect(Effect::Throw(Value::Tuple(vec![
        stack,
        Value::vec3(at),
        Value::vec3(velocity),
        Value::Int(40),
    ])));
    true
}

impl Hooks for Dolphin {
    fn voice(&self, _type_id: u16, data: &FamilyData) -> f32 {
        if age(data) < 0 {
            1.5
        } else {
            1.0
        }
    }

    /// `SmoothSwimmingLookControl(10)`.
    fn look_control(&self, t: &mut Turn) -> bool {
        smooth_swimming::look(t, 10.0);
        true
    }

    /// A baby bites nothing.
    fn can_attack(&self, eyes: &Eyes, _target: Entity<'_, Extra>) -> bool {
        age(eyes.data) >= 0
    }

    /// `playAttackSound` after a bite.
    fn hit(&self, t: &mut Turn, _target: &Seen) {
        t.play("minecraft:entity.dolphin.attack", 1.0, 1.0);
    }
}

impl Family for Dolphin {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Dolphin::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn max_air(&self) -> i32 {
        MAX_AIR
    }

    fn own_air(&self) -> bool {
        true
    }

    fn voice(&self, body: &Body) -> f32 {
        Hooks::voice(self, self.type_id, &body.data)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let data = &body.data;
        vec![
            value(
                "ageable_baby",
                Value::bool(age(data) < 0),
                Value::bool(false),
            ),
            value(
                "age_locked",
                Value::bool(data.age_locked().unwrap_or(false)),
                Value::bool(false),
            ),
            value(
                "dolphin_got_fish",
                Value::bool(flag(data, "got_fish")),
                Value::bool(false),
            ),
            value(
                "dolphin_moistness",
                Value::Int(int(data, "moistness")),
                Value::Int(MOIST),
            ),
        ]
    }

    fn dimensions(&self, body: &Body) -> Option<[f32; 3]> {
        (age(&body.data) < 0).then_some(self.baby)
    }
}

impl Kind for Dolphin {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Dolphin"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered {
            goals: vec![
                Registration::new(0, "BreathAirGoal", MOVE | LOOK, BreathAir::new()),
                Registration::new(0, "TryFindLiquidGoal", 0, TryFindLiquid::new()),
                Registration::new(
                    1,
                    "DolphinSwimToTreasureGoal",
                    MOVE | LOOK,
                    Treasure::default(),
                ),
                Registration::new(
                    2,
                    "DolphinSwimWithPlayerGoal",
                    MOVE | LOOK,
                    SwimWithPlayer {
                        speed: 4.0,
                        player: None,
                        grace: self.grace,
                    },
                ),
                Registration::new(
                    4,
                    "RandomSwimmingGoal",
                    MOVE,
                    RandomStroll::new(
                        1.0,
                        StrollOptions {
                            interval: 10,
                            swim: true,
                            ..StrollOptions::default()
                        },
                    ),
                ),
                Registration::new(
                    4,
                    "RandomLookAroundGoal",
                    MOVE | LOOK,
                    RandomLookAround::new(),
                ),
                Registration::new(
                    5,
                    "LookAtPlayerGoal",
                    LOOK,
                    LookAtPlayer::new(6.0, 0.02, false, None),
                ),
                Registration::new(
                    5,
                    "DolphinJumpGoal",
                    MOVE | JUMP,
                    Jump {
                        interval: reduced(10),
                        breached: false,
                        blocks: self.blocks_jump.clone(),
                    },
                ),
                Registration::new(
                    6,
                    "MeleeAttackGoal",
                    MOVE | LOOK,
                    MeleeAttack::new(f(1.2), true, false),
                ),
                Registration::new(7, "MoveToItemGoal", MOVE, MoveToItem { cooldown: 0 }),
                Registration::new(8, "PlayWithItemsGoal", 0, PlayWithItems),
                Registration::new(8, "FollowPlayerRiddenEntityGoal", 0, FollowRidden::new()),
                Registration::new(8, "FollowPlayerRiddenEntityGoal", 0, FollowRidden::new()),
                Registration::new(
                    9,
                    "AvoidEntityGoal",
                    MOVE,
                    AvoidEntity::new(EntityTest::Mobs(self.guardians.clone()), 8.0, 1.0, 1.0),
                ),
            ],
            // `HurtByTargetGoal(alert)` alerting none (the Elixir's
            // `alert_types` are empty).
            targets: vec![Registration::new(
                1,
                "HurtByTargetGoal",
                TARGET,
                HurtByTarget::new(true, Vec::new(), self.guardians.clone()),
            )],
        }
    }

    /// `WaterBoundPathNavigation` that may breach the surface.
    fn navigation(&self, _type_id: u16) -> NavSpec {
        NavSpec {
            kind: NavKind::Water,
            breaching: true,
            ..NavSpec::default()
        }
    }

    /// Its travel when its AI does not choose one (dead, `NoAI`): no target.
    fn kernel_motion(&self) -> KindMotion {
        KindMotion {
            fluid_pushed: false,
            travel: (TravelKind::Dolphin, true),
            ..KindMotion::default()
        }
    }

    /// `finalizeSpawn`: full air, level, then `Mob`'s part.
    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        t.mob.body.mob.living.air_supply = MAX_AIR;
        t.mob.body.pitch = 0.0;
        spawn::mob(t, reason);
    }

    /// `SmoothSwimmingMoveControl(85, 10, 0.02, 0.1, true)`; it travels as a
    /// dolphin, sinking without a target.
    fn move_control(&self, t: &mut Turn) {
        smooth_swimming::tick(t, &CONTROLS);
        let sink = t.mind.target.is_none();
        t.mob.body.mob.motion.travel = Some(Travel {
            kind: TravelKind::Dolphin,
            sink,
        });
    }

    fn after_ai(&self, t: &mut Turn) {
        animals::settle_ageable(t);
    }

    fn after_tick(&self, t: &mut Turn) {
        if t.mob.body.mob.no_ai {
            t.mob.body.mob.living.air_supply = MAX_AIR;
        } else {
            self.moisten(t);
        }
    }

    /// `LivingEntity.baseTick`'s air with a dolphin's supply: its eyes in
    /// water use it up (drowning at -20), out of water it is full at once.
    fn breath(&self, t: &mut Turn) -> Option<(i32, f64)> {
        let air = t.mob.body.mob.living.air_supply;
        Some(if t.submerged() && !self.breathes(t) {
            if air - 1 <= -20 {
                (0, 2.0)
            } else {
                (air - 1, 0.0)
            }
        } else {
            (MAX_AIR, 0.0)
        })
    }

    /// In water it calls one way, out of it another.
    fn ambient_sound(&self, t: &mut Turn) -> Option<i32> {
        let name = if t.in_water() {
            "minecraft:entity.dolphin.ambient_water"
        } else {
            "minecraft:entity.dolphin.ambient"
        };
        t.level.facts.sounds.id(name)
    }

    fn splash_sound(&self) -> Option<&'static str> {
        Some("minecraft:entity.dolphin.splash")
    }

    fn swim_sound(&self) -> Option<&'static str> {
        Some("minecraft:entity.dolphin.swim")
    }

    fn still(&self) -> bool {
        true
    }

    /// `Dolphin.pickUpItem`: an item into its empty mouth, whole; it never
    /// takes one the usual way.
    fn pick_up(&self, t: &mut Turn, item: &SensedItem) -> bool {
        if t.mob.body.mob.equipment.get(Slot::Mainhand).is_none() {
            let stack = items::new_stack(item.item, item.count, item.components.clone());
            let mob = &mut t.mob.body.mob;
            mob.equipment.set(Slot::Mainhand, Some(stack));
            mob.drop_chances.0[Slot::Mainhand as usize] = Some(2.0);
            t.effect(Effect::Pickup {
                item: item.uuid,
                count: item.count,
            });
            if let Some(i) = t.sensing.items.iter_mut().find(|i| i.uuid == item.uuid) {
                i.count -= item.count;
            }
        }
        true
    }

    /// `Dolphin.mobInteract`: a fish from a player's hand is eaten (it then
    /// has fish, or a baby grows).
    fn interact(&self, i: &mut Interaction) -> Outcome {
        let Some(id) = i.request.item_id() else {
            return Outcome::Pass;
        };
        if !self.fishes.contains(&id) {
            return Outcome::Pass;
        }
        if can_age_up(&i.mob.body.data) {
            animals::feed_baby(i.mob);
        } else {
            i.mob.body.data.set("got_fish", Value::bool(true));
        }
        Outcome::Done(Done {
            hand: Some(Hand::Use(1)),
            swing: true,
            events: vec![InteractEvent::Sound {
                sound: self.eat,
                source: "neutral",
                volume: 1.0,
                pitch: 1.0,
            }],
            ..Done::default()
        })
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Dolphin::data_of()
    }
}

// ## Goals

/// The treasure in its data.
fn treasure(data: &FamilyData) -> Option<[i32; 3]> {
    match data.get("treasure")? {
        Value::Tuple(v) if v.len() == 3 => {
            let c = |i: usize| v[i].as_int().map(|n| n as i32);
            Some([c(0)?, c(1)?, c(2)?])
        }
        _ => None,
    }
}

// `BlockPos.closerToCenterThan`.
fn near(t: &Turn, [x, y, z]: [i32; 3], range: f64) -> bool {
    t.distance_sq([x as f64 + 0.5, y as f64 + 0.5, z as f64 + 0.5]) < range * range
}

fn reached(t: &Turn) -> bool {
    match treasure(t.data()) {
        None => false,
        Some([x, _, z]) => near(t, [x, fmath::floor(t.y()), z], 4.0),
    }
}

/// `DolphinSwimToTreasureGoal` (`Dolphin.Treasure`): a dolphin that ate
/// fish (with air to spare) looks for treasure, waiting for its structure
/// query without blocking, then swims toward it in water waypoints.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Treasure {
    stuck: bool,
    waiting: bool,
    request: Option<u64>,
    query: Option<Query>,
}

impl Treasure {
    fn ask(&self, t: &mut Turn) {
        let (Some(request), Some(q)) = (self.request, &self.query) else {
            return;
        };
        let query = Map::from_atoms([
            ("tag", Value::Binary(q.tag.as_bytes().to_vec())),
            (
                "position",
                Value::Tuple(q.position.iter().map(|&c| Value::Int(c as i64)).collect()),
            ),
            ("radius", Value::Int(q.radius as i64)),
        ]);
        t.effect(Effect::Locate(Value::Tuple(vec![
            Value::Binary(t.uuid.to_vec()),
            Value::Int(request as i64),
            Value::Map(query),
        ])));
    }

    fn located(&mut self, t: &mut Turn, result: Option<[i32; 3]>) {
        self.waiting = false;
        match result {
            Some(p) => {
                let pos = Value::Tuple(p.iter().map(|&c| Value::Int(c as i64)).collect());
                t.mob.body.data.set("treasure", pos);
                t.effect(Effect::Event(38));
            }
            None => self.stuck = true,
        }
    }

    // `DolphinSwimToTreasureGoal.tick` once it knows where to go.
    fn swim(&mut self, t: &mut Turn) {
        let Some([x, y, z]) = treasure(t.data()) else {
            return;
        };
        if self.stuck {
            return;
        }
        let nav = &t.mind.navigation;
        let target = nav.target;
        if !(nav.done() || target.is_some_and(|p| near(t, p, 12.0))) {
            return;
        }
        let towards = [x as f64 + 0.5, y as f64 + 0.5, z as f64 + 0.5];
        let eighth = f(std::f64::consts::PI / 8.0);
        let half = f(std::f64::consts::PI / 2.0);
        let mut at = random_pos::default_towards(t, 16, 1, towards, eighth);
        if at.is_none() {
            at = random_pos::default_towards(t, 8, 4, towards, half);
        }
        if at.is_some_and(|p| !water(t, p)) {
            at = random_pos::default_towards(t, 8, 5, towards, half);
        }
        match at {
            None => self.stuck = true,
            Some(p) => {
                let (y_max, x_max) = (t.facts.max_head_y_rot + 20.0, t.facts.max_head_x_rot);
                t.look_at(p, y_max, x_max);
                navigation::move_to(t, p, 1.3);
                let bound = self.adjusted(80) as i32;
                if spawn::level_int(t, bound) == 0 {
                    t.effect(Effect::Event(38));
                }
            }
        }
    }
}

// Water that a swimmer may path through, at `at`.
fn water(t: &Turn, at: [f64; 3]) -> bool {
    let pos = fmath::block(at);
    match t.level.block(pos) {
        None => false,
        Some(state) => {
            t.level.fluid(pos) == FluidKind::Water
                && t.paths
                    .flags
                    .get(state as usize)
                    .is_some_and(|f| f & SWIMMABLE != 0)
        }
    }
}

impl Goal for Treasure {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        flag(t.data(), "got_fish") && t.mob.body.mob.living.air_supply >= 100
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        !self.stuck
            && t.mob.body.mob.living.air_supply >= 100
            && (self.waiting || (treasure(t.data()).is_some() && !reached(t)))
    }

    fn interruptable(&self) -> bool {
        false
    }

    fn start(&mut self, t: &mut Turn) {
        navigation::stop(t);
        let query = Query {
            tag: "minecraft:dolphin_located",
            position: t.block(),
            radius: 50,
        };
        self.stuck = false;
        self.waiting = false;
        self.request = None;
        self.query = Some(query.clone());
        match t.level.locate(&query) {
            None => {
                self.waiting = true;
                self.request = Some(t.next_seed() as u64);
                self.ask(t);
            }
            Some(result) => self.located(t, result),
        }
    }

    fn stop(&mut self, t: &mut Turn) {
        if self.stuck || reached(t) {
            t.mob.body.data.set("got_fish", Value::bool(false));
        }
        self.waiting = false;
        self.request = None;
    }

    fn tick(&mut self, t: &mut Turn) {
        if self.waiting {
            let key = (t.uuid, self.request.unwrap_or(0));
            match t.level.located.remove(&key) {
                Some(result) => self.located(t, result),
                None => {
                    self.ask(t);
                    return;
                }
            }
        }
        self.swim(t);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Dolphin.Treasure"
    }
}

fn swimming(t: &Turn, r: &Ref) -> bool {
    r.kind == RefKind::Player
        && t.sensing
            .players
            .iter()
            .any(|p| p.uuid == r.uuid && p.swimming)
}

/// `DolphinSwimWithPlayerGoal` (`Dolphin.SwimWithPlayer`): it swims along
/// with the nearest player swimming within ten blocks (seen or not) and
/// gives it Dolphin's Grace for five seconds now and then.
#[derive(Clone, Debug, PartialEq)]
pub struct SwimWithPlayer {
    speed: f64,
    player: Option<Ref>,
    grace: i32,
}

impl SwimWithPlayer {
    fn grace(&self, t: &mut Turn) {
        let Some(target) = self.player else { return };
        let actions = Value::List(vec![Value::Tuple(vec![
            Value::atom("add"),
            Value::Int(self.grace as i64),
            Value::List(vec![Value::Tuple(vec![
                Value::Int(100),
                Value::Int(0),
                Value::bool(false),
                Value::bool(true),
                Value::bool(true),
            ])]),
        ])]);
        t.effect(Effect::GiveEffect { target, actions });
    }
}

impl Goal for SwimWithPlayer {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let targeting = Targeting::new(false).range(10.0).sight(false);
        let at = t.pos();
        match t.nearest_player(&targeting, at) {
            None => {
                self.player = None;
                false
            }
            Some(p) => {
                self.player = Some(p.reference);
                swimming(t, &p.reference) && t.mind.target != Some(p.reference)
            }
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        match t.entity(self.player.as_ref()) {
            Some(p) => swimming(t, &p.reference) && t.distance_sq(p.position) < 256.0,
            None => false,
        }
    }

    fn start(&mut self, t: &mut Turn) {
        self.grace(t);
    }

    fn stop(&mut self, t: &mut Turn) {
        self.player = None;
        navigation::stop(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        let Some(player) = t.entity(self.player.as_ref()) else {
            return;
        };
        t.look_at([player.x(), player.eye_y(), player.z()], 21.0, 1.0);
        if t.distance_sq(player.position) < 6.25 {
            navigation::stop(t);
        } else {
            navigation::move_to_entity(t, &player, self.speed, 1);
        }
        // The player's level random (`player.level().getRandom()`).
        if swimming(t, &player.reference) && spawn::level_int(t, 6) == 0 {
            self.grace(t);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Dolphin.SwimWithPlayer"
    }
}

/// `DolphinJumpGoal` (`Dolphin.Jump`): now and then (one chance in half its
/// interval), with clear water ahead along its heading and air above it, it
/// leaps: motion 0.6 ahead and 0.7 up; while in the air it pitches along its
/// flight and splashes back in with its jump sound.
#[derive(Clone, Debug, PartialEq)]
pub struct Jump {
    interval: i64,
    breached: bool,
    blocks: Vec<i32>,
}

const STEPS: [i32; 6] = [0, 1, 4, 5, 6, 7];

// Java's `!(a < b)`: true where `a` is not below `b` (or either is NaN).
fn not_below(a: f64, b: f64) -> bool {
    a.partial_cmp(&b) != Some(std::cmp::Ordering::Less)
}

impl Jump {
    // `getMotionDirection`: the horizontal direction its yaw faces.
    fn direction(t: &Turn) -> (i32, i32) {
        match (t.yaw() / 90.0 + 0.5).floor().rem_euclid(4.0) as i32 {
            0 => (0, 1),
            1 => (-1, 0),
            2 => (0, -1),
            _ => (1, 0),
        }
    }

    fn blocks(&self, t: &Turn, pos: [i32; 3]) -> bool {
        match t.level.block(pos) {
            None => true,
            Some(state) => t
                .level
                .facts
                .blocks
                .block_id(state)
                .is_some_and(|id| self.blocks.contains(&(id as i32))),
        }
    }
}

impl Goal for Jump {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if t.int(self.interval as i32) != 0 {
            return false;
        }
        let (sx, sz) = Jump::direction(t);
        let [x, y, z] = t.block();
        STEPS.iter().all(|&i| {
            let p = [x + sx * i, y, z + sz * i];
            t.level.fluid(p) == FluidKind::Water
                && !self.blocks(t, p)
                && t.level.air([p[0], y + 1, p[2]])
                && t.level.air([p[0], y + 2, p[2]])
        })
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        let vy = t.velocity()[1];
        let pitch = t.pitch();
        (not_below(vy * vy, f(0.03))
            || pitch == 0.0
            || not_below(pitch.abs(), 10.0)
            || !t.in_water())
            && !t.on_ground()
    }

    fn interruptable(&self) -> bool {
        false
    }

    fn start(&mut self, t: &mut Turn) {
        let (sx, sz) = Jump::direction(t);
        let [vx, vy, vz] = t.velocity();
        t.mob.body.velocity = [vx + sx as f64 * 0.6, vy + 0.7, vz + sz as f64 * 0.6];
        self.breached = false;
        navigation::stop(t);
    }

    fn stop(&mut self, t: &mut Turn) {
        t.mob.body.pitch = 0.0;
    }

    fn tick(&mut self, t: &mut Turn) {
        let breached = self.breached || t.level.fluid(t.block()) == FluidKind::Water;
        if breached && !self.breached {
            t.play("minecraft:entity.dolphin.jump", 1.0, 1.0);
        }
        let [vx, vy, vz] = t.velocity();
        let pitch = t.pitch();
        if vy * vy < f(0.03) && pitch != 0.0 {
            t.mob.body.pitch = fmath::rot_lerp(f(0.2), pitch, 0.0);
        } else if (vx * vx + vy * vy + vz * vz).sqrt() > f(1.0e-5) {
            let h = (vx * vx + vz * vz).sqrt();
            t.mob.body.pitch = f((-vy).atan2(h) * 180.0 / f(std::f64::consts::PI));
        }
        self.breached = breached;
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Dolphin.Jump"
    }
}

/// `MoveToItemGoal` (`Dolphin.MoveToItem`): it swims to the first item it
/// may play with (with its play sound), and when done tosses what it
/// holds, waiting a while.
#[derive(Clone, Debug, PartialEq)]
pub struct MoveToItem {
    cooldown: i64,
}

fn swim_to(t: &mut Turn, item: &SensedItem) {
    let seen = Seen::of(Entity::Item(item));
    navigation::move_to_entity(t, &seen, f(1.2), 1);
}

impl Goal for MoveToItem {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if self.cooldown > t.mind.tick {
            return false;
        }
        !items(t).is_empty()
    }

    fn start(&mut self, t: &mut Turn) {
        if let Some(item) = items(t).first() {
            swim_to(t, item);
            t.play("minecraft:entity.dolphin.play", 1.0, 1.0);
        }
        self.cooldown = 0;
    }

    fn stop(&mut self, t: &mut Turn) {
        if toss(t) {
            let n = t.int(100);
            self.cooldown = t.mind.tick + n as i64;
        }
    }

    fn tick(&mut self, t: &mut Turn) {
        if let Some(item) = items(t).first() {
            swim_to(t, item);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Dolphin.MoveToItem"
    }
}

/// `PlayWithItemsGoal` (`Dolphin.PlayWithItems`): while it holds something,
/// it tosses it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PlayWithItems;

impl Goal for PlayWithItems {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        t.mob.body.mob.equipment.get(Slot::Mainhand).is_some()
    }

    fn stop(&mut self, t: &mut Turn) {
        toss(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        toss(t);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Dolphin.PlayWithItems"
    }
}
