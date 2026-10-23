//! Vanilla's loot tables for containers (VMC-072a), from the generated loot
//! facts (`LootOracle`, `priv/loot`): pools with rolls and bonus rolls,
//! weighted entries (items, empty entries, nested tables), conditions,
//! number providers and the item functions container tables use, evaluated
//! in vanilla's order of random draws; `LootTable.fill` with its shuffled
//! slots and split stacks, and `getRandomItems` for brushable blocks.
//!
//! What a table reads from the world goes through `LootWorld`: the biome at
//! a position, the nearest map structure and new map ids.

use std::collections::{HashMap, HashSet};

use crate::worldgen::json::Json;
use crate::worldgen::random::Random;

/// An item stack as loot tables build it: the item, its count and the
/// components the functions set (unset ones keep the item's defaults).
#[derive(Clone, Debug, PartialEq)]
pub struct Stack {
    pub item: String,
    pub count: i32,
    pub enchantments: Vec<(String, i32)>,
    pub stored_enchantments: Vec<(String, i32)>,
    pub damage: i32,
    pub potion: Option<String>,
    pub stew_effects: Vec<(String, i32)>,
    pub instrument: Option<String>,
    pub ominous_amplifier: Option<i32>,
    pub item_name: Option<Json>,
    pub custom_name: Option<Json>,
    pub map_id: Option<i32>,
    /// Map decorations: key, type, x, z, rotation.
    pub map_decorations: Vec<(String, String, f64, f64, f32)>,
}

impl Stack {
    fn new(item: &str) -> Stack {
        Stack {
            item: item.to_string(),
            count: 1,
            enchantments: Vec::new(),
            stored_enchantments: Vec::new(),
            damage: 0,
            potion: None,
            stew_effects: Vec::new(),
            instrument: None,
            ominous_amplifier: None,
            item_name: None,
            custom_name: None,
            map_id: None,
            map_decorations: Vec::new(),
        }
    }

    fn empty() -> Stack {
        let mut s = Stack::new("minecraft:air");
        s.count = 0;
        s
    }

    pub fn is_empty(&self) -> bool {
        self.count <= 0 || self.item == "minecraft:air"
    }

    fn is(&self, item: &str) -> bool {
        self.item == item
    }

    /// `ItemStack.enchant`: upgrades the enchantment (stored on enchanted
    /// books).
    fn enchant(&mut self, enchantment: &str, level: i32) {
        if level <= 0 {
            return;
        }
        let level = level.min(255);
        let list = self.enchantments_mut();
        match list.iter_mut().find(|(e, _)| e == enchantment) {
            Some((_, l)) => *l = (*l).max(level),
            None => list.push((enchantment.to_string(), level)),
        }
    }

    /// `ItemEnchantments.Mutable.set`.
    fn set_enchantment(&mut self, enchantment: &str, level: i32) {
        let list = self.enchantments_mut();
        list.retain(|(e, _)| e != enchantment);
        if level > 0 {
            list.push((enchantment.to_string(), level.min(255)));
        }
    }

    fn enchantment_level(&self, enchantment: &str) -> i32 {
        let list = if self.is("minecraft:enchanted_book") {
            &self.stored_enchantments
        } else {
            &self.enchantments
        };
        list.iter()
            .find(|(e, _)| e == enchantment)
            .map_or(0, |(_, l)| *l)
    }

    fn enchantments_mut(&mut self) -> &mut Vec<(String, i32)> {
        if self.is("minecraft:enchanted_book") {
            &mut self.stored_enchantments
        } else {
            &mut self.enchantments
        }
    }

    /// `transmuteCopy`: another item with the same count and components.
    fn transmute(&self, item: &str) -> Stack {
        let mut s = self.clone();
        s.item = item.to_string();
        // Enchantments follow the component, not the item: an enchanted
        // book's stored enchantments stay stored.
        s
    }
}

/// An item's defaults that loot functions read.
#[derive(Clone, Copy, Debug)]
struct ItemInfo {
    max_stack: i32,
    max_damage: i32,
    damageable: bool,
    enchantable: i32,
}

#[derive(Debug)]
struct EnchantmentDef {
    id: String,
    weight: i32,
    max_level: i32,
    min_cost: (i32, i32),
    max_cost: (i32, i32),
    supported: HashSet<String>,
    primary: Option<HashSet<String>>,
    exclusive: HashSet<String>,
}

impl EnchantmentDef {
    fn min_cost(&self, level: i32) -> i32 {
        self.min_cost.0 + self.min_cost.1 * (level - 1)
    }

    fn max_cost(&self, level: i32) -> i32 {
        self.max_cost.0 + self.max_cost.1 * (level - 1)
    }
}

/// What a table asks the world.
pub trait LootWorld {
    /// The biome at a position, or `None` where nothing is loaded.
    fn biome(&mut self, pos: [i32; 3]) -> Option<String>;
    /// `findNearestMapStructure`: the structures (a tag's name when the
    /// holder set is one, and its members), the origin, the search radius and
    /// whether found structures are referenced.
    fn map_structure(
        &mut self,
        tag: Option<&str>,
        structures: &[String],
        origin: [i32; 3],
        radius: i32,
        skip_existing: bool,
    ) -> Option<[i32; 3]>;
    /// A new map's id (`MapItem.applyNewSavedData` with its centre, scale
    /// and tracking).
    fn new_map(&mut self, x: i32, z: i32, scale: i32) -> i32;
}

/// A holder set as a codec writes it: a tag or identifiers.
#[derive(Clone, Debug)]
struct HolderSet {
    tag: Option<String>,
    members: Vec<String>,
}

#[derive(Debug)]
enum IntProvider {
    Constant(i32),
    Uniform(Box<IntProvider>, Box<IntProvider>),
}

#[derive(Debug)]
enum FloatProvider {
    Constant(f32),
    Uniform(Box<FloatProvider>, Box<FloatProvider>),
}

#[derive(Debug)]
enum Condition {
    RandomChance(FloatProvider),
    Inverted(Box<Condition>),
    AllOf(Vec<Condition>),
    AnyOf(Vec<Condition>),
    Location {
        biomes: Option<HolderSet>,
        offset: [i32; 3],
    },
    KilledByPlayer,
    /// `random_chance_with_enchanted_bonus`: the attacker's level of the
    /// enchantment picks the chance (`LevelBasedValue.Linear` above zero).
    EnchantedChance {
        enchantment: String,
        unenchanted: f32,
        base: f32,
        per_level: f32,
    },
    Entity(EntityTarget, EntityPredicate),
}

/// The entity an `entity_properties` condition asks about.
#[derive(Debug, Clone, Copy)]
enum EntityTarget {
    This,
    Attacker,
    DirectAttacker,
}

/// The entity predicates the modelled mobs' tables use: the victim's flags
/// and vehicle type, and enchantments on an attacker's main-hand item.
#[derive(Debug, Default)]
struct EntityPredicate {
    on_fire: Option<bool>,
    baby: Option<bool>,
    vehicle: Option<Vec<String>>,
    mainhand_enchantments: Option<Vec<String>>,
}

/// An entity's death as its loot table reads it (`LootContextParamSets.ENTITY`):
/// the victim's flags and vehicle type, whether a player killed it, and the
/// main-hand enchantments of the attacker and the direct attacker (None when
/// there is no living one). Enchantment levels act from the main hand, where
/// the tables' enchantments (Looting, the `smelts_loot` set) act.
#[derive(Debug, Clone, Default)]
pub struct Death {
    pub on_fire: bool,
    pub baby: bool,
    pub vehicle: Option<String>,
    pub killed_by_player: bool,
    pub attacker: Option<Vec<(String, i32)>>,
    pub direct_attacker: Option<Vec<(String, i32)>>,
}

impl Death {
    fn attacker_level(&self, enchantment: &str) -> i32 {
        self.attacker
            .iter()
            .flatten()
            .filter(|(e, _)| e == enchantment)
            .map(|(_, level)| *level)
            .max()
            .unwrap_or(0)
    }
}

impl EntityPredicate {
    fn matches(&self, target: EntityTarget, death: &Death) -> bool {
        let mainhand = match target {
            EntityTarget::This => None,
            EntityTarget::Attacker => match &death.attacker {
                Some(m) => Some(m),
                None => return false,
            },
            EntityTarget::DirectAttacker => match &death.direct_attacker {
                Some(m) => Some(m),
                None => return false,
            },
        };
        let this = matches!(target, EntityTarget::This);
        // Only the victim's flags and vehicle, and only attackers' items, are known.
        if (self.on_fire.is_some() || self.baby.is_some() || self.vehicle.is_some()) && !this {
            return false;
        }
        self.on_fire.is_none_or(|v| v == death.on_fire)
            && self.baby.is_none_or(|v| v == death.baby)
            && self
                .vehicle
                .as_ref()
                .is_none_or(|types| death.vehicle.as_ref().is_some_and(|v| types.contains(v)))
            && self.mainhand_enchantments.as_ref().is_none_or(|set| {
                mainhand.is_some_and(|m| m.iter().any(|(e, level)| *level > 0 && set.contains(e)))
            })
    }
}

#[derive(Debug)]
enum Function {
    Sequence(Vec<Function>),
    Conditional(Box<Condition>, Box<Function>),
    SetCount(IntProvider, bool),
    EnchantRandomly {
        options: Option<Vec<usize>>,
        only_compatible: bool,
    },
    EnchantWithLevels {
        levels: IntProvider,
        options: Option<Vec<usize>>,
    },
    SetEnchantments(Vec<(String, IntProvider)>, bool),
    SetDamage(FloatProvider, bool),
    SetPotion(String),
    SetStewEffect(Vec<(String, IntProvider)>),
    SetOminousAmplifier(IntProvider),
    SetInstrument(Vec<String>),
    SetName {
        name: Json,
        item_name: bool,
    },
    Filtered {
        filter: ItemFilter,
        on_pass: Option<Box<Function>>,
        on_fail: Option<Box<Function>>,
    },
    Discard,
    ExplorationMap {
        destination: HolderSet,
        decoration: String,
        zoom: i32,
        radius: i32,
        skip_existing: bool,
    },
    EnchantedCountIncrease {
        enchantment: String,
        count: FloatProvider,
        limit: i32,
    },
    FurnaceSmelt(bool),
}

/// An item predicate: items, and components that must be present.
#[derive(Debug)]
struct ItemFilter {
    items: Option<Vec<String>>,
    present: Vec<String>,
}

#[derive(Debug)]
enum EntryKind {
    Item(String),
    Empty,
    /// The context's dynamic drops (a container's or pot's contents), which
    /// a container fill never has: picked by weight, adding nothing.
    Dynamic,
    Tables {
        tables: Vec<String>,
        expand: bool,
    },
    Tag {
        items: Vec<String>,
        expand: bool,
    },
    /// The first child that expands.
    Alternatives(Vec<Entry>),
    /// Children until one does not expand.
    Sequence(Vec<Entry>),
    /// Every child.
    Group(Vec<Entry>),
}

/// One expanded entry `LootPool.addRandomItem` picks from: its weight, what
/// it yields and the modifiers its items pass through, innermost first.
struct Choice<'a> {
    weight: i32,
    leaf: Leaf<'a>,
    modifiers: Vec<&'a Function>,
}

enum Leaf<'a> {
    Entry(&'a Entry),
    Table(&'a str),
    Item(&'a str),
}

#[derive(Debug)]
struct Entry {
    kind: EntryKind,
    weight: i32,
    quality: i32,
    condition: Option<Condition>,
    modifier: Option<Function>,
}

#[derive(Debug)]
struct Pool {
    entries: Vec<Entry>,
    condition: Option<Condition>,
    modifier: Option<Function>,
    rolls: IntProvider,
    bonus_rolls: FloatProvider,
}

#[derive(Debug)]
struct Table {
    pools: Vec<Pool>,
    modifier: Option<Function>,
}

/// The loot facts, parsed.
#[derive(Debug, Default)]
pub struct Loot {
    tables: HashMap<String, Table>,
    items: HashMap<String, ItemInfo>,
    enchantments: Vec<EnchantmentDef>,
    enchantment_index: HashMap<String, usize>,
    instantaneous: HashSet<String>,
    /// Per registry, per tag, its members in order.
    tags: HashMap<String, HashMap<String, Vec<String>>>,
    /// Furnace (smelting) results by input item, for `furnace_smelt`.
    smelting: HashMap<String, String>,
}

/// Where produced items go (vanilla's item consumers).
type Sink<'s> = dyn FnMut(Stack, &mut Ctx) -> Result<(), String> + 's;

struct Ctx<'w> {
    random: Random,
    luck: f32,
    origin: [f64; 3],
    world: &'w mut dyn LootWorld,
    visited: Vec<String>,
    death: Option<Death>,
}

/// `Mth.floor` of a float.
fn floor_f(v: f32) -> i32 {
    (v as f64).floor() as i32
}

/// `Mth.nextInt`.
fn next_int(random: &mut Random, min: i32, max: i32) -> i32 {
    if min >= max {
        min
    } else {
        random.next_int_bounded(max - min + 1) + min
    }
}

/// `Math.round(float)`: half up, NaN to 0, saturating.
fn round_f(v: f32) -> i32 {
    if v.is_nan() {
        return 0;
    }
    let floor = v.floor();
    let rounded = if v - floor >= 0.5 { floor + 1.0 } else { floor };
    rounded as i32
}

impl Loot {
    /// The facts: the loot tables (`tables.json`) and what evaluation reads
    /// (`registries.json`).
    pub fn parse(tables: &Json, registries: &Json) -> Result<Loot, String> {
        let mut loot = Loot::default();
        for (registry, by_tag) in registries.field("tags")?.entries()? {
            let mut map = HashMap::new();
            for (tag, members) in by_tag.entries()? {
                let members = members
                    .as_array()?
                    .iter()
                    .map(|m| m.as_str().map(str::to_string))
                    .collect::<Result<Vec<_>, _>>()?;
                map.insert(tag.clone(), members);
            }
            loot.tags.insert(registry.clone(), map);
        }
        for row in registries.field("items")?.as_array()? {
            let row = row.as_array()?;
            loot.items.insert(
                row[0].as_str()?.to_string(),
                ItemInfo {
                    max_stack: row[1].as_i32()?,
                    max_damage: row[2].as_i32()?,
                    damageable: row[3].as_bool()?,
                    enchantable: row[4].as_i32()?,
                },
            );
        }
        let names = |j: &Json| -> Result<HashSet<String>, String> {
            j.as_array()?
                .iter()
                .map(|n| n.as_str().map(str::to_string))
                .collect()
        };
        for (index, e) in registries
            .field("enchantments")?
            .as_array()?
            .iter()
            .enumerate()
        {
            let cost = |k: &str| -> Result<(i32, i32), String> {
                let c = e.field(k)?;
                Ok((
                    c.field("base")?.as_i32()?,
                    c.field("per_level_above_first")?.as_i32()?,
                ))
            };
            let id = e.field("id")?.as_str()?.to_string();
            loot.enchantment_index.insert(id.clone(), index);
            loot.enchantments.push(EnchantmentDef {
                id,
                weight: e.field("weight")?.as_i32()?,
                max_level: e.field("max_level")?.as_i32()?,
                min_cost: cost("min_cost")?,
                max_cost: cost("max_cost")?,
                supported: names(e.field("supported_items")?)?,
                primary: e.get("primary_items").map(names).transpose()?,
                exclusive: names(e.field("exclusive_set")?)?,
            });
        }
        loot.instantaneous = names(registries.field("instantaneous_effects")?)?;
        if let Some(smelting) = registries.get("smelting") {
            for (input, result) in smelting.entries()? {
                loot.smelting
                    .insert(input.clone(), result.as_str()?.to_string());
            }
        }
        for (id, json) in tables.entries()? {
            let table = loot
                .table(json)
                .map_err(|e| format!("loot table {id}: {e}"))?;
            loot.tables.insert(id.clone(), table);
        }
        fn named(entries: &[Entry], out: &mut Vec<String>) {
            for entry in entries {
                match &entry.kind {
                    EntryKind::Tables { tables, .. } => out.extend(tables.iter().cloned()),
                    EntryKind::Alternatives(children)
                    | EntryKind::Sequence(children)
                    | EntryKind::Group(children) => named(children, out),
                    _ => {}
                }
            }
        }
        for (id, table) in &loot.tables {
            let mut tables = Vec::new();
            for pool in &table.pools {
                named(&pool.entries, &mut tables);
            }
            if let Some(missing) = tables.iter().find(|t| !loot.tables.contains_key(*t)) {
                return Err(format!("loot table {id} names unknown table {missing}"));
            }
        }
        Ok(loot)
    }

    pub fn has_table(&self, id: &str) -> bool {
        self.tables.contains_key(id)
    }

    /// The item stack's maximum count.
    pub fn max_stack(&self, item: &str) -> i32 {
        self.items.get(item).map_or(64, |i| i.max_stack)
    }

    fn holder_set(&self, registry: &str, json: &Json) -> Result<HolderSet, String> {
        match json {
            Json::String(s) if s.starts_with('#') => {
                let tag = &s[1..];
                let members = self
                    .tags
                    .get(registry)
                    .and_then(|t| t.get(tag))
                    .ok_or_else(|| format!("unknown {registry} tag {tag}"))?
                    .clone();
                Ok(HolderSet {
                    tag: Some(tag.to_string()),
                    members,
                })
            }
            Json::String(s) => Ok(HolderSet {
                tag: None,
                members: vec![s.clone()],
            }),
            Json::Array(items) => Ok(HolderSet {
                tag: None,
                members: items
                    .iter()
                    .map(|i| i.as_str().map(str::to_string))
                    .collect::<Result<_, _>>()?,
            }),
            other => Err(format!("holder set {other:?}")),
        }
    }

    fn enchantment_options(&self, json: Option<&Json>) -> Result<Option<Vec<usize>>, String> {
        let Some(json) = json else {
            return Ok(None);
        };
        let set = self.holder_set("minecraft:enchantment", json)?;
        set.members
            .iter()
            .map(|m| {
                self.enchantment_index
                    .get(m)
                    .copied()
                    .ok_or_else(|| format!("unknown enchantment {m}"))
            })
            .collect::<Result<Vec<_>, _>>()
            .map(Some)
    }

    fn table(&self, json: &Json) -> Result<Table, String> {
        let pools = match json.get("pools") {
            Some(p) => p
                .as_array()?
                .iter()
                .map(|p| self.pool(p))
                .collect::<Result<_, _>>()?,
            None => Vec::new(),
        };
        Ok(Table {
            pools,
            modifier: json.get("modifier").map(|m| self.function(m)).transpose()?,
        })
    }

    fn pool(&self, json: &Json) -> Result<Pool, String> {
        Ok(Pool {
            entries: json
                .field("entries")?
                .as_array()?
                .iter()
                .map(|e| self.entry(e))
                .collect::<Result<_, _>>()?,
            condition: json
                .get("condition")
                .map(|c| self.condition(c))
                .transpose()?,
            modifier: json.get("modifier").map(|m| self.function(m)).transpose()?,
            rolls: Self::int_provider(json.field("rolls")?)?,
            bonus_rolls: match json.get("bonus_rolls") {
                Some(b) => Self::float_provider(b)?,
                None => FloatProvider::Constant(0.0),
            },
        })
    }

    fn entry(&self, json: &Json) -> Result<Entry, String> {
        let kind = match json.field("type")?.as_str()? {
            "minecraft:item" => EntryKind::Item(json.field("name")?.as_str()?.to_string()),
            "minecraft:empty" => EntryKind::Empty,
            "minecraft:dynamic" => EntryKind::Dynamic,
            "minecraft:tag" => EntryKind::Tag {
                items: self
                    .holder_set("minecraft:item", json.field("items")?)?
                    .members,
                expand: json.get("expand").map_or(Ok(false), Json::as_bool)?,
            },
            kind @ ("minecraft:alternatives" | "minecraft:sequence" | "minecraft:group") => {
                let children = match json.get("children") {
                    Some(c) => c
                        .as_array()?
                        .iter()
                        .map(|c| self.entry(c))
                        .collect::<Result<_, _>>()?,
                    None => Vec::new(),
                };
                match kind {
                    "minecraft:alternatives" => EntryKind::Alternatives(children),
                    "minecraft:sequence" => EntryKind::Sequence(children),
                    _ => EntryKind::Group(children),
                }
            }
            "minecraft:loot_table" => {
                let value = json.field("value")?;
                let tables = match value {
                    Json::String(s) if !s.starts_with('#') => vec![s.clone()],
                    Json::Array(items) => items
                        .iter()
                        .map(|i| i.as_str().map(str::to_string))
                        .collect::<Result<_, _>>()?,
                    other => return Err(format!("loot table entry value {other:?}")),
                };
                EntryKind::Tables {
                    tables,
                    expand: json.get("expand").map_or(Ok(false), Json::as_bool)?,
                }
            }
            other => return Err(format!("loot entry {other} is not implemented")),
        };
        Ok(Entry {
            kind,
            weight: json.get("weight").map_or(Ok(1), Json::as_i32)?,
            quality: json.get("quality").map_or(Ok(0), Json::as_i32)?,
            condition: json
                .get("condition")
                .map(|c| self.condition(c))
                .transpose()?,
            modifier: json.get("modifier").map(|m| self.function(m)).transpose()?,
        })
    }

    fn int_provider(json: &Json) -> Result<IntProvider, String> {
        if let Json::Number(_) = json {
            return Ok(IntProvider::Constant(json.as_i32()?));
        }
        Ok(match json.field("type")?.as_str()? {
            "minecraft:constant" => IntProvider::Constant(json.field("value")?.as_i32()?),
            "minecraft:uniform" => IntProvider::Uniform(
                Box::new(Self::int_provider(json.field("min")?)?),
                Box::new(Self::int_provider(json.field("max")?)?),
            ),
            other => return Err(format!("int provider {other} is not implemented")),
        })
    }

    fn float_provider(json: &Json) -> Result<FloatProvider, String> {
        if let Json::Number(n) = json {
            return Ok(FloatProvider::Constant(*n as f32));
        }
        Ok(match json.field("type")?.as_str()? {
            "minecraft:constant" => FloatProvider::Constant(json.field("value")?.as_f64()? as f32),
            "minecraft:uniform" => FloatProvider::Uniform(
                Box::new(Self::float_provider(json.field("min")?)?),
                Box::new(Self::float_provider(json.field("max")?)?),
            ),
            other => return Err(format!("float provider {other} is not implemented")),
        })
    }

    fn condition(&self, json: &Json) -> Result<Condition, String> {
        if let Json::Array(items) = json {
            return Ok(Condition::AllOf(
                items
                    .iter()
                    .map(|c| self.condition(c))
                    .collect::<Result<_, _>>()?,
            ));
        }
        Ok(match json.field("type")?.as_str()? {
            "minecraft:random_chance" => {
                Condition::RandomChance(Self::float_provider(json.field("chance")?)?)
            }
            "minecraft:inverted" => {
                Condition::Inverted(Box::new(self.condition(json.field("term")?)?))
            }
            "minecraft:all_of" => Condition::AllOf(
                json.field("terms")?
                    .as_array()?
                    .iter()
                    .map(|c| self.condition(c))
                    .collect::<Result<_, _>>()?,
            ),
            "minecraft:any_of" => Condition::AnyOf(
                json.field("terms")?
                    .as_array()?
                    .iter()
                    .map(|c| self.condition(c))
                    .collect::<Result<_, _>>()?,
            ),
            "minecraft:location_check" => {
                let mut biomes = None;
                if let Some(predicate) = json.get("predicate") {
                    for (key, value) in predicate.entries()? {
                        match key.as_str() {
                            "biomes" => {
                                biomes = Some(self.holder_set("minecraft:worldgen/biome", value)?)
                            }
                            other => {
                                return Err(format!(
                                    "location predicate {other} is not implemented"
                                ))
                            }
                        }
                    }
                }
                let o = |k: &str| json.get(k).map_or(Ok(0), Json::as_i32);
                Condition::Location {
                    biomes,
                    offset: [o("offsetX")?, o("offsetY")?, o("offsetZ")?],
                }
            }
            "minecraft:killed_by_player" => Condition::KilledByPlayer,
            "minecraft:random_chance_with_enchanted_bonus" => {
                let (base, per_level) = match json.field("enchanted_chance")? {
                    Json::Number(n) => (*n as f32, 0.0),
                    v if v.field("type")?.as_str()? == "minecraft:linear" => (
                        v.field("base")?.as_f64()? as f32,
                        v.field("per_level_above_first")?.as_f64()? as f32,
                    ),
                    other => return Err(format!("enchanted chance {other:?} is not implemented")),
                };
                Condition::EnchantedChance {
                    enchantment: json.field("enchantment")?.as_str()?.to_string(),
                    unenchanted: json.field("unenchanted_chance")?.as_f64()? as f32,
                    base,
                    per_level,
                }
            }
            "minecraft:entity_properties" => {
                let target = match json.field("entity")?.as_str()? {
                    "this" => EntityTarget::This,
                    "attacker" => EntityTarget::Attacker,
                    "direct_attacker" => EntityTarget::DirectAttacker,
                    other => return Err(format!("entity target {other} is not implemented")),
                };
                let predicate = match json.get("predicate") {
                    Some(p) => self.entity_predicate(p)?,
                    None => EntityPredicate::default(),
                };
                Condition::Entity(target, predicate)
            }
            other => return Err(format!("loot condition {other} is not implemented")),
        })
    }

    fn entity_predicate(&self, json: &Json) -> Result<EntityPredicate, String> {
        let mut predicate = EntityPredicate::default();
        for (key, value) in json.entries()? {
            match key.as_str() {
                "minecraft:flags" => {
                    for (flag, v) in value.entries()? {
                        match flag.as_str() {
                            "is_on_fire" => predicate.on_fire = Some(v.as_bool()?),
                            "is_baby" => predicate.baby = Some(v.as_bool()?),
                            other => return Err(format!("entity flag {other} is not implemented")),
                        }
                    }
                }
                "minecraft:vehicle" => {
                    let mut types = None;
                    for (k, v) in value.entries()? {
                        match (k.as_str(), v) {
                            ("minecraft:entity_type", Json::String(t)) if !t.starts_with('#') => {
                                types = Some(vec![t.clone()])
                            }
                            (other, _) => {
                                return Err(format!("vehicle predicate {other} is not implemented"))
                            }
                        }
                    }
                    predicate.vehicle = types;
                }
                "minecraft:equipment" => {
                    for (slot, item) in value.entries()? {
                        if slot != "mainhand" {
                            return Err(format!("equipment slot {slot} is not implemented"));
                        }
                        let mut set = Vec::new();
                        for (k, v) in item.entries()? {
                            if k != "predicates" {
                                return Err(format!("item predicate {k} is not implemented"));
                            }
                            for (component, list) in v.entries()? {
                                if component != "minecraft:enchantments" {
                                    return Err(format!(
                                        "item predicate {component} is not implemented"
                                    ));
                                }
                                for e in list.as_array()? {
                                    for (field, ids) in e.entries()? {
                                        if field != "enchantments" {
                                            return Err(format!(
                                                "enchantment predicate {field} is not implemented"
                                            ));
                                        }
                                        set.extend(
                                            self.holder_set("minecraft:enchantment", ids)?.members,
                                        );
                                    }
                                }
                            }
                        }
                        predicate.mainhand_enchantments = Some(set);
                    }
                }
                other => return Err(format!("entity predicate {other} is not implemented")),
            }
        }
        Ok(predicate)
    }

    fn function(&self, json: &Json) -> Result<Function, String> {
        if let Json::Array(items) = json {
            return Ok(Function::Sequence(
                items
                    .iter()
                    .map(|f| self.function(f))
                    .collect::<Result<_, _>>()?,
            ));
        }
        let int = |k: &str| json.field(k).and_then(Self::int_provider);
        let flag = |k: &str| json.get(k).map_or(Ok(false), Json::as_bool);
        let function = match json.field("type")?.as_str()? {
            "minecraft:sequence" => Function::Sequence(
                json.field("functions")?
                    .as_array()?
                    .iter()
                    .map(|f| self.function(f))
                    .collect::<Result<_, _>>()?,
            ),
            "minecraft:set_count" => Function::SetCount(int("count")?, flag("add")?),
            "minecraft:enchant_randomly" => Function::EnchantRandomly {
                options: self.enchantment_options(json.get("options"))?,
                only_compatible: json
                    .get("only_compatible")
                    .map_or(Ok(true), Json::as_bool)?,
            },
            "minecraft:enchant_with_levels" => Function::EnchantWithLevels {
                levels: int("levels")?,
                options: self.enchantment_options(json.get("options"))?,
            },
            "minecraft:set_enchantments" => Function::SetEnchantments(
                json.field("enchantments")?
                    .entries()?
                    .iter()
                    .map(|(e, level)| Ok((e.clone(), Self::int_provider(level)?)))
                    .collect::<Result<_, String>>()?,
                flag("add")?,
            ),
            "minecraft:set_damage" => {
                Function::SetDamage(Self::float_provider(json.field("damage")?)?, flag("add")?)
            }
            "minecraft:set_potion" => Function::SetPotion(json.field("id")?.as_str()?.to_string()),
            "minecraft:set_stew_effect" => Function::SetStewEffect(
                json.field("effects")?
                    .as_array()?
                    .iter()
                    .map(|e| {
                        Ok((
                            e.field("type")?.as_str()?.to_string(),
                            Self::int_provider(e.field("duration")?)?,
                        ))
                    })
                    .collect::<Result<_, String>>()?,
            ),
            "minecraft:set_ominous_bottle_amplifier" => {
                Function::SetOminousAmplifier(int("amplifier")?)
            }
            "minecraft:set_instrument" => Function::SetInstrument(
                self.holder_set("minecraft:instrument", json.field("options")?)?
                    .members,
            ),
            "minecraft:set_name" => {
                let item_name = match json.get("target") {
                    None => false,
                    Some(t) => match t.as_str()? {
                        "item_name" => true,
                        "custom_name" => false,
                        other => return Err(format!("set_name target {other}")),
                    },
                };
                if json.get("entity").is_some() {
                    return Err("set_name with an entity is not implemented".into());
                }
                match json.get("name") {
                    Some(name) => Function::SetName {
                        name: name.clone(),
                        item_name,
                    },
                    None => Function::Sequence(Vec::new()),
                }
            }
            "minecraft:filtered" => Function::Filtered {
                filter: Self::item_filter(json.field("item_filter")?)?,
                on_pass: json
                    .get("on_pass")
                    .map(|f| self.function(f).map(Box::new))
                    .transpose()?,
                on_fail: json
                    .get("on_fail")
                    .map(|f| self.function(f).map(Box::new))
                    .transpose()?,
            },
            "minecraft:discard" => Function::Discard,
            "minecraft:exploration_map" => Function::ExplorationMap {
                destination: self
                    .holder_set("minecraft:worldgen/structure", json.field("destination")?)?,
                decoration: json
                    .get("decoration")
                    .map_or(Ok("minecraft:mansion"), Json::as_str)?
                    .to_string(),
                zoom: json.get("zoom").map_or(Ok(2), Json::as_i32)?,
                radius: json.get("search_radius").map_or(Ok(50), Json::as_i32)?,
                skip_existing: json
                    .get("skip_existing_chunks")
                    .map_or(Ok(true), Json::as_bool)?,
            },
            "minecraft:enchanted_count_increase" => Function::EnchantedCountIncrease {
                enchantment: json.field("enchantment")?.as_str()?.to_string(),
                count: Self::float_provider(json.field("count")?)?,
                limit: json.get("limit").map_or(Ok(0), Json::as_i32)?,
            },
            "minecraft:furnace_smelt" => Function::FurnaceSmelt(
                json.get("use_input_count")
                    .map_or(Ok(true), Json::as_bool)?,
            ),
            other => return Err(format!("loot function {other} is not implemented")),
        };
        Ok(match json.get("condition") {
            Some(c) => Function::Conditional(Box::new(self.condition(c)?), Box::new(function)),
            None => function,
        })
    }

    fn item_filter(json: &Json) -> Result<ItemFilter, String> {
        let mut filter = ItemFilter {
            items: None,
            present: Vec::new(),
        };
        for (key, value) in json.entries()? {
            match key.as_str() {
                "items" => {
                    filter.items = Some(match value {
                        Json::String(s) => vec![s.clone()],
                        Json::Array(items) => items
                            .iter()
                            .map(|i| i.as_str().map(str::to_string))
                            .collect::<Result<_, _>>()?,
                        other => return Err(format!("item predicate items {other:?}")),
                    })
                }
                "predicates" => {
                    for (component, body) in value.entries()? {
                        if !matches!(body, Json::Object(fields) if fields.is_empty()) {
                            return Err(format!(
                                "component predicate {component} is not implemented"
                            ));
                        }
                        filter.present.push(component.clone());
                    }
                }
                other => return Err(format!("item predicate {other} is not implemented")),
            }
        }
        Ok(filter)
    }
}

impl IntProvider {
    fn get(&self, ctx: &mut Ctx) -> i32 {
        match self {
            IntProvider::Constant(v) => *v,
            IntProvider::Uniform(min, max) => {
                let (lo, hi) = (min.get(ctx), max.get(ctx));
                next_int(&mut ctx.random, lo, hi)
            }
        }
    }
}

impl FloatProvider {
    fn get(&self, ctx: &mut Ctx) -> f32 {
        match self {
            FloatProvider::Constant(v) => *v,
            FloatProvider::Uniform(min, max) => {
                let (lo, hi) = (min.get(ctx), max.get(ctx));
                if lo >= hi {
                    lo
                } else {
                    ctx.random.next_float() * (hi - lo) + lo
                }
            }
        }
    }
}

impl Condition {
    fn test(&self, ctx: &mut Ctx) -> bool {
        match self {
            Condition::RandomChance(chance) => {
                let p = chance.get(ctx);
                ctx.random.next_float() < p
            }
            Condition::Inverted(term) => !term.test(ctx),
            Condition::AllOf(terms) => terms.iter().all(|t| t.test(ctx)),
            Condition::AnyOf(terms) => terms.iter().any(|t| t.test(ctx)),
            Condition::KilledByPlayer => ctx.death.as_ref().is_some_and(|d| d.killed_by_player),
            Condition::EnchantedChance {
                enchantment,
                unenchanted,
                base,
                per_level,
            } => {
                let level = ctx
                    .death
                    .as_ref()
                    .map_or(0, |d| d.attacker_level(enchantment));
                let chance = if level > 0 {
                    base + per_level * (level - 1) as f32
                } else {
                    *unenchanted
                };
                ctx.random.next_float() < chance
            }
            Condition::Entity(target, predicate) => ctx
                .death
                .as_ref()
                .is_some_and(|d| predicate.matches(*target, d)),
            Condition::Location { biomes, offset } => {
                let pos = [
                    (ctx.origin[0] + offset[0] as f64).floor() as i32,
                    (ctx.origin[1] + offset[1] as f64).floor() as i32,
                    (ctx.origin[2] + offset[2] as f64).floor() as i32,
                ];
                match biomes {
                    None => true,
                    Some(set) => ctx
                        .world
                        .biome(pos)
                        .is_some_and(|b| set.members.contains(&b)),
                }
            }
        }
    }
}

impl Loot {
    fn info(&self, item: &str) -> ItemInfo {
        self.items.get(item).copied().unwrap_or(ItemInfo {
            max_stack: 64,
            max_damage: 0,
            damageable: false,
            enchantable: 0,
        })
    }

    fn apply(&self, f: &Function, mut stack: Stack, ctx: &mut Ctx) -> Result<Stack, String> {
        Ok(match f {
            Function::Sequence(list) => {
                for f in list {
                    stack = self.apply(f, stack, ctx)?;
                }
                stack
            }
            Function::Conditional(condition, f) => {
                if condition.test(ctx) {
                    self.apply(f, stack, ctx)?
                } else {
                    stack
                }
            }
            Function::EnchantedCountIncrease {
                enchantment,
                count,
                limit,
            } => {
                let level = match &ctx.death {
                    Some(d) if d.attacker.is_some() => d.attacker_level(enchantment),
                    _ => 0,
                };
                if level == 0 {
                    return Ok(stack);
                }
                let addition = level as f32 * count.get(ctx);
                stack.count += round_f(addition);
                if *limit > 0 && stack.count > *limit {
                    stack.count = *limit;
                }
                stack
            }
            Function::FurnaceSmelt(use_input_count) => {
                if stack.is_empty() {
                    return Ok(stack);
                }
                match self.smelting.get(&stack.item) {
                    Some(result) => {
                        let count = if *use_input_count { stack.count } else { 1 };
                        let mut smelted = Stack::new(result);
                        smelted.count = count.min(self.max_stack(result));
                        smelted
                    }
                    None => stack,
                }
            }
            Function::SetCount(count, add) => {
                let base = if *add { stack.count } else { 0 };
                stack.count = base + count.get(ctx);
                stack
            }
            Function::EnchantRandomly {
                options,
                only_compatible,
            } => {
                let book = stack.is("minecraft:book");
                let check = !book && *only_compatible;
                let all: Vec<usize> = match options {
                    Some(o) => o.clone(),
                    None => (0..self.enchantments.len()).collect(),
                };
                let candidates: Vec<usize> = all
                    .into_iter()
                    .filter(|&e| !check || self.enchantments[e].supported.contains(&stack.item))
                    .collect();
                if candidates.is_empty() {
                    return Ok(stack);
                }
                let e = &self.enchantments
                    [candidates[ctx.random.next_int_bounded(candidates.len() as i32) as usize]];
                let level = next_int(&mut ctx.random, 1, e.max_level);
                if book {
                    stack = Stack::new("minecraft:enchanted_book");
                }
                stack.enchant(&e.id, level);
                stack
            }
            Function::EnchantWithLevels { levels, options } => {
                let cost = levels.get(ctx);
                self.enchant_item(ctx, stack, cost, options.as_deref())
            }
            Function::SetEnchantments(list, add) => {
                if stack.is("minecraft:book") {
                    stack = stack.transmute("minecraft:enchanted_book");
                }
                for (e, level) in list {
                    let value = level.get(ctx);
                    let target = if *add {
                        stack.enchantment_level(e) + value
                    } else {
                        value
                    };
                    stack.set_enchantment(e, target.clamp(0, 255));
                }
                stack
            }
            Function::SetDamage(damage, add) => {
                let info = self.info(&stack.item);
                if info.damageable {
                    let max = info.max_damage;
                    let base = if *add {
                        1.0f32 - stack.damage as f32 / max as f32
                    } else {
                        0.0
                    };
                    let value = damage.get(ctx) + base;
                    let pct = 1.0f32 - crate::worldgen::java::clamp(value, 0.0, 1.0);
                    stack.damage = floor_f(pct * max as f32).clamp(0, max);
                }
                stack
            }
            Function::SetPotion(potion) => {
                stack.potion = Some(potion.clone());
                stack
            }
            Function::SetStewEffect(effects) => {
                if stack.is("minecraft:suspicious_stew") && !effects.is_empty() {
                    let (effect, duration) =
                        &effects[ctx.random.next_int_bounded(effects.len() as i32) as usize];
                    let mut d = duration.get(ctx);
                    if !self.instantaneous.contains(effect) {
                        d *= 20;
                    }
                    stack.stew_effects.push((effect.clone(), d));
                }
                stack
            }
            Function::SetOminousAmplifier(amplifier) => {
                stack.ominous_amplifier = Some(amplifier.get(ctx).clamp(0, 4));
                stack
            }
            Function::SetInstrument(options) => {
                if !options.is_empty() {
                    let pick = ctx.random.next_int_bounded(options.len() as i32) as usize;
                    stack.instrument = Some(options[pick].clone());
                }
                stack
            }
            Function::SetName { name, item_name } => {
                if *item_name {
                    stack.item_name = Some(name.clone());
                } else {
                    stack.custom_name = Some(name.clone());
                }
                stack
            }
            Function::Filtered {
                filter,
                on_pass,
                on_fail,
            } => {
                let pass = filter
                    .items
                    .as_ref()
                    .is_none_or(|items| items.contains(&stack.item))
                    && filter.present.iter().all(|c| match c.as_str() {
                        "minecraft:map_id" => stack.map_id.is_some(),
                        _ => false,
                    });
                match if pass { on_pass } else { on_fail } {
                    Some(f) => self.apply(f, stack, ctx)?,
                    None => stack,
                }
            }
            Function::Discard => Stack::empty(),
            Function::ExplorationMap {
                destination,
                decoration,
                zoom,
                radius,
                skip_existing,
            } => {
                if stack.is_empty() {
                    return Ok(stack);
                }
                let origin = [
                    ctx.origin[0].floor() as i32,
                    ctx.origin[1].floor() as i32,
                    ctx.origin[2].floor() as i32,
                ];
                let Some(found) = ctx.world.map_structure(
                    destination.tag.as_deref(),
                    &destination.members,
                    origin,
                    *radius,
                    *skip_existing,
                ) else {
                    return Ok(stack);
                };
                stack.map_id = Some(ctx.world.new_map(found[0], found[2], *zoom));
                stack.map_decorations.retain(|(k, ..)| k != "+");
                stack.map_decorations.push((
                    "+".to_string(),
                    decoration.clone(),
                    found[0] as f64,
                    found[2] as f64,
                    180.0,
                ));
                stack
            }
        })
    }

    /// `EnchantmentHelper.enchantItem`.
    fn enchant_item(
        &self,
        ctx: &mut Ctx,
        stack: Stack,
        cost: i32,
        options: Option<&[usize]>,
    ) -> Stack {
        let all: Vec<usize> = match options {
            Some(o) => o.to_vec(),
            None => (0..self.enchantments.len()).collect(),
        };
        let chosen = self.select_enchantments(ctx, &stack, cost, &all);
        let mut stack = if stack.is("minecraft:book") {
            Stack::new("minecraft:enchanted_book")
        } else {
            stack
        };
        for (e, level) in chosen {
            stack.enchant(&self.enchantments[e].id, level);
        }
        stack
    }

    /// `EnchantmentHelper.selectEnchantment`.
    fn select_enchantments(
        &self,
        ctx: &mut Ctx,
        stack: &Stack,
        cost: i32,
        source: &[usize],
    ) -> Vec<(usize, i32)> {
        let mut results = Vec::new();
        let enchantable = self.info(&stack.item).enchantable;
        if enchantable <= 0 {
            return results;
        }
        let r = &mut ctx.random;
        let mut cost = cost
            + 1
            + r.next_int_bounded(enchantable / 4 + 1)
            + r.next_int_bounded(enchantable / 4 + 1);
        let span = (r.next_float() + r.next_float() - 1.0f32) * 0.15f32;
        cost = round_f(cost as f32 + cost as f32 * span).max(1);
        let book = stack.is("minecraft:book");
        let mut available: Vec<(usize, i32)> = Vec::new();
        for &e in source {
            let def = &self.enchantments[e];
            let primary = def.supported.contains(&stack.item)
                && def.primary.as_ref().is_none_or(|p| p.contains(&stack.item));
            if !primary && !book {
                continue;
            }
            for level in (1..=def.max_level).rev() {
                if cost >= def.min_cost(level) && cost <= def.max_cost(level) {
                    available.push((e, level));
                    break;
                }
            }
        }
        if available.is_empty() {
            return results;
        }
        let pick = |r: &mut Random, list: &[(usize, i32)]| -> Option<(usize, i32)> {
            let total: i32 = list.iter().map(|(e, _)| self.enchantments[*e].weight).sum();
            if total <= 0 {
                return None;
            }
            let mut index = r.next_int_bounded(total);
            for &(e, level) in list {
                index -= self.enchantments[e].weight;
                if index < 0 {
                    return Some((e, level));
                }
            }
            None
        };
        if let Some(first) = pick(r, &available) {
            results.push(first);
        }
        while r.next_int_bounded(50) <= cost {
            if let Some(&(last, _)) = results.last() {
                let last = &self.enchantments[last];
                available.retain(|(e, _)| {
                    let other = &self.enchantments[*e];
                    other.id != last.id
                        && !last.exclusive.contains(&other.id)
                        && !other.exclusive.contains(&last.id)
                });
            }
            if available.is_empty() {
                break;
            }
            if let Some(next) = pick(r, &available) {
                results.push(next);
            }
            cost /= 2;
        }
        results
    }

    /// `LootTable.getRandomItemsRaw`: the table's pools, each item through
    /// the table's modifier as it comes (vanilla's decorated consumers).
    fn raw_items(&self, id: &str, ctx: &mut Ctx, sink: &mut Sink) -> Result<(), String> {
        if ctx.visited.iter().any(|v| v == id) {
            // Vanilla logs an infinite loop and adds nothing.
            return Ok(());
        }
        let table = self
            .tables
            .get(id)
            .ok_or_else(|| format!("unknown loot table {id}"))?;
        ctx.visited.push(id.to_string());
        let mut decorated = |stack: Stack, ctx: &mut Ctx| -> Result<(), String> {
            let stack = match &table.modifier {
                Some(f) => self.apply(f, stack, ctx)?,
                None => stack,
            };
            sink(stack, ctx)
        };
        for pool in &table.pools {
            self.pool_items(pool, ctx, &mut decorated)?;
        }
        ctx.visited.pop();
        Ok(())
    }

    fn pool_items(&self, pool: &Pool, ctx: &mut Ctx, sink: &mut Sink) -> Result<(), String> {
        if let Some(c) = &pool.condition {
            if !c.test(ctx) {
                return Ok(());
            }
        }
        let mut decorated = |stack: Stack, ctx: &mut Ctx| -> Result<(), String> {
            let stack = match &pool.modifier {
                Some(f) => self.apply(f, stack, ctx)?,
                None => stack,
            };
            sink(stack, ctx)
        };
        let rolls = pool.rolls.get(ctx);
        let bonus = pool.bonus_rolls.get(ctx);
        let count = rolls + floor_f(bonus * ctx.luck);
        for _ in 0..count {
            self.add_random_item(pool, ctx, &mut decorated)?;
        }
        Ok(())
    }

    fn weight(entry: &Entry, luck: f32) -> i32 {
        floor_f(entry.weight as f32 + entry.quality as f32 * luck).max(0)
    }

    /// `LootPoolEntryContainer.expand`: false when the entry's condition
    /// fails or (for composites) its children say so; the expanded entries
    /// it yields carry its modifier outside their own.
    fn expand<'a>(
        &'a self,
        entry: &'a Entry,
        ctx: &mut Ctx,
        outer: &[&'a Function],
        out: &mut Vec<Choice<'a>>,
    ) -> bool {
        if let Some(c) = &entry.condition {
            if !c.test(ctx) {
                return false;
            }
        }
        let mut modifiers = Vec::with_capacity(outer.len() + 1);
        modifiers.extend(entry.modifier.as_ref());
        modifiers.extend_from_slice(outer);
        let weight = Self::weight(entry, ctx.luck);
        let mut push = |leaf| {
            out.push(Choice {
                weight,
                leaf,
                modifiers: modifiers.clone(),
            })
        };
        match &entry.kind {
            EntryKind::Tables {
                tables,
                expand: true,
            } => {
                tables.iter().for_each(|t| push(Leaf::Table(t)));
                true
            }
            EntryKind::Tag {
                items,
                expand: true,
            } => {
                items.iter().for_each(|i| push(Leaf::Item(i)));
                true
            }
            EntryKind::Alternatives(children) => children
                .iter()
                .any(|c| self.expand(c, ctx, &modifiers, out)),
            EntryKind::Sequence(children) => children
                .iter()
                .all(|c| self.expand(c, ctx, &modifiers, out)),
            EntryKind::Group(children) => {
                for c in children {
                    self.expand(c, ctx, &modifiers, out);
                }
                true
            }
            _ => {
                push(Leaf::Entry(entry));
                true
            }
        }
    }

    /// `LootPool.addRandomItem`: the expanded entries with a positive weight,
    /// one picked by weight.
    fn add_random_item(&self, pool: &Pool, ctx: &mut Ctx, sink: &mut Sink) -> Result<(), String> {
        let mut expanded = Vec::new();
        for entry in &pool.entries {
            self.expand(entry, ctx, &[], &mut expanded);
        }
        let valid: Vec<Choice> = expanded.into_iter().filter(|c| c.weight > 0).collect();
        let total: i32 = valid.iter().map(|c| c.weight).sum();
        if total == 0 || valid.is_empty() {
            return Ok(());
        }
        if valid.len() == 1 {
            return self.create(&valid[0], ctx, sink);
        }
        let mut index = ctx.random.next_int_bounded(total);
        for choice in &valid {
            index -= choice.weight;
            if index < 0 {
                return self.create(choice, ctx, sink);
            }
        }
        Ok(())
    }

    /// An expanded entry's items, each through its modifiers as it comes.
    fn create(&self, choice: &Choice, ctx: &mut Ctx, sink: &mut Sink) -> Result<(), String> {
        let mut decorated = |mut stack: Stack, ctx: &mut Ctx| -> Result<(), String> {
            for f in &choice.modifiers {
                stack = self.apply(f, stack, ctx)?;
            }
            sink(stack, ctx)
        };
        match choice.leaf {
            Leaf::Item(item) => decorated(Stack::new(item), ctx),
            Leaf::Table(table) => self.raw_items(table, ctx, &mut decorated),
            Leaf::Entry(entry) => match &entry.kind {
                EntryKind::Item(item) => decorated(Stack::new(item), ctx),
                EntryKind::Empty | EntryKind::Dynamic => Ok(()),
                EntryKind::Tables { tables, .. } => {
                    for t in tables {
                        self.raw_items(t, ctx, &mut decorated)?;
                    }
                    Ok(())
                }
                EntryKind::Tag { items, .. } => {
                    for i in items {
                        decorated(Stack::new(i), ctx)?;
                    }
                    Ok(())
                }
                _ => Err("a composite entry is never picked".into()),
            },
        }
    }

    /// `LootTable.getRandomItems` through the stack splitter: stacks at
    /// their maximum size or above split into full stacks.
    fn random_items(&self, id: &str, ctx: &mut Ctx) -> Result<Vec<Stack>, String> {
        let mut out = Vec::new();
        let mut split = |stack: Stack, _: &mut Ctx| -> Result<(), String> {
            let max = self.max_stack(&stack.item);
            if stack.count < max {
                out.push(stack);
            } else {
                let mut count = stack.count;
                while count > 0 {
                    let mut copy = stack.clone();
                    copy.count = count.min(max);
                    count -= copy.count;
                    out.push(copy);
                }
            }
            Ok(())
        };
        self.raw_items(id, ctx, &mut split)?;
        Ok(out)
    }

    /// `LootTable.fill` of an empty container of `size` slots with `random`
    /// (`LegacyRandomSource(seed)` for a stored seed).
    pub fn fill(
        &self,
        id: &str,
        random: Random,
        luck: f32,
        origin: [f64; 3],
        size: usize,
        world: &mut dyn LootWorld,
    ) -> Result<Vec<Option<Stack>>, String> {
        let mut ctx = Ctx {
            random,
            luck,
            origin,
            world,
            visited: Vec::new(),
            death: None,
        };
        let mut items = self.random_items(id, &mut ctx)?;
        let random = &mut ctx.random;
        let mut slots: Vec<usize> = (0..size).collect();
        shuffle(&mut slots, random);
        self.shuffle_and_split(&mut items, slots.len(), random);
        let mut container: Vec<Option<Stack>> = vec![None; size];
        for stack in items {
            let Some(slot) = slots.pop() else {
                break;
            };
            container[slot] = (!stack.is_empty()).then_some(stack);
        }
        Ok(container)
    }

    /// `getRandomItems` with `random` (brushable blocks take the first).
    pub fn items(
        &self,
        id: &str,
        random: Random,
        luck: f32,
        origin: [f64; 3],
        world: &mut dyn LootWorld,
    ) -> Result<Vec<Stack>, String> {
        let mut ctx = Ctx {
            random,
            luck,
            origin,
            world,
            visited: Vec::new(),
            death: None,
        };
        self.random_items(id, &mut ctx)
    }

    /// An entity's death drops: `getRandomItems` with `random` and `death`,
    /// without the empty stacks.
    pub fn entity_items(
        &self,
        id: &str,
        random: Random,
        luck: f32,
        origin: [f64; 3],
        death: Death,
        world: &mut dyn LootWorld,
    ) -> Result<Vec<Stack>, String> {
        let mut ctx = Ctx {
            random,
            luck,
            origin,
            world,
            visited: Vec::new(),
            death: Some(death),
        };
        // `spawnAtLocation` drops nothing for an empty stack.
        let mut items = self.random_items(id, &mut ctx)?;
        items.retain(|s| !s.is_empty());
        Ok(items)
    }

    fn shuffle_and_split(&self, result: &mut Vec<Stack>, available: usize, random: &mut Random) {
        let mut splittable: Vec<Stack> = Vec::new();
        result.retain(|s| {
            if s.is_empty() {
                false
            } else if s.count > 1 {
                splittable.push(s.clone());
                false
            } else {
                true
            }
        });
        while available as i64 - result.len() as i64 - splittable.len() as i64 > 0
            && !splittable.is_empty()
        {
            let index = next_int(random, 0, splittable.len() as i32 - 1) as usize;
            let mut stack = splittable.remove(index);
            let remove = next_int(random, 1, stack.count / 2);
            let mut copy = stack.clone();
            copy.count = remove;
            stack.count -= remove;
            if stack.count > 1 && random.next_bool() {
                splittable.push(stack);
            } else {
                result.push(stack);
            }
            if copy.count > 1 && random.next_bool() {
                splittable.push(copy);
            } else {
                result.push(copy);
            }
        }
        result.append(&mut splittable);
        shuffle(result, random);
    }
}

/// `Util.shuffle`.
fn shuffle<T>(list: &mut [T], random: &mut Random) {
    for i in (2..=list.len()).rev() {
        let swap = random.next_int_bounded(i as i32) as usize;
        list.swap(i - 1, swap);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn java_round_half_up() {
        assert_eq!(round_f(2.5), 3);
        assert_eq!(round_f(-2.5), -2);
        assert_eq!(round_f(0.49999997), 0);
        assert_eq!(round_f(f32::NAN), 0);
        assert_eq!(round_f(7.4), 7);
    }

    #[test]
    fn next_int_of_an_empty_range_draws_nothing() {
        let mut a = Random::legacy(5);
        assert_eq!(next_int(&mut a, 3, 3), 3);
        let mut b = Random::legacy(5);
        assert_eq!(a.next_long(), b.next_long());
    }
}
