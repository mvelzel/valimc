//! A native mob's state (VMC-081d), field for field what the Elixir holds:
//! the store entry's uuid, position and hops (`NativeMob`), the body
//! (`Valimc.Entity.Body`), its living part (`Valimc.Entity.Mob`), the
//! `LivingEntity` state (`Valimc.Living` and `Valimc.Living.Health` /
//! `Freezing`), the travel state (`Valimc.Entity.MobMotion`) and the mind
//! (`Valimc.AI.Mind`: its saved random and brain memories, plus the live
//! `MindState` the AI keeps between ticks). Names follow the Elixir fields.
//!
//! Numbers keep the Elixir representation: every float is an `f64` holding
//! the exact bits the Elixir term holds (often an `f32` value widened; the
//! rules round as Java does), so a record writes back what it read. Integers
//! that vanilla holds in a Java `int` are `i32`. Items (`%ItemStack{}`), a
//! custom name's text component, a death's pending drops and brain memories
//! are terms the core does not interpret: `Value`s.
//!
//! Family data (`Body.data`, atom-keyed, its key set fixed by type and
//! checked on restore) is a `FamilyData`: the type's fields in key order as
//! `(Atom, Value)` pairs, so any family's data is held exactly whatever its
//! fields, with O(1) typed access to the fields many families share and
//! hot paths read (an `AgeableMob`'s `age`, `forced_age`, `age_locked`,
//! `in_love`, `love_cause`; a zombie or piglin's `baby`) through slot
//! indices resolved once when the data is made. A family that moves native
//! reads its own fields by name (`get`/`set`); the key set never changes
//! after construction, as `Body.restore` requires.

use super::random::LegacyRandom;
use super::term::{Atom, Value};

/// A mob in a native section: the store entry (`%{entity: %{uuid, x, y,
/// z}, body, hops}`) of a living body.
#[derive(Clone, Debug, PartialEq)]
pub struct NativeMob {
    pub uuid: [u8; 16],
    /// The entry's `x`, `y`, `z`.
    pub position: [f64; 3],
    /// The handoffs it made (`Store` entry `hops`).
    pub hops: u64,
    pub body: Body,
}

/// `Valimc.Entity.Body` of a mob.
#[derive(Clone, Debug, PartialEq)]
pub struct Body {
    /// The entity type's id, e.g. `"minecraft:cow"` (`type`).
    pub entity_type: String,
    pub yaw: f64,
    pub pitch: f64,
    pub head_yaw: f64,
    pub velocity: [f64; 3],
    pub on_ground: bool,
    pub no_gravity: bool,
    pub data: FamilyData,
    pub mob: Mob,
    /// A name tag's text component; Elixir truthiness decides whether a
    /// record has it.
    pub custom_name: Option<Value>,
    /// What generation gave it, as SNBT.
    pub preserved: Option<Vec<u8>>,
    /// `portalCooldown`, 0..=32767.
    pub portal_cooldown: i32,
}

/// `Valimc.Entity.Mob`: the `LivingEntity` and `Mob` state of a body.
#[derive(Clone, Debug, PartialEq)]
pub struct Mob {
    pub living: Living,
    pub equipment: Equipment,
    /// Attribute overrides over the type's defaults, by attribute id.
    pub attributes: Attributes,
    /// `ai`: nil until the mob first thinks or a record restores its random.
    pub ai: Option<Mind>,
    /// `NoAI`.
    pub no_ai: bool,
    pub motion: MobMotion,
    /// `lastHurtByPlayer` (a player uuid) while `player_memory` lasts.
    pub hurt_by_player: Option<[u8; 16]>,
    /// Ticks left of `hurt_by_player`, 0..=100.
    pub player_memory: i32,
    /// The uuid of the last living entity that hurt it (not saved).
    pub hurt_by: Option<[u8; 16]>,
    /// What a death the owner has not dropped yet leaves (not saved).
    pub death: Option<Value>,
    /// `PersistenceRequired`.
    pub persistent: bool,
    pub left_handed: bool,
    pub can_pick_up_loot: bool,
    /// Equipment drop chances by slot where not the default.
    pub drop_chances: DropChances,
    /// The spawn reason (`:natural`, `:spawner`, ...) whose `finalizeSpawn`
    /// is still to run.
    pub finalize: Option<Atom>,
    pub leash: Option<Leash>,
    /// `Mob.setHomeTo`'s `{{x, y, z}, radius}`.
    pub home: Option<Home>,
    /// The item it is using (`useItem`).
    pub using: Option<Using>,
}

/// `EquipmentSlot`, in the equipment packet's numbering (`Mob.slots/0`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Slot {
    Mainhand = 0,
    Offhand = 1,
    Feet = 2,
    Legs = 3,
    Chest = 4,
    Head = 5,
    Body = 6,
    Saddle = 7,
}

impl Slot {
    pub const ALL: [Slot; 8] = [
        Slot::Mainhand,
        Slot::Offhand,
        Slot::Feet,
        Slot::Legs,
        Slot::Chest,
        Slot::Head,
        Slot::Body,
        Slot::Saddle,
    ];

    /// The slot's atom.
    pub fn name(self) -> &'static str {
        match self {
            Slot::Mainhand => "mainhand",
            Slot::Offhand => "offhand",
            Slot::Feet => "feet",
            Slot::Legs => "legs",
            Slot::Chest => "chest",
            Slot::Head => "head",
            Slot::Body => "body",
            Slot::Saddle => "saddle",
        }
    }

    pub fn from_name(name: &str) -> Option<Slot> {
        Slot::ALL.into_iter().find(|slot| slot.name() == name)
    }
}

/// Equipment by slot: each an `%ItemStack{}` term.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Equipment(pub [Option<Value>; 8]);

impl Equipment {
    pub fn get(&self, slot: Slot) -> Option<&Value> {
        self.0[slot as usize].as_ref()
    }

    pub fn set(&mut self, slot: Slot, stack: Option<Value>) {
        self.0[slot as usize] = stack;
    }
}

/// Drop chances by slot (`DropChances`), only where set.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct DropChances(pub [Option<f64>; 8]);

impl DropChances {
    pub fn get(&self, slot: Slot) -> Option<f64> {
        self.0[slot as usize]
    }

    pub fn is_empty(&self) -> bool {
        self.0.iter().all(Option::is_none)
    }
}

/// Attribute overrides: `%{"minecraft:x" => %{base, modifiers}}`, kept
/// sorted by id (the map's order).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Attributes(pub Vec<(String, AttributeOverride)>);

impl Attributes {
    pub fn get(&self, id: &str) -> Option<&AttributeOverride> {
        self.0
            .binary_search_by(|(k, _)| k.as_bytes().cmp(id.as_bytes()))
            .ok()
            .map(|i| &self.0[i].1)
    }

    /// The override of `id`, made empty (`%{base: nil, modifiers: []}`) if
    /// absent.
    pub fn entry(&mut self, id: &str) -> &mut AttributeOverride {
        let i = match self
            .0
            .binary_search_by(|(k, _)| k.as_bytes().cmp(id.as_bytes()))
        {
            Ok(i) => i,
            Err(i) => {
                self.0
                    .insert(i, (id.to_owned(), AttributeOverride::default()));
                i
            }
        };
        &mut self.0[i].1
    }

    /// `Map.delete(attributes, id)`.
    pub fn remove(&mut self, id: &str) {
        if let Ok(i) = self
            .0
            .binary_search_by(|(k, _)| k.as_bytes().cmp(id.as_bytes()))
        {
            self.0.remove(i);
        }
    }

    /// The modifier `id` of attribute `name` removed and, with `add`
    /// (`{amount, operation}`), added again after the rest; an override
    /// left without a base or modifiers goes (the Elixir's attribute
    /// toggles: a baby's speed, an enderman's attacking or a witch's
    /// drinking speed).
    pub fn toggle(&mut self, name: &str, id: &str, add: Option<(Number, i32)>) {
        let entry = self.entry(name);
        entry.modifiers.retain(|m| m.id != id);
        if let Some((amount, operation)) = add {
            entry.modifiers.push(Modifier {
                id: id.to_owned(),
                amount,
                operation,
            });
        }
        if entry.base.is_none() && entry.modifiers.is_empty() {
            self.remove(name);
        }
    }
}

/// One attribute's override.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AttributeOverride {
    /// The base value replacing the type's, if any.
    pub base: Option<f64>,
    /// In order.
    pub modifiers: Vec<Modifier>,
}

/// `{id, amount, operation}`.
#[derive(Clone, Debug, PartialEq)]
pub struct Modifier {
    pub id: String,
    pub amount: Number,
    /// 0 add value, 1 add multiplied base, 2 add multiplied total.
    pub operation: i32,
}

/// A number kept as the term had it (an amount may be an integer).
#[derive(Clone, Copy, Debug)]
pub enum Number {
    Int(i64),
    Float(f64),
}

impl Number {
    pub fn as_f64(self) -> f64 {
        match self {
            Number::Int(i) => i as f64,
            Number::Float(f) => f,
        }
    }
}

impl PartialEq for Number {
    fn eq(&self, other: &Number) -> bool {
        match (self, other) {
            (Number::Int(a), Number::Int(b)) => a == b,
            (Number::Float(a), Number::Float(b)) => a.to_bits() == b.to_bits(),
            _ => false,
        }
    }
}

/// A lead (`Leashable.LeashData`).
#[derive(Clone, Debug, PartialEq)]
pub struct Leash {
    pub holder: LeashHolder,
    /// The holder's network id once found (not saved).
    pub id: Option<i32>,
    /// Its angular momentum (not saved).
    pub momentum: f64,
    /// Restored from a record (`delayedLeashInfo`): it looks for its holder
    /// first (not saved).
    pub restored: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum LeashHolder {
    /// `{:player, uuid}`.
    Player([u8; 16]),
    /// `{:knot, {x, y, z}}`: a fence knot's block.
    Knot([i32; 3]),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Home {
    pub center: [i32; 3],
    pub radius: i32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hand {
    MainHand,
    OffHand,
}

impl Hand {
    pub fn name(self) -> &'static str {
        match self {
            Hand::MainHand => "main_hand",
            Hand::OffHand => "off_hand",
        }
    }
}

/// `{hand, ticks used}`.
#[derive(Clone, Debug, PartialEq)]
pub struct Using {
    pub hand: Hand,
    pub ticks: i32,
}

/// `Valimc.Living`.
#[derive(Clone, Debug, PartialEq)]
pub struct Living {
    pub health: Health,
    /// `lastHurtByMobTimestamp` (not saved).
    pub last_mob_hurt: Option<i64>,
    /// Golden hearts, a canonical `f32`.
    pub absorption: f64,
    pub effects: Effects,
    pub fire_ticks: i32,
    pub air_supply: i32,
    pub freezing: Freezing,
}

/// `Valimc.Living.Health`: values are canonical `f32`s.
#[derive(Clone, Debug, PartialEq)]
pub struct Health {
    pub value: f64,
    /// The `max_health` base it was restored or made with (not saved).
    pub maximum: f64,
    pub hurt_ticks: i32,
    pub death_ticks: i32,
    /// `invulnerableTime` (not saved), 0..=20.
    pub cooldown: i32,
    /// `lastHurt` (not saved).
    pub last_hurt: f64,
}

/// `Valimc.Living.Freezing`: only `frozen_ticks` is saved.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Freezing {
    pub powder_snow: bool,
    pub frozen_ticks: i32,
    pub damage_phase: i32,
    pub damage_due: bool,
}

/// Status effects by registry id (sorted), each a priority stack of rungs:
/// the active one first, then strictly weaker suppressed ones.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Effects(pub Vec<(i32, Vec<Rung>)>);

impl Effects {
    pub fn get(&self, id: i32) -> Option<&[Rung]> {
        self.0
            .binary_search_by_key(&id, |(k, _)| *k)
            .ok()
            .map(|i| self.0[i].1.as_slice())
    }

    /// The active amplifier of `id` (`Attributes.amplifier/2`).
    pub fn amplifier(&self, id: i32) -> Option<u8> {
        self.get(id)
            .and_then(|rungs| rungs.first())
            .map(|r| r.amplifier)
    }
}

/// `{remaining ticks (-1 infinite), amplifier, ambient, particles, icon}`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rung {
    pub ticks: i32,
    pub amplifier: u8,
    pub ambient: bool,
    pub particles: bool,
    pub icon: bool,
}

/// `Valimc.Entity.MobMotion`: travel state between ticks. A record holds
/// it whole, as the `%MobMotion{}` struct, with `jump` and `rise` cleared.
#[derive(Clone, Debug, PartialEq)]
pub struct MobMotion {
    pub fall_distance: f64,
    /// 0..=10.
    pub no_jump_delay: i32,
    pub stuck_multiplier: [f64; 3],
    pub strafe: f64,
    /// `yya`.
    pub up: f64,
    pub forward: f64,
    pub speed: f64,
    pub control: Control,
    pub horizontal_collision: bool,
    /// `JumpControl.jump()` this tick (not saved: recorded false).
    pub jump: bool,
    /// A blaze's lift this tick (not saved: recorded false).
    pub rise: bool,
    pub water: f64,
    pub lava: f64,
    pub powder_snow: bool,
    /// `{eye in water, eye block state}` where the last move left it.
    pub eye: Eye,
    /// A rabbit's hopping controls.
    pub hop: Option<Hop>,
    pub vertical_collision: bool,
    /// A family's own move control's setting for the tick.
    pub set: Option<MotionSet>,
    /// A goal's own move before the travel (`BreathAirGoal`): a yaw.
    pub pre_move: Option<f64>,
    pub impulse: Impulse,
    pub travel: Option<Travel>,
    pub move_dist: f64,
    pub next_step: f64,
    /// A ghast's float control.
    pub float: Option<FloatControl>,
    pub eye_water: bool,
    /// The block state it stands on after its last move.
    pub support: Option<i32>,
}

impl Default for MobMotion {
    /// `%MobMotion{}`.
    fn default() -> MobMotion {
        MobMotion {
            fall_distance: 0.0,
            no_jump_delay: 0,
            stuck_multiplier: [0.0; 3],
            strafe: 0.0,
            up: 0.0,
            forward: 0.0,
            speed: 0.0,
            control: Control::Wait,
            horizontal_collision: false,
            jump: false,
            rise: false,
            water: 0.0,
            lava: 0.0,
            powder_snow: false,
            eye: Eye::default(),
            hop: None,
            vertical_collision: false,
            set: None,
            pre_move: None,
            impulse: Impulse::One([0.0; 3]),
            travel: None,
            move_dist: 0.0,
            next_step: 1.0,
            float: None,
            eye_water: false,
            support: None,
        }
    }
}

/// The move control's operation the AI set.
#[derive(Clone, Debug, PartialEq)]
pub enum Control {
    /// `:wait`.
    Wait,
    /// `{:move_to, {x, y, z}, speed}`.
    MoveTo { target: [f64; 3], speed: f64 },
    /// `{:jumping, speed}`.
    Jumping { speed: f64 },
    /// `{:strafe, forward, right, speed}`.
    Strafe {
        forward: f64,
        right: f64,
        speed: f64,
    },
}

/// `{eye in water, block state}`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Eye {
    pub water: bool,
    pub state: i32,
}

/// A family's own move control setting (`MobMotion.set`).
#[derive(Clone, Debug, PartialEq)]
pub enum MotionSet {
    /// `:hold`: it keeps still.
    Hold,
    /// `{speed, lift}`: `setSpeed`, with a lift while its eyes are in water.
    Speed { speed: f64, lift: bool },
    /// `{speed, lift, {xxa, yya, zza}}`: a smooth swimmer's own inputs, nil
    /// keeping `setSpeed`'s.
    Inputs {
        speed: f64,
        lift: bool,
        inputs: [Option<f64>; 3],
    },
}

/// Motion a move control adds after the dead zone: one vector, or a list in
/// order.
#[derive(Clone, Debug, PartialEq)]
pub enum Impulse {
    One([f64; 3]),
    List(Vec<[f64; 3]>),
}

/// `{kind, sink}`: the travel a family's AI chose this tick.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Travel {
    pub kind: TravelKind,
    pub sink: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TravelKind {
    Ground,
    Flying,
    Fish,
    Guardian,
    Dolphin,
    Squid,
}

impl TravelKind {
    pub fn name(self) -> &'static str {
        match self {
            TravelKind::Ground => "ground",
            TravelKind::Flying => "flying",
            TravelKind::Fish => "fish",
            TravelKind::Guardian => "guardian",
            TravelKind::Dolphin => "dolphin",
            TravelKind::Squid => "squid",
        }
    }

    pub fn from_name(name: &str) -> Option<TravelKind> {
        [
            TravelKind::Ground,
            TravelKind::Flying,
            TravelKind::Fish,
            TravelKind::Guardian,
            TravelKind::Dolphin,
            TravelKind::Squid,
        ]
        .into_iter()
        .find(|kind| kind.name() == name)
    }
}

/// A rabbit's hop (`RabbitMoveControl`): `%{jumping, wanted, speed,
/// next_speed}`, plus `path_up` while its AI set it and what the kernel's
/// hop did this tick (`started`, `jumped`, `nav_speed`) until its AI settles
/// it.
#[derive(Clone, Debug, PartialEq)]
pub struct Hop {
    pub jumping: bool,
    pub wanted: Option<[f64; 3]>,
    pub speed: f64,
    pub next_speed: f64,
    pub path_up: Option<bool>,
    pub outcome: Option<HopOutcome>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct HopOutcome {
    pub started: bool,
    pub jumped: bool,
    pub nav_speed: Option<f64>,
}

/// A ghast's `GhastMoveControl` state: its wanted place (none: it waits)
/// and float timer.
#[derive(Clone, Debug, PartialEq)]
pub struct FloatControl {
    pub wanted: Option<[f64; 3]>,
    pub duration: i32,
}

/// `Valimc.AI.Mind`: the saved part (its random and a brain's saved
/// memories) and, once it thought, its live state.
#[derive(Clone, Debug, PartialEq)]
pub struct Mind {
    pub random: LegacyRandom,
    /// The memories its brain saves (`saved/0` keys), as a term map; `None`
    /// for a mob without a brain or whose brain saves none.
    pub memories: Option<Value>,
    /// What it keeps between ticks once it thought; `None` for a mind only a
    /// record gave (not saved).
    pub state: Option<Box<MindState>>,
}

/// The live, unsaved part of `Valimc.AI.Mind` (tick and idle counters, the
/// ambient timer, goal and target selectors, target and aggression, look,
/// body rotation, navigation, hurt memory, the held gaussian, sight cache,
/// brain, particle timers, disabled flags, `own`, pending reactions): the AI
/// core's (`mobs::ai::mind`). A record never holds it, and a restored mob
/// starts with none.
pub use super::ai::mind::MindState;

/// A family's atom-keyed data (`Body.data`), its key set fixed by type.
#[derive(Clone, Debug, PartialEq)]
pub struct FamilyData {
    fields: Vec<(Atom, Value)>,
    slots: Slots,
}

// Indices of shared hot fields in `fields`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct Slots {
    age: Option<u8>,
    forced_age: Option<u8>,
    age_locked: Option<u8>,
    in_love: Option<u8>,
    love_cause: Option<u8>,
    baby: Option<u8>,
}

impl FamilyData {
    /// Data of `fields`; `None` if a key repeats or there are more than 255.
    pub fn new(mut fields: Vec<(Atom, Value)>) -> Option<FamilyData> {
        fields.sort_by(|a, b| a.0.as_str().as_bytes().cmp(b.0.as_str().as_bytes()));
        if fields.len() > 255 || fields.windows(2).any(|w| w[0].0 == w[1].0) {
            return None;
        }
        let slot = |name: &str| {
            fields
                .iter()
                .position(|(k, _)| k.as_str() == name)
                .map(|i| i as u8)
        };
        let slots = Slots {
            age: slot("age"),
            forced_age: slot("forced_age"),
            age_locked: slot("age_locked"),
            in_love: slot("in_love"),
            love_cause: slot("love_cause"),
            baby: slot("baby"),
        };
        Some(FamilyData { fields, slots })
    }

    /// No data (a family without its own).
    pub fn empty() -> FamilyData {
        FamilyData {
            fields: Vec::new(),
            slots: Slots::default(),
        }
    }

    /// The fields in key order.
    pub fn fields(&self) -> &[(Atom, Value)] {
        &self.fields
    }

    pub fn keys(&self) -> impl Iterator<Item = &str> {
        self.fields.iter().map(|(k, _)| k.as_str())
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        self.index(key).map(|i| &self.fields[i].1)
    }

    /// Replaces field `key`'s value; false (and nothing changes) if the type
    /// has no such field.
    pub fn set(&mut self, key: &str, value: Value) -> bool {
        match self.index(key) {
            Some(i) => {
                self.fields[i].1 = value;
                true
            }
            None => false,
        }
    }

    fn index(&self, key: &str) -> Option<usize> {
        self.fields
            .binary_search_by(|(k, _)| k.as_str().as_bytes().cmp(key.as_bytes()))
            .ok()
    }

    fn slot(&self, slot: Option<u8>) -> Option<&Value> {
        slot.map(|i| &self.fields[i as usize].1)
    }

    fn put(&mut self, slot: Option<u8>, value: Value) -> bool {
        match slot {
            Some(i) => {
                self.fields[i as usize].1 = value;
                true
            }
            None => false,
        }
    }

    /// `AgeableMob.age` (negative: a baby).
    pub fn age(&self) -> Option<i64> {
        self.slot(self.slots.age).and_then(Value::as_int)
    }

    pub fn set_age(&mut self, age: i64) -> bool {
        self.put(self.slots.age, Value::Int(age))
    }

    pub fn forced_age(&self) -> Option<i64> {
        self.slot(self.slots.forced_age).and_then(Value::as_int)
    }

    pub fn set_forced_age(&mut self, age: i64) -> bool {
        self.put(self.slots.forced_age, Value::Int(age))
    }

    pub fn age_locked(&self) -> Option<bool> {
        self.slot(self.slots.age_locked).and_then(Value::as_bool)
    }

    pub fn set_age_locked(&mut self, locked: bool) -> bool {
        self.put(self.slots.age_locked, Value::bool(locked))
    }

    /// `Animal.inLove` ticks.
    pub fn in_love(&self) -> Option<i64> {
        self.slot(self.slots.in_love).and_then(Value::as_int)
    }

    pub fn set_in_love(&mut self, ticks: i64) -> bool {
        self.put(self.slots.in_love, Value::Int(ticks))
    }

    /// `Animal.loveCause` (a player uuid or nil), as its term.
    pub fn love_cause(&self) -> Option<&Value> {
        self.slot(self.slots.love_cause)
    }

    pub fn set_love_cause(&mut self, cause: Value) -> bool {
        self.put(self.slots.love_cause, cause)
    }

    /// A zombie's, piglin's or drowned's baby flag.
    pub fn baby(&self) -> Option<bool> {
        self.slot(self.slots.baby).and_then(Value::as_bool)
    }

    pub fn set_baby(&mut self, baby: bool) -> bool {
        self.put(self.slots.baby, Value::bool(baby))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn family_data_slots() {
        let mut data = FamilyData::new(vec![
            (
                Atom::new("variant"),
                Value::Binary(b"minecraft:temperate".to_vec()),
            ),
            (Atom::new("age"), Value::Int(-24000)),
            (Atom::new("in_love"), Value::Int(0)),
            (Atom::new("love_cause"), super::super::term::NIL),
            (Atom::new("age_locked"), Value::bool(false)),
            (Atom::new("forced_age"), Value::Int(0)),
        ])
        .unwrap();
        assert_eq!(data.keys().next(), Some("age"));
        assert_eq!(data.age(), Some(-24000));
        assert!(data.set_in_love(600));
        assert_eq!(data.get("in_love"), Some(&Value::Int(600)));
        assert_eq!(data.baby(), None);
        assert!(!data.set_baby(true));
        assert!(!data.set("missing", Value::Int(1)));
        assert!(FamilyData::new(vec![
            (Atom::new("a"), Value::Int(1)),
            (Atom::new("a"), Value::Int(2))
        ])
        .is_none());
    }

    #[test]
    fn attributes_stay_sorted() {
        let mut attributes = Attributes::default();
        attributes.entry("minecraft:movement_speed").base = Some(0.25);
        attributes
            .entry("minecraft:armor")
            .modifiers
            .push(Modifier {
                id: "minecraft:x".into(),
                amount: Number::Float(1.0),
                operation: 0,
            });
        assert_eq!(attributes.0[0].0, "minecraft:armor");
        assert_eq!(
            attributes.get("minecraft:movement_speed").unwrap().base,
            Some(0.25)
        );
    }
}
