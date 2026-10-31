//! The enchantment engine (VMC-037q): every enchantment's effect components
//! from the pinned data pack (`registry/enchantments.json`), compiled once
//! into typed effects, and vanilla's `EnchantmentHelper` hooks over them.
//!
//! - **Value hooks** (`value`, `unconditioned`) fold an effect component's
//!   value effects (`add`, `set`, `multiply`, `remove_binomial`, `all_of`)
//!   over a stack's enchantments, each where its requirements hold.
//! - **Entity hooks** (`post_attack`, `entity`, `location`) answer the
//!   [`Action`]s vanilla's entity and location effects take, in order. The
//!   engine never touches a world: the owner of the entity applies them, so
//!   one plan serves a player (by NIF) and a mob.
//!
//! A form the pinned pack does not use fails the parse, so a data change
//! cannot be ignored silently. Values are Java floats (`f32`), as vanilla's.

mod eval;
mod parse;

pub use eval::*;

use std::collections::HashMap;

/// `LevelBasedValue`.
#[derive(Clone, Debug, PartialEq)]
pub enum Level {
    Constant(f32),
    Linear(f32, f32),
    Clamped(Box<Level>, f32, f32),
    Fraction(Box<Level>, Box<Level>),
    Squared(f32),
    Lookup(Vec<f32>, Box<Level>),
    Exponent(Box<Level>, Box<Level>),
}

impl Level {
    /// `calculate(level)`.
    pub fn at(&self, level: i32) -> f32 {
        match self {
            Level::Constant(v) => *v,
            Level::Linear(base, per) => base + per * (level - 1) as f32,
            Level::Clamped(v, min, max) => v.at(level).clamp(*min, *max),
            Level::Fraction(n, d) => {
                let d = d.at(level);
                if d == 0.0 {
                    0.0
                } else {
                    n.at(level) / d
                }
            }
            Level::Squared(added) => (level * level) as f32 + added,
            Level::Lookup(values, fallback) => {
                if level >= 1 && level as usize <= values.len() {
                    values[level as usize - 1]
                } else {
                    fallback.at(level)
                }
            }
            Level::Exponent(base, power) => {
                (base.at(level) as f64).powf(power.at(level) as f64) as f32
            }
        }
    }
}

/// `FloatProvider` (a sound's volume and pitch, a particle's speed).
#[derive(Clone, Debug, PartialEq)]
pub enum FloatProvider {
    Constant(f32),
    /// `[min, max)`.
    Uniform(f32, f32),
}

/// `EnchantmentValueEffect`.
#[derive(Clone, Debug, PartialEq)]
pub enum ValueEffect {
    Add(Level),
    Set(Level),
    Multiply(Level),
    RemoveBinomial(Level),
    AllOf(Vec<ValueEffect>),
}

/// Whose entity an `entity_properties` requirement reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Who {
    This,
    Attacker,
    DirectAttacker,
}

/// The `EntityPredicate` fields the pinned pack uses.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct EntityPredicate {
    /// An entity type (`Ok`) or type tag (`Err`, namespaced).
    pub entity_type: Option<Result<u16, String>>,
    pub on_ground: Option<bool>,
    pub in_water: Option<bool>,
    pub fall_flying: Option<bool>,
    pub flying: Option<bool>,
    /// `minecraft:vehicle: {}`: it rides something.
    pub vehicle: bool,
    /// `minecraft:location.can_see_sky`.
    pub can_see_sky: Option<bool>,
    /// `minecraft:movement_affected_by`'s block tag.
    pub affected_by: Option<String>,
    pub min_horizontal_speed: Option<f64>,
    pub min_fall_distance: Option<f64>,
    pub periodic_tick: Option<i32>,
    /// `type_specific/player`: its game modes (empty: any) and least food.
    pub player: Option<(Vec<String>, Option<i32>)>,
}

/// `LootItemCondition`, as enchantments use it.
#[derive(Clone, Debug, PartialEq)]
pub enum Condition {
    AllOf(Vec<Condition>),
    AnyOf(Vec<Condition>),
    Inverted(Box<Condition>),
    Entity(Who, EntityPredicate),
    /// `damage_source_properties`: tags (namespaced) and `is_direct`.
    Damage(Vec<(String, bool)>, Option<bool>),
    /// `match_tool`: an item (`Ok`) or item tag (`Err`).
    MatchTool(Result<i32, String>),
    /// `random_chance`.
    Chance(Level),
    Active(bool),
    Thundering(bool),
    /// `location_check`: the block's tag at the origin and its sky.
    Location(Option<String>, Option<bool>),
}

/// A block predicate (`replace_disk`'s).
#[derive(Clone, Debug, PartialEq)]
pub enum BlockPredicate {
    AllOf(Vec<BlockPredicate>),
    /// `matching_block_tag`: offset and tag (namespaced).
    Tag([i32; 3], String),
    /// `matching_blocks`: offset and block names.
    Blocks([i32; 3], Vec<String>),
    /// `matching_fluids`: offset and fluid names.
    Fluids([i32; 3], Vec<String>),
    Unobstructed,
}

/// `SpawnParticlesEffect`'s position and velocity sources.
#[derive(Clone, Debug, PartialEq)]
pub struct Particles {
    pub particle: String,
    /// `(in bounding box, offset, scale)` for x/z and for y.
    pub horizontal: (bool, f32, f32),
    pub vertical: (bool, f32, f32),
    /// `(movement scale, base)`.
    pub horizontal_velocity: (f32, FloatProvider),
    pub vertical_velocity: (f32, FloatProvider),
    pub speed: FloatProvider,
}

/// `ExplodeEffect`.
#[derive(Clone, Debug, PartialEq)]
pub struct Explode {
    pub attribute_to_user: bool,
    pub damage_type: Option<String>,
    pub knockback_multiplier: Option<Level>,
    pub immune_blocks: Option<String>,
    pub offset: [f64; 3],
    pub radius: Level,
    pub create_fire: bool,
    pub block_interaction: String,
    pub small_particle: String,
    pub large_particle: String,
    pub sound: String,
}

/// `EnchantmentEntityEffect` and the location effects.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    AllOf(Vec<Effect>),
    /// Effects (names), durations in seconds and amplifiers.
    MobEffect {
        effects: Vec<String>,
        min_duration: Level,
        max_duration: Level,
        min_amplifier: Level,
        max_amplifier: Level,
    },
    Ignite(Level),
    DamageEntity(Level, Level, String),
    ChangeItemDamage(Level),
    Exhaustion(Level),
    Impulse([f64; 3], [f64; 3], Level),
    Sound(Vec<String>, FloatProvider, FloatProvider),
    Particles(Box<Particles>),
    Summon(Vec<String>, bool),
    Explode(Box<Explode>),
    ReplaceDisk {
        radius: Level,
        height: Level,
        offset: [i32; 3],
        predicate: Option<BlockPredicate>,
        state: (String, Vec<(String, String)>),
        event: Option<String>,
    },
    /// A location effect's attribute modifier: attribute, id, amount,
    /// operation (0 add, 1 multiplied base, 2 multiplied total).
    Attribute(String, String, Level, u8),
}

/// `EnchantmentTarget`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    Attacker,
    DamagingEntity,
    Victim,
}

/// A `post_attack` entry: who holds the enchanted item, who is affected.
#[derive(Clone, Debug, PartialEq)]
pub struct Targeted {
    pub enchanted: Target,
    pub affected: Target,
    pub effect: Effect,
    pub condition: Option<Condition>,
}

/// An attribute effect (`minecraft:attributes`).
#[derive(Clone, Debug, PartialEq)]
pub struct AttributeEffect {
    pub attribute: String,
    pub id: String,
    pub amount: Level,
    pub operation: u8,
}

/// The value effect components (each a list of conditional effects).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ValueHook {
    DamageProtection,
    ItemDamage,
    AmmoUse,
    ProjectilePiercing,
    BlockExperience,
    MobExperience,
    RepairWithXp,
    TridentReturnAcceleration,
    FishingTimeReduction,
    FishingLuckBonus,
    Damage,
    SmashDamagePerFallenBlock,
    Knockback,
    ArmorEffectiveness,
    ProjectileCount,
    ProjectileSpread,
}

/// The unconditioned value components (one effect each).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Unconditioned {
    CrossbowChargeTime,
    TridentSpinAttackStrength,
}

/// The entity effect components (each a list of conditional effects).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EntityHook {
    Tick,
    ProjectileSpawned,
    HitBlock,
    PostPiercingAttack,
}

/// One enchantment's definition.
#[derive(Clone, Debug, Default)]
pub struct Definition {
    pub name: String,
    /// Bits by `Slot as usize` of its slot groups.
    pub slots: u8,
    pub max_level: i32,
    pub values: HashMap<ValueHook, Vec<(ValueEffect, Option<Condition>)>>,
    pub unconditioned: HashMap<Unconditioned, ValueEffect>,
    pub entity: HashMap<EntityHook, Vec<(Effect, Option<Condition>)>>,
    pub post_attack: Vec<Targeted>,
    /// `equipment_drops`: enchanted, affected, effect, requirements.
    pub equipment_drops: Vec<(Target, Target, ValueEffect, Option<Condition>)>,
    pub location_changed: Vec<(Effect, Option<Condition>)>,
    pub attributes: Vec<AttributeEffect>,
    pub immunity: Vec<Option<Condition>>,
    pub prevent_armor_change: bool,
    pub prevent_equipment_drop: bool,
    /// `crossbow_charging_sounds` by level.
    pub charging_sounds: Vec<ChargingSounds>,
    /// `trident_sound` by level.
    pub trident_sounds: Vec<String>,
}

/// `CrossbowItem.ChargingSounds`: start, mid and end.
pub type ChargingSounds = (Option<String>, Option<String>, Option<String>);

/// Every enchantment's definition, by name.
#[derive(Clone, Debug, Default)]
pub struct Engine {
    pub definitions: HashMap<String, Definition>,
}
