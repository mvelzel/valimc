//! Vanilla's `Brain` (VMC-081d), ported from `Valimc.AI.Brain`: memories
//! with expiry, sensors with their scan rates, activities (a core set always
//! active and one other, chosen by the memories each requires) and
//! behaviours by priority, then activity, then order.
//!
//! `tick` is `Brain.tick`: memories age (one that has run out is cleared),
//! each sensor whose countdown ends scans, every stopped behaviour of an
//! active activity tries to start, and every running behaviour ticks or
//! stops. A behaviour (`behavior::Behavior`) is a boxed value holding its
//! own state, taken out of its slot while its callback runs as a goal is out
//! of its selector entry: what it leaves is put back at its index, in the
//! brain the mind holds then (a villager's remade brain included, as the
//! Elixir puts the returned behaviour into the brain it returns).
//!
//! Memories are typed (`Mem` names them, `MemValue` holds them); entities
//! are kept by reference and read through the section's sensing each tick,
//! as vanilla's memories hold live entities. What a brain family gives the
//! machinery (its brain, its activity choice, sounds, looting, reactions,
//! its own sensors and the tests its behaviours ask) is `BrainFamily`.
//!
//! The Elixir's closures over memories are data here: a behaviour's memory
//! conditions are `Conds`, a remote change of another brain's memories is
//! `Remember`, a family's change of another brain mob's state (`{:brain,
//! uuid, fun}`) is an opaque change its family applies.

pub mod behavior;
pub mod behaviors;
pub mod fight;
pub mod poi;
pub mod sensors;

use super::mind::MindState;
use super::paths::NavPath;
use super::turn::{Seen, Turn};
use super::Opaque;
use crate::mobs::facts::MobFacts;
use crate::mobs::model::FamilyData;
use crate::mobs::random::LegacyRandom;
use crate::mobs::sensing::{Kind as RefKind, Ref, SensedItem, Uuid};
use crate::mobs::term::{Atom, Map, Value, TRUE};
use behavior::Behavior;
use std::any::Any;
use std::collections::BTreeMap;

macro_rules! memories {
    ($($variant:ident => $name:literal),* $(,)?) => {
        /// A memory module type (`MemoryModuleType`), by its Elixir name.
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub enum Mem { $($variant),* }

        impl Mem {
            /// Every memory, in declaration order.
            pub const ALL: &'static [Mem] = &[$(Mem::$variant),*];

            /// The Elixir atom's name.
            pub fn name(self) -> &'static str {
                match self { $(Mem::$variant => $name),* }
            }

            /// The memory of an Elixir atom's name.
            pub fn of(name: &str) -> Option<Mem> {
                match name { $($name => Some(Mem::$variant),)* _ => None }
            }
        }
    };
}

memories! {
    LookTarget => "look_target",
    WalkTarget => "walk_target",
    Path => "path",
    CantReachWalkTargetSince => "cant_reach_walk_target_since",
    NearestLivingEntities => "nearest_living_entities",
    NearestVisibleLivingEntities => "nearest_visible_living_entities",
    NearestPlayers => "nearest_players",
    NearestVisiblePlayer => "nearest_visible_player",
    NearestVisibleAttackablePlayers => "nearest_visible_attackable_players",
    NearestVisibleAttackablePlayer => "nearest_visible_attackable_player",
    NearestVisibleWantedItem => "nearest_visible_wanted_item",
    ItemPickupCooldownTicks => "item_pickup_cooldown_ticks",
    HurtBy => "hurt_by",
    HurtByEntity => "hurt_by_entity",
    NearestVisibleAdult => "nearest_visible_adult",
    AttackTarget => "attack_target",
    AttackCoolingDown => "attack_cooling_down",
    InteractionTarget => "interaction_target",
    BreedTarget => "breed_target",
    IsPanicking => "is_panicking",
    Pacified => "pacified",
    AvoidTarget => "avoid_target",
    CelebrateLocation => "celebrate_location",
    Dancing => "dancing",
    AngryAt => "angry_at",
    UniversalAnger => "universal_anger",
    DoorsToClose => "doors_to_close",
    NearestRepellent => "nearest_repellent",
    NearestVisibleAdultPiglin => "nearest_visible_adult_piglin",
    NearestVisibleAdultPiglins => "nearest_visible_adult_piglins",
    NearestVisibleAdultHoglins => "nearest_visible_adult_hoglins",
    VisibleAdultPiglinCount => "visible_adult_piglin_count",
    VisibleAdultHoglinCount => "visible_adult_hoglin_count",
    NearbyAdultPiglins => "nearby_adult_piglins",
    HuntedRecently => "hunted_recently",
    NearestVisibleNemesis => "nearest_visible_nemesis",
    NearestVisibleZombified => "nearest_visible_zombified",
    NearestVisibleHuntableHoglin => "nearest_visible_huntable_hoglin",
    NearestVisibleBabyHoglin => "nearest_visible_baby_hoglin",
    NearestTargetablePlayerNotWearingGold => "nearest_targetable_player_not_wearing_gold",
    NearestPlayerHoldingWantedItem => "nearest_player_holding_wanted_item",
    AdmiringItem => "admiring_item",
    AdmiringDisabled => "admiring_disabled",
    DisableWalkToAdmireItem => "disable_walk_to_admire_item",
    TimeTryingToReachAdmireItem => "time_trying_to_reach_admire_item",
    RideTarget => "ride_target",
    PlayDeadTicks => "play_dead_ticks",
    TemptationCooldownTicks => "temptation_cooldown_ticks",
    TemptingPlayer => "tempting_player",
    HasHuntingCooldown => "has_hunting_cooldown",
    NearestAttackable => "nearest_attackable",
    Home => "home",
    JobSite => "job_site",
    PotentialJobSite => "potential_job_site",
    MeetingPoint => "meeting_point",
    SecondaryJobSite => "secondary_job_site",
    LastSlept => "last_slept",
    LastWoken => "last_woken",
    LastWorkedAtPoi => "last_worked_at_poi",
    GolemDetectedRecently => "golem_detected_recently",
    HeardBellTime => "heard_bell_time",
    NearestBed => "nearest_bed",
    NearestHostile => "nearest_hostile",
    VisibleVillagerBabies => "visible_villager_babies",
    LastGossip => "last_gossip",
    BedCache => "__bed_cache",
}

/// A memory's condition in a behaviour's entry (`MemoryStatus`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cond {
    Present,
    Absent,
    Registered,
}

/// A behaviour's memory conditions (`[{name, status}]`), held inline.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Conds {
    items: [(Mem, Cond); 8],
    len: u8,
}

impl Conds {
    /// The conditions of `list` (at most eight).
    pub const fn new(list: &[(Mem, Cond)]) -> Conds {
        let mut items = [(Mem::LookTarget, Cond::Registered); 8];
        let mut i = 0;
        while i < list.len() {
            items[i] = list[i];
            i += 1;
        }
        Conds {
            items,
            len: list.len() as u8,
        }
    }

    /// None.
    pub const NONE: Conds = Conds::new(&[]);

    pub fn list(&self) -> &[(Mem, Cond)] {
        &self.items[..self.len as usize]
    }

    /// `Brain.conditions?/2`.
    pub fn hold(&self, memories: &Memories) -> bool {
        self.list().iter().all(|&(m, c)| match c {
            Cond::Present => memories.has(m),
            Cond::Absent => !memories.has(m),
            Cond::Registered => true,
        })
    }
}

/// `PositionTracker`: an entity (its eyes when `eye`; an item's also where
/// it lay, `at`, as vanilla's tracker keeps a removed item's last place) or
/// a block and its center.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Tracker {
    Entity {
        target: Ref,
        eye: bool,
        at: Option<[f64; 3]>,
    },
    Block {
        block: [i32; 3],
        center: [f64; 3],
    },
}

impl Tracker {
    /// `{:entity, ref, eye}`.
    pub fn entity(target: Ref, eye: bool) -> Tracker {
        Tracker::Entity {
            target,
            eye,
            at: None,
        }
    }

    /// A block's tracker, its center the block's middle.
    pub fn block(block: [i32; 3]) -> Tracker {
        Tracker::Block {
            block,
            center: [
                block[0] as f64 + 0.5,
                block[1] as f64 + 0.5,
                block[2] as f64 + 0.5,
            ],
        }
    }

    /// `Behaviors.point/1`: the block holding a point.
    pub fn point(p: [f64; 3]) -> Tracker {
        Tracker::block(super::fmath::block(p))
    }
}

/// `WalkTarget`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WalkTarget {
    pub target: Tracker,
    pub speed: f64,
    pub close: i32,
}

/// `NearestVisibleLivingEntities`: the living entities a scan saw, nearest
/// first, and the sight of each tested since (`seen`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Visible {
    pub entities: Vec<Ref>,
    pub seen: Vec<(Ref, bool)>,
}

/// `GlobalPos`: a block of a dimension.
#[derive(Clone, Debug, PartialEq)]
pub struct Global {
    pub dimension: Atom,
    pub pos: [i32; 3],
}

/// A memory's value.
#[derive(Clone, Debug, PartialEq)]
pub enum MemValue {
    True,
    Int(i64),
    Ref(Ref),
    Refs(Vec<Ref>),
    Visible(Box<Visible>),
    Tracker(Tracker),
    Walk(WalkTarget),
    Path(Box<NavPath>),
    Pos([i32; 3]),
    Global(Global),
    Globals(Vec<Global>),
    /// The damage type's registry id (`hurt_by`).
    Damage(u16),
    /// A villager baby's bed search cache: `pos => until`.
    Cache(Vec<([i32; 3], i64)>),
}

impl MemValue {
    /// `Brain.set/3`'s erasing values: an empty list.
    fn erases(&self) -> bool {
        matches!(self, MemValue::Refs(l) if l.is_empty())
            || matches!(self, MemValue::Globals(l) if l.is_empty())
    }
}

/// A memory's slot: its value and the ticks it has left (None: never runs
/// out).
pub type Slot = (MemValue, Option<i64>);

/// A brain's memories.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Memories(pub BTreeMap<Mem, Slot>);

impl Memories {
    pub fn get(&self, m: Mem) -> Option<&MemValue> {
        self.0.get(&m).map(|(v, _)| v)
    }

    pub fn has(&self, m: Mem) -> bool {
        self.0.contains_key(&m)
    }

    /// `Brain.ttl/2`: None without a value, `Some(None)` for one that never
    /// runs out.
    pub fn ttl(&self, m: Mem) -> Option<Option<i64>> {
        self.0.get(&m).map(|(_, t)| *t)
    }

    /// `Brain.set/4` (an empty list erases).
    pub fn set(&mut self, m: Mem, value: MemValue, ttl: Option<i64>) {
        if value.erases() {
            self.0.remove(&m);
        } else {
            self.0.insert(m, (value, ttl));
        }
    }

    pub fn erase(&mut self, m: Mem) {
        self.0.remove(&m);
    }

    /// `MemorySlot.tick`: a memory that has run out is cleared, else counts
    /// down.
    fn forget(&mut self) {
        self.0.retain(|_, (_, ttl)| ttl.is_none_or(|t| t > 0));
        for (_, ttl) in self.0.values_mut() {
            if let Some(t) = ttl {
                *t -= 1;
            }
        }
    }

    pub fn reference(&self, m: Mem) -> Option<Ref> {
        match self.get(m) {
            Some(MemValue::Ref(r)) => Some(*r),
            _ => None,
        }
    }

    pub fn int(&self, m: Mem) -> Option<i64> {
        match self.get(m) {
            Some(MemValue::Int(n)) => Some(*n),
            _ => None,
        }
    }

    pub fn global(&self, m: Mem) -> Option<&Global> {
        match self.get(m) {
            Some(MemValue::Global(g)) => Some(g),
            _ => None,
        }
    }
}

/// An activity (`Activity`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Activity {
    Core,
    Idle,
    Work,
    Play,
    Meet,
    Rest,
    Panic,
    Fight,
    Avoid,
    AdmireItem,
    Celebrate,
    Ride,
    PlayDead,
}

impl Activity {
    /// The Elixir atom's name.
    pub fn name(self) -> &'static str {
        match self {
            Activity::Core => "core",
            Activity::Idle => "idle",
            Activity::Work => "work",
            Activity::Play => "play",
            Activity::Meet => "meet",
            Activity::Rest => "rest",
            Activity::Panic => "panic",
            Activity::Fight => "fight",
            Activity::Avoid => "avoid",
            Activity::AdmireItem => "admire_item",
            Activity::Celebrate => "celebrate",
            Activity::Ride => "ride",
            Activity::PlayDead => "play_dead",
        }
    }

    /// The activity of a schedule's name.
    pub fn of(name: &str) -> Option<Activity> {
        Some(match name {
            "core" => Activity::Core,
            "idle" => Activity::Idle,
            "work" => Activity::Work,
            "play" => Activity::Play,
            "meet" => Activity::Meet,
            "rest" => Activity::Rest,
            "panic" => Activity::Panic,
            "fight" => Activity::Fight,
            "avoid" => Activity::Avoid,
            "admire_item" => Activity::AdmireItem,
            "celebrate" => Activity::Celebrate,
            "ride" => Activity::Ride,
            "play_dead" => Activity::PlayDead,
            _ => return None,
        })
    }
}

/// A sensor (`Sensor`): the shared ones, or a family's own (`Family(tag)`,
/// which its `BrainFamily::scan` runs).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sensor {
    NearestLiving,
    Players,
    Items,
    HurtBy,
    NearestAdult,
    Family(u32),
}

/// A sensor with its scan rate and countdown.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SensorSlot {
    pub sensor: Sensor,
    pub scan: i32,
    pub time: i32,
}

/// An activity: the memories it requires and those it erases when another
/// replaces it.
#[derive(Clone, Debug, PartialEq)]
pub struct Rule {
    pub name: Activity,
    pub requirements: Conds,
    pub erase: &'static [Mem],
}

/// A behaviour in the brain's order.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub activity: Activity,
    pub priority: i32,
    /// None only while its own callback runs.
    pub behavior: Option<Box<dyn Behavior>>,
}

/// An activity as a family builds it: its behaviours by priority, its
/// requirements and what it erases.
pub struct Package {
    pub name: Activity,
    pub behaviors: Vec<(i32, Box<dyn Behavior>)>,
    pub requirements: Conds,
    pub erase: &'static [Mem],
}

impl Package {
    /// `{activity, first, [behavior], requirements, erase}`: each behaviour
    /// at the next priority from `first`.
    pub fn from(
        name: Activity,
        first: i32,
        behaviors: Vec<Box<dyn Behavior>>,
        requirements: Conds,
        erase: &'static [Mem],
    ) -> Package {
        Package {
            name,
            behaviors: behaviors
                .into_iter()
                .enumerate()
                .map(|(i, b)| (first + i as i32, b))
                .collect(),
            requirements,
            erase,
        }
    }

    /// `{activity, :each, [{priority, behavior}], requirements, erase}`.
    pub fn each(
        name: Activity,
        behaviors: Vec<(i32, Box<dyn Behavior>)>,
        requirements: Conds,
        erase: &'static [Mem],
    ) -> Package {
        Package {
            name,
            behaviors,
            requirements,
            erase,
        }
    }
}

/// A mob's brain.
#[derive(Clone, Debug, PartialEq)]
pub struct Brain {
    pub memories: Memories,
    pub sensors: Vec<SensorSlot>,
    pub activities: Vec<Rule>,
    pub behaviors: Vec<Entry>,
    pub active: Vec<Activity>,
    pub default: Activity,
    pub schedule_update: i64,
    /// The memories a record saves (`saved/0`; None: the record keeps no
    /// memories).
    pub saved: Option<&'static [Mem]>,
    /// The memories other brain mobs read of it.
    pub shared: &'static [Mem],
}

impl Brain {
    /// `Brain.new/5`: `sensors` (`(sensor, scan rate)`, their countdowns
    /// drawn from `random` as `Sensor.randomlyDelayStart` does) and
    /// `activities`; behaviours of one priority run by activity in
    /// `activities`' order, then in their activity's order. It starts in its
    /// default activity, idle.
    pub fn new(
        sensors: &[(Sensor, i32)],
        activities: Vec<Package>,
        random: &mut LegacyRandom,
        saved: Option<&'static [Mem]>,
        shared: &'static [Mem],
    ) -> Brain {
        let sensors = sensors
            .iter()
            .map(|&(sensor, scan)| SensorSlot {
                sensor,
                scan,
                time: random.int(scan),
            })
            .collect();
        let mut keyed = Vec::new();
        let mut rules = Vec::new();
        for (a, package) in activities.into_iter().enumerate() {
            rules.push(Rule {
                name: package.name,
                requirements: package.requirements,
                erase: package.erase,
            });
            for (i, (priority, behavior)) in package.behaviors.into_iter().enumerate() {
                keyed.push((
                    (priority, a, i),
                    Entry {
                        activity: package.name,
                        priority,
                        behavior: Some(behavior),
                    },
                ));
            }
        }
        keyed.sort_by_key(|(k, _)| *k);
        let mut brain = Brain {
            memories: Memories::default(),
            sensors,
            activities: rules,
            behaviors: keyed.into_iter().map(|(_, e)| e).collect(),
            active: vec![Activity::Core],
            default: Activity::Idle,
            schedule_update: -9999,
            saved,
            shared,
        };
        brain.activate(Activity::Idle);
        brain
    }

    /// `setActiveActivity`: a newly active activity erases what the others
    /// it replaces erase when they stop.
    pub fn activate(&mut self, activity: Activity) {
        if self.active.contains(&activity) {
            return;
        }
        for old in self.active.clone() {
            if old == activity {
                continue;
            }
            for rule in self.activities.iter().filter(|r| r.name == old) {
                for &m in rule.erase {
                    self.memories.erase(m);
                }
            }
        }
        self.active = vec![Activity::Core, activity];
    }

    fn requirements_met(&self, activity: Activity) -> bool {
        self.activities
            .iter()
            .find(|r| r.name == activity)
            .is_some_and(|r| r.requirements.hold(&self.memories))
    }

    /// `getActiveNonCoreActivity`.
    pub fn activity(&self) -> Option<Activity> {
        self.active.iter().copied().find(|&a| a != Activity::Core)
    }

    /// The running behaviours as `priority:activity`, in tick order
    /// (`Brain.running/1`).
    pub fn running(&self) -> Vec<String> {
        self.behaviors
            .iter()
            .filter(|e| e.behavior.as_ref().is_some_and(|b| b.running()))
            .map(|e| format!("{}:{}", e.priority, e.activity.name()))
            .collect()
    }

    /// The memories of `saved` as a record keeps them (`Mind.record/1`):
    /// `%{name => {value, ttl}}`.
    pub fn saved_record(&self, facts: Option<&MobFacts>) -> Option<Value> {
        let saved = self.saved?;
        let pairs = self
            .memories
            .0
            .iter()
            .filter(|(m, _)| saved.contains(m))
            .map(|(m, slot)| (Value::Atom(Atom::new(m.name())), slot_value(slot, facts)))
            .collect();
        Some(Value::Map(Map::from_pairs(pairs).unwrap_or_default()))
    }
}

// ## Values as terms

fn kind_atom(kind: RefKind) -> Value {
    Value::atom(match kind {
        RefKind::Player => "player",
        RefKind::Mob => "mob",
        RefKind::Item => "item",
    })
}

/// A reference as `World.ref/1` writes it (`{kind, uuid}`).
pub fn ref_value(r: &Ref) -> Value {
    Value::tuple([kind_atom(r.kind), Value::Binary(r.uuid.to_vec())])
}

fn ivec(p: [i32; 3]) -> Value {
    Value::ivec3([p[0] as i64, p[1] as i64, p[2] as i64])
}

fn tracker_value(t: &Tracker) -> Value {
    match t {
        Tracker::Entity {
            target,
            eye,
            at: None,
        } => Value::tuple([Value::atom("entity"), ref_value(target), Value::bool(*eye)]),
        Tracker::Entity {
            target,
            eye,
            at: Some(at),
        } => Value::tuple([
            Value::atom("entity"),
            ref_value(target),
            Value::bool(*eye),
            Value::vec3(*at),
        ]),
        Tracker::Block { block, center } => {
            Value::tuple([Value::atom("block"), ivec(*block), Value::vec3(*center)])
        }
    }
}

fn global_value(g: &Global) -> Value {
    Value::tuple([Value::Atom(g.dimension.clone()), ivec(g.pos)])
}

/// A memory's value as the Elixir's term (a path as `{:path, index,
/// nodes}`, a damage type as its unprefixed atom where `facts` name it).
pub fn value(v: &MemValue, facts: Option<&MobFacts>) -> Value {
    match v {
        MemValue::True => TRUE,
        MemValue::Int(n) => Value::Int(*n),
        MemValue::Ref(r) => ref_value(r),
        MemValue::Refs(l) => Value::List(l.iter().map(ref_value).collect()),
        MemValue::Visible(v) => {
            let seen = v
                .seen
                .iter()
                .map(|(r, s)| (ref_value(r), Value::bool(*s)))
                .collect();
            Value::Map(Map::from_atoms([
                (
                    "entities",
                    Value::List(v.entities.iter().map(ref_value).collect()),
                ),
                (
                    "seen",
                    Value::Map(Map::from_pairs(seen).unwrap_or_default()),
                ),
            ]))
        }
        MemValue::Tracker(t) => tracker_value(t),
        MemValue::Walk(w) => Value::Map(Map::from_atoms([
            ("target", tracker_value(&w.target)),
            ("speed", Value::Float(w.speed)),
            ("close", Value::Int(w.close as i64)),
        ])),
        MemValue::Path(p) => Value::tuple([
            Value::atom("path"),
            Value::Int(p.index as i64),
            Value::List(p.nodes.iter().map(|n| ivec(*n)).collect()),
        ]),
        MemValue::Pos(p) => ivec(*p),
        MemValue::Global(g) => global_value(g),
        MemValue::Globals(l) => Value::List(l.iter().map(global_value).collect()),
        MemValue::Damage(id) => {
            let name = facts
                .and_then(|f| f.damage_types.types.get(*id as usize))
                .map(|d| {
                    d.name
                        .strip_prefix("minecraft:")
                        .unwrap_or(&d.name)
                        .to_owned()
                });
            match name {
                Some(n) => Value::Atom(Atom::new(&n)),
                None => Value::Int(*id as i64),
            }
        }
        MemValue::Cache(l) => Value::Map(
            Map::from_pairs(l.iter().map(|(p, t)| (ivec(*p), Value::Int(*t))).collect())
                .unwrap_or_default(),
        ),
    }
}

/// `{value, ttl}` (`:never` for one that never runs out).
pub fn slot_value((v, ttl): &Slot, facts: Option<&MobFacts>) -> Value {
    Value::tuple([
        value(v, facts),
        match ttl {
            None => Value::atom("never"),
            Some(t) => Value::Int(*t),
        },
    ])
}

/// A saved memory's value from a record's term: a flag, a time or a
/// `GlobalPos` (what `saved/0` keeps); None for anything else.
fn saved_value(v: &Value) -> Option<MemValue> {
    match v {
        Value::Atom(a) if a.as_str() == "true" => Some(MemValue::True),
        Value::Int(n) => Some(MemValue::Int(*n)),
        Value::Tuple(items) => match items.as_slice() {
            [Value::Atom(dimension), pos] => {
                let p = pos.as_ivec3()?;
                Some(MemValue::Global(Global {
                    dimension: dimension.clone(),
                    pos: [p[0] as i32, p[1] as i32, p[2] as i32],
                }))
            }
            _ => None,
        },
        _ => None,
    }
}

/// The memories a record kept (`%{name => {value, ttl}}`), as a fresh brain
/// gets them back.
pub fn restore_memories(kept: &Value) -> Memories {
    let mut memories = Memories::default();
    let Some(map) = kept.as_map() else {
        return memories;
    };
    for (k, v) in map.iter() {
        let Some(m) = k.as_atom().and_then(|a| Mem::of(a.as_str())) else {
            continue;
        };
        let Some([value, ttl]) = v.as_tuple_n::<2>() else {
            continue;
        };
        let ttl = match ttl {
            Value::Int(t) => Some(*t),
            _ => None,
        };
        if let Some(value) = saved_value(value) {
            memories.0.insert(m, (value, ttl));
        }
    }
    memories
}

// ## Its family

/// What a brain mob reacts to before its section thinks: a hurt by an
/// entity since it last thought (`{:hurt_by, ref}`) and what players did
/// (`{:anger, player, seen}`: opening or breaking what piglins guard).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reaction {
    HurtBy(Ref),
    Anger { player: Ref, seen: bool },
}

/// What a brain family gives the machinery (`Valimc.AI.Brains.*`'s module
/// callbacks): its brain, its activity choice after the brain's tick, its
/// ambient sound, its part after the move, what it wants to pick up, its
/// reactions, its own sensors, and the tests, finders and speeds its
/// behaviours take by tag (the Elixir's closures).
pub trait BrainFamily: Send + Sync {
    fn as_any(&self) -> &dyn Any;

    /// `brain/2,3`: a fresh brain of a mob of `uuid` with `data`, its
    /// sensors' countdowns drawn from `random`.
    fn brain(
        &self,
        facts: &MobFacts,
        uuid: &Uuid,
        data: &FamilyData,
        random: &mut LegacyRandom,
    ) -> Brain;

    /// `started/1`: its constructor's part once made in a world.
    fn started(&self, _t: &mut Turn) {}

    /// `update_activity/1`: after the brain's tick.
    fn update_activity(&self, t: &mut Turn);

    /// `ambient_sound/1`: the sound its timer plays (an id), or none.
    fn ambient_sound(&self, t: &mut Turn) -> Option<i32>;

    /// `pick_up/1`: its part after the move (looting, ageing).
    fn pick_up(&self, _t: &mut Turn) {}

    /// `wants?/2` of a sensed item (`NearestItemSensor`).
    fn wants(&self, _t: &Turn, _item: &SensedItem) -> bool {
        false
    }

    /// Whether it reacts before its section thinks (`react/2` exported).
    fn reacts(&self) -> bool {
        false
    }

    /// `react/2`.
    fn react(&self, _t: &mut Turn, _event: Reaction) {}

    /// A change of its family another brain mob asked of this one
    /// (`{:brain, uuid, fun}`).
    fn brain_change(&self, _t: &mut Turn, _change: &dyn Opaque) {}

    /// Its own sensor `tag`.
    fn scan(&self, _t: &mut Turn, _tag: u32) {}

    /// A test of the mob (`fn self -> bool`).
    fn test(&self, _t: &mut Turn, _tag: u32) -> bool {
        false
    }

    /// A test of a sensed entity.
    fn select(
        &self,
        _t: &Turn,
        _tag: u32,
        _e: crate::mobs::sensing::Entity<'_, super::Extra>,
    ) -> bool {
        false
    }

    /// A finder (`fn self -> {entity | nil, self}`).
    fn find(&self, _t: &mut Turn, _tag: u32) -> Option<Seen> {
        None
    }

    /// A speed of the mob's state.
    fn speed(&self, _t: &Turn, _tag: u32) -> f64 {
        0.0
    }

    /// A stop test of a target (`fn self, target -> {stop, self}`).
    fn stop_when(&self, _t: &mut Turn, _tag: u32, _target: &Seen) -> bool {
        false
    }

    /// An attack target's end (`fn self, target -> self`).
    fn on_stop(&self, _t: &mut Turn, _tag: u32, _target: Option<&Seen>) {}

    /// A celebration's dance (`fn self, target -> {dances, self}`).
    fn dance(&self, _t: &mut Turn, _target: &Seen) -> bool {
        false
    }

    /// `young?/1` as the shared behaviours read it.
    fn young(&self, _t: &Turn) -> bool {
        false
    }
}

// ## The mob's brain in its turn

impl<'w> Turn<'_, 'w> {
    /// The mind's brain.
    pub fn brain(&self) -> Option<&Brain> {
        self.mind.brain.as_deref()
    }

    pub fn brain_mut(&mut self) -> Option<&mut Brain> {
        self.mind.brain.as_deref_mut()
    }

    /// The family's brain (`Hooks::brain`).
    pub fn family(&self) -> Option<&'w dyn BrainFamily> {
        let hooks: &'w dyn super::hooks::Hooks = self.hooks;
        hooks.brain()
    }

    /// `Brain.get/2`.
    pub fn memory(&self, m: Mem) -> Option<&MemValue> {
        self.brain()?.memories.get(m)
    }

    /// `Brain.has?/2`.
    pub fn has(&self, m: Mem) -> bool {
        self.brain().is_some_and(|b| b.memories.has(m))
    }

    /// `Brain.ttl/2`.
    pub fn ttl(&self, m: Mem) -> Option<Option<i64>> {
        self.brain()?.memories.ttl(m)
    }

    /// `Brain.set/3`.
    pub fn remember(&mut self, m: Mem, value: MemValue) {
        if let Some(b) = self.brain_mut() {
            b.memories.set(m, value, None);
        }
    }

    /// `Brain.set/4`.
    pub fn remember_for(&mut self, m: Mem, value: MemValue, ttl: i64) {
        if let Some(b) = self.brain_mut() {
            b.memories.set(m, value, Some(ttl));
        }
    }

    /// `Brain.set/3` of a value that may be nil (which erases).
    pub fn remember_opt(&mut self, m: Mem, value: Option<MemValue>) {
        match value {
            Some(v) => self.remember(m, v),
            None => self.forget(m),
        }
    }

    /// `Brain.erase/2`.
    pub fn forget(&mut self, m: Mem) {
        if let Some(b) = self.brain_mut() {
            b.memories.erase(m);
        }
    }

    pub fn mem_ref(&self, m: Mem) -> Option<Ref> {
        self.brain()?.memories.reference(m)
    }

    pub fn mem_int(&self, m: Mem) -> Option<i64> {
        self.brain()?.memories.int(m)
    }

    pub fn mem_pos(&self, m: Mem) -> Option<[i32; 3]> {
        match self.memory(m) {
            Some(MemValue::Pos(p)) => Some(*p),
            _ => None,
        }
    }

    pub fn mem_global(&self, m: Mem) -> Option<Global> {
        self.brain()?.memories.global(m).cloned()
    }

    pub fn mem_refs(&self, m: Mem) -> Vec<Ref> {
        match self.memory(m) {
            Some(MemValue::Refs(l)) => l.clone(),
            _ => Vec::new(),
        }
    }

    pub fn mem_walk(&self) -> Option<WalkTarget> {
        match self.memory(Mem::WalkTarget) {
            Some(MemValue::Walk(w)) => Some(*w),
            _ => None,
        }
    }

    pub fn mem_tracker(&self, m: Mem) -> Option<Tracker> {
        match self.memory(m) {
            Some(MemValue::Tracker(t)) => Some(*t),
            _ => None,
        }
    }

    /// The sensed entity a memory refers to (`World.entity(world,
    /// Brain.get(self, m))`).
    pub fn remembered(&self, m: Mem) -> Option<Seen> {
        let r = self.mem_ref(m)?;
        self.entity(Some(&r))
    }

    /// `Brain.conditions?/2`.
    pub fn conditions(&self, conds: &Conds) -> bool {
        match self.brain() {
            Some(b) => conds.hold(&b.memories),
            None => conds
                .list()
                .iter()
                .all(|&(_, c)| matches!(c, Cond::Absent | Cond::Registered)),
        }
    }

    // ### Activities

    /// `Brain.active?/2`.
    pub fn active(&self, a: Activity) -> bool {
        self.brain().is_some_and(|b| b.active.contains(&a))
    }

    /// `Brain.activity/1`.
    pub fn activity(&self) -> Option<Activity> {
        self.brain()?.activity()
    }

    /// `setActiveActivityIfPossible`: the activity when its requirements
    /// hold, else the default.
    pub fn set_active_if_possible(&mut self, a: Activity) {
        if let Some(b) = self.brain_mut() {
            let to = if b.requirements_met(a) { a } else { b.default };
            b.activate(to);
        }
    }

    /// `setDefaultActivity`.
    pub fn set_default_activity(&mut self, a: Activity) {
        if let Some(b) = self.brain_mut() {
            b.default = a;
        }
    }

    /// `useDefaultActivity`.
    pub fn default_activity(&mut self) {
        if let Some(b) = self.brain_mut() {
            let d = b.default;
            b.activate(d);
        }
    }

    /// `setActiveActivityToFirstValid`.
    pub fn first_valid(&mut self, activities: &[Activity]) {
        if let Some(b) = self.brain_mut() {
            if let Some(&a) = activities.iter().find(|&&a| b.requirements_met(a)) {
                b.activate(a);
            }
        }
    }

    /// `updateActivityFromSchedule`: at most once in 20 ticks, the
    /// scheduled activity when it is not active.
    pub fn update_from_schedule(&mut self, scheduled: Activity) {
        let time = self.level.time;
        let Some(b) = self.brain_mut() else { return };
        if time - b.schedule_update > 20 {
            b.schedule_update = time;
            if !b.active.contains(&scheduled) {
                self.set_active_if_possible(scheduled);
            }
        }
    }

    // ### The level's random

    /// `level.getRandom().nextInt(bound)` (`Behavior.level_int/2`).
    pub fn level_int(&mut self, bound: i32) -> i32 {
        self.level.random.int(bound)
    }

    /// `level.getRandom().nextFloat()`.
    pub fn level_float(&mut self) -> f64 {
        self.level.random.float() as f64
    }
}

// ## Ticking

/// `Brain.tick`: memories age, sensors scan, stopped behaviours of active
/// activities try to start, running ones tick or stop.
pub fn tick(t: &mut Turn, family: &dyn BrainFamily) {
    let Some(b) = t.brain_mut() else { return };
    b.memories.forget();
    let count = b.sensors.len();
    for index in 0..count {
        let Some(slot) = t.brain_mut().and_then(|b| b.sensors.get_mut(index)) else {
            break;
        };
        let time = slot.time - 1;
        if time <= 0 {
            slot.time = slot.scan;
            let sensor = slot.sensor;
            sensors::scan(t, family, sensor);
        } else {
            slot.time = time;
        }
    }
    start_stopped(t);
    tick_running(t);
}

/// Runs `f` on behaviour `index`, taken out of its slot meanwhile; what it
/// leaves goes back to that index of the brain the mind holds then.
fn with_behavior<R>(
    t: &mut Turn,
    index: usize,
    f: impl FnOnce(&mut dyn Behavior, &mut Turn) -> R,
) -> Option<R> {
    let mut b = t
        .brain_mut()?
        .behaviors
        .get_mut(index)
        .and_then(|e| e.behavior.take())?;
    let result = f(&mut *b, t);
    if let Some(e) = t
        .brain_mut()
        .and_then(|brain| brain.behaviors.get_mut(index))
    {
        e.behavior = Some(b);
    }
    Some(result)
}

fn start_stopped(t: &mut Turn) {
    let count = t.brain().map_or(0, |b| b.behaviors.len());
    for index in 0..count {
        let Some((running, activity)) = t
            .brain()
            .and_then(|b| b.behaviors.get(index))
            .and_then(|e| Some((e.behavior.as_ref()?.running(), e.activity)))
        else {
            continue;
        };
        if !running && t.active(activity) {
            with_behavior(t, index, |b, t| b.try_start(t));
        }
    }
}

fn tick_running(t: &mut Turn) {
    let count = t.brain().map_or(0, |b| b.behaviors.len());
    for index in 0..count {
        let running = t
            .brain()
            .and_then(|b| b.behaviors.get(index))
            .and_then(|e| e.behavior.as_ref())
            .is_some_and(|b| b.running());
        if running {
            with_behavior(t, index, |b, t| b.tick_or_stop(t));
        }
    }
}

/// `stop_all`: every running behaviour stops (`Villager.refreshBrain`).
pub fn stop_all(t: &mut Turn) {
    let count = t.brain().map_or(0, |b| b.behaviors.len());
    for index in 0..count {
        let running = t
            .brain()
            .and_then(|b| b.behaviors.get(index))
            .and_then(|e| e.behavior.as_ref())
            .is_some_and(|b| b.running());
        if running {
            with_behavior(t, index, |b, t| b.stop(t));
        }
    }
}

// ## Changes to another brain

/// A change of another brain mob's memories (`{:remote, uuid, fun}` of
/// `Brain.set`s and erases): each memory set (with its ttl) or erased, in
/// order.
#[derive(Clone, Debug, PartialEq)]
pub struct Remember(pub Vec<(Mem, Option<Slot>)>);

impl Remember {
    pub fn set(m: Mem, value: MemValue) -> Remember {
        Remember(vec![(m, Some((value, None)))])
    }

    pub fn erase(m: Mem) -> Remember {
        Remember(vec![(m, None)])
    }

    /// The change on a mind (one without a brain keeps it unchanged).
    pub fn apply(&self, mind: &mut MindState) {
        let Some(b) = mind.brain.as_deref_mut() else {
            return;
        };
        for (m, slot) in &self.0 {
            match slot {
                Some((v, ttl)) => b.memories.set(*m, v.clone(), *ttl),
                None => b.memories.erase(*m),
            }
        }
    }
}

/// What others sense of a brain mob's memories (`AI.sensed/1`'s
/// `memories`): those its family shares, as the Elixir's term map
/// (`%{name => {value, ttl}}`); None where it shares none.
pub fn shared_value(brain: &Brain) -> Option<Value> {
    if brain.shared.is_empty() {
        return None;
    }
    let pairs = brain
        .memories
        .0
        .iter()
        .filter(|(m, _)| brain.shared.contains(m))
        .map(|(m, slot)| (Value::Atom(Atom::new(m.name())), slot_value(slot, None)))
        .collect();
    Some(Value::Map(Map::from_pairs(pairs).unwrap_or_default()))
}

/// A memory of a sensed brain mob (`v.memories[name]`): its value's term.
pub fn sensed_memory(memories: Option<&Value>, m: Mem) -> Option<&Value> {
    let [value, _] = memories?.as_map()?.get_atom(m.name())?.as_tuple_n::<2>()?;
    Some(value)
}

/// `{x, y, z}` of a mob reference's uuid for a brain change's own reference
/// (`{:mob, uuid}`).
pub fn mob_ref(uuid: Uuid) -> Ref {
    Ref {
        kind: RefKind::Mob,
        uuid,
    }
}
