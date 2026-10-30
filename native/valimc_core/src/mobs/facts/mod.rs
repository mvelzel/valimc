//! The facts native mob AI reads (VMC-081d), installed once per VM from the
//! same generated files the Elixir AI decodes (`Valimc.AI.NativeFacts`
//! hands their decoded JSON over): the registries (entity types, attributes,
//! effects, items, blocks, tags, the protocol registries, sounds, damage
//! types, biome climates), the AI facts and the families' facts (combat,
//! hostiles, animals, villages). Each accessor mirrors one Elixir accessor;
//! values are decoded as the Elixir decodes them (a hex double, the bits of a
//! float), so both read the same numbers.
//!
//! The per-state block facts (flags, fluids, collision shapes) are the block
//! fact table's (`crate::facts`, `crate::physics::facts`), installed by
//! `Valimc.Data.BlockFacts.install!`; `mobs::level` reads them there.

pub mod ai;
pub mod families;
pub mod outlines;
pub mod registry;

pub use ai::AiFacts;
pub use families::{AnimalFacts, CombatFacts, HostileFacts, VillageFacts};
pub use registry::{
    Attributes, BlockRegistry, Climate, DamageTypes, EntityTypes, Items, Names, Registries, Sounds,
    Tags,
};

use crate::worldgen::json::Json;
use std::collections::HashMap;

/// Every fact table the mob AI reads.
#[derive(Debug)]
pub struct MobFacts {
    pub entities: EntityTypes,
    pub attributes: Attributes,
    /// Status effects by registry id (`Valimc.Data.EffectTypes`).
    pub effects: Names,
    pub items: Items,
    pub blocks: BlockRegistry,
    pub tags: Tags,
    pub registries: Registries,
    pub sounds: Sounds,
    pub damage_types: DamageTypes,
    /// Each biome's climate by biome registry id (`Valimc.World.Climate`).
    pub climates: Vec<Climate>,
    pub ai: AiFacts,
    pub combat: CombatFacts,
    pub hostile: HostileFacts,
    pub animal: AnimalFacts,
    pub village: VillageFacts,
    /// Block outline shapes (`Valimc.Physics.Clip`'s), where given.
    pub outlines: outlines::Outlines,
    /// Potions by registry id (`Valimc.Data.PotionTypes`), where given.
    pub potions: Vec<Potion>,
    /// Consumable items' defaults by item id (`Valimc.Living.FoodItems`),
    /// where given.
    pub food: HashMap<i32, FoodItem>,
    /// The ender dragon's facts (`dragon_facts.json`), where given.
    pub dragon: Option<crate::mobs::boss::dragon::DragonFacts>,
}

/// An item's consumable defaults (`FoodItems.defaults/1`): its
/// `minecraft:consumable` component (None: not consumable), its use
/// remainder `(item id, count)` and the consume listeners beside it.
#[derive(Clone, Debug, PartialEq)]
pub struct FoodItem {
    pub consumable: Option<Consumable>,
    pub remainder: Option<(i32, i32)>,
    pub other_listeners: Vec<String>,
}

/// `minecraft:consumable` as `FoodItems` keeps it.
#[derive(Clone, Debug, PartialEq)]
pub struct Consumable {
    pub ticks: i32,
    pub animation: String,
    pub sound: String,
    /// The number of its consume effects.
    pub effects: i32,
}

fn food(json: &Json) -> Result<HashMap<i32, FoodItem>, String> {
    json.entries()?
        .iter()
        .map(|(_, row)| {
            let id = row.field("item_id")?.as_i32()?;
            let consumable = match row.get("consumable") {
                None | Some(Json::Null) => None,
                Some(c) => Some(Consumable {
                    ticks: c.field("ticks")?.as_i32()?,
                    animation: c.field("animation")?.as_str()?.to_owned(),
                    sound: c.field("sound")?.as_str()?.to_owned(),
                    effects: c.field("effects")?.as_i32()?,
                }),
            };
            let remainder = match row.get("remainder") {
                None | Some(Json::Null) => None,
                Some(r) => Some((r.field("item_id")?.as_i32()?, r.field("count")?.as_i32()?)),
            };
            let other_listeners = row
                .field("other_listeners")?
                .as_array()?
                .iter()
                .map(|l| l.as_str().map(str::to_owned))
                .collect::<Result<_, _>>()?;
            Ok((
                id,
                FoodItem {
                    consumable,
                    remainder,
                    other_listeners,
                },
            ))
        })
        .collect()
}

/// A potion (`Valimc.Data.PotionTypes`): its name and each effect's rungs.
#[derive(Clone, Debug, PartialEq)]
pub struct Potion {
    pub name: String,
    pub effects: Vec<(i32, Vec<crate::mobs::model::Rung>)>,
}

impl MobFacts {
    /// `PotionTypes.id/1` of a namespaced name.
    pub fn potion(&self, name: &str) -> Option<i32> {
        self.potions
            .iter()
            .position(|p| p.name == name)
            .map(|i| i as i32)
    }
}

fn potions(json: &Json) -> Result<Vec<Potion>, String> {
    let mut rows = json
        .field("potions")?
        .as_array()?
        .iter()
        .map(|row| {
            let id = row.field("id")?.as_f64()? as usize;
            let effects = row
                .field("effects")?
                .as_array()?
                .iter()
                .map(|e| {
                    let rungs = e
                        .field("rungs")?
                        .as_array()?
                        .iter()
                        .map(|r| match r.as_array()? {
                            [ticks, amplifier, ambient, particles, icon] => {
                                Ok(crate::mobs::model::Rung {
                                    ticks: ticks.as_f64()? as i32,
                                    amplifier: amplifier.as_f64()? as u8,
                                    ambient: ambient.as_bool()?,
                                    particles: particles.as_bool()?,
                                    icon: icon.as_bool()?,
                                })
                            }
                            _ => Err("a rung needs five fields".to_string()),
                        })
                        .collect::<Result<Vec<_>, String>>()?;
                    Ok((e.field("id")?.as_f64()? as i32, rungs))
                })
                .collect::<Result<Vec<_>, String>>()?;
            let name = row.field("name")?.as_str()?.to_owned();
            Ok((id, Potion { name, effects }))
        })
        .collect::<Result<Vec<_>, String>>()?;
    rows.sort_by_key(|(id, _)| *id);
    if rows.iter().enumerate().any(|(i, (id, _))| i != *id) {
        return Err("potion ids are not contiguous".into());
    }
    Ok(rows.into_iter().map(|(_, p)| p).collect())
}

impl MobFacts {
    /// The facts from the installer's map (`Valimc.AI.NativeFacts.facts/0`):
    /// `ai`, `entities`, `effects`, `hostile`, `animal`, `village`, `combat`,
    /// `attributes`, `items`, `blocks`, `tags`, `registries`, `climates`,
    /// `structure_tags`, `outlines`, `potions`, `food_items` and `dragon`
    /// (optional), each the decoded JSON of its file (or the part of it the
    /// AI reads).
    pub fn parse(json: &Json) -> Result<MobFacts, String> {
        let at = |key: &str| json.field(key).map_err(|e| format!("mob facts: {e}"));
        let registries = Registries::parse(at("registries")?)?;
        let tags = Tags::parse(at("tags")?)?;
        let entities = EntityTypes::parse(at("entities")?)?;
        let attributes = Attributes::parse(at("attributes")?)?;
        let effects = Names::new(
            at("effects")?
                .as_array()?
                .iter()
                .map(|n| n.as_str().map(str::to_owned))
                .collect::<Result<_, _>>()?,
        )?;
        let items = Items::parse(at("items")?)?;
        let blocks = BlockRegistry::parse(at("blocks")?)?;
        let ai_json = at("ai")?;
        let combat_json = at("combat")?;
        let hostile_json = at("hostile")?;
        let animal_json = at("animal")?;
        let village_json = at("village")?;
        let sounds = Sounds::parse(
            combat_json,
            &[
                ("ai", ai_json.field("sounds")?),
                ("hostile", hostile_json.field("sounds")?),
                ("animal", animal_json.field("sounds")?),
                ("village", village_json.field("sounds")?),
            ],
        )?;
        let damage_types = DamageTypes::parse(&registries, combat_json.field("damage_types")?)?;
        let climates = registry::climates(&registries, at("climates")?)?;
        let ctx = Context {
            entities: &entities,
            attributes: &attributes,
            effects: &effects,
            items: &items,
            sounds: &sounds,
        };
        let ai = AiFacts::parse(&ctx, ai_json)?;
        let combat = CombatFacts::parse(&ctx, combat_json)?;
        let hostile = HostileFacts::parse(&ctx, hostile_json)?;
        let animal = AnimalFacts::parse(&ctx, animal_json, at("structure_tags")?)?;
        let village = VillageFacts::parse(village_json)?;
        let outlines = match json.field("outlines") {
            Ok(o) => outlines::Outlines::parse(o)?,
            Err(_) => outlines::Outlines::default(),
        };
        let potions = match json.field("potions") {
            Ok(p) => potions(p)?,
            Err(_) => Vec::new(),
        };
        let food = match json.field("food_items") {
            Ok(f) => food(f)?,
            Err(_) => HashMap::new(),
        };
        let dragon = match json.field("dragon") {
            Ok(d) => Some(crate::mobs::boss::dragon::DragonFacts::parse(d)?),
            Err(_) => None,
        };
        Ok(MobFacts {
            dragon,
            food,
            potions,
            outlines,
            entities,
            attributes,
            effects,
            items,
            blocks,
            tags,
            registries,
            sounds,
            damage_types,
            climates,
            ai,
            combat,
            hostile,
            animal,
            village,
        })
    }

    /// `EntityTypes.tag?(type, tag)`: entity type `id` is in tag `tag`
    /// (namespaced).
    pub fn entity_tag(&self, id: u16, tag: &str) -> bool {
        self.tags.has("minecraft:entity_type", tag, id as i32)
    }

    /// `Animal.biome_in?(biome, tag)`: biome registry id `biome` (None:
    /// unknown) is in biome tag `tag`.
    pub fn biome_in(&self, biome: Option<u16>, tag: &str) -> bool {
        biome.is_some_and(|b| self.tags.has("minecraft:worldgen/biome", tag, b as i32))
    }

    /// Whether item `id` is in item tag `tag`.
    pub fn item_tag(&self, id: i32, tag: &str) -> bool {
        self.tags.has("minecraft:item", tag, id)
    }

    /// Whether block registry id `id` is in block tag `tag`.
    pub fn block_tag(&self, id: u16, tag: &str) -> bool {
        self.tags.has("minecraft:block", tag, id as i32)
    }

    /// `DamageTypes.tag?(type, tag)` over a damage type's registry id.
    pub fn damage_tag(&self, id: u16, tag: &str) -> bool {
        self.tags.has("minecraft:damage_type", tag, id as i32)
    }
}

/// What the family parsers resolve names through.
pub(crate) struct Context<'a> {
    pub entities: &'a EntityTypes,
    pub attributes: &'a Attributes,
    pub effects: &'a Names,
    pub items: &'a Items,
    pub sounds: &'a Sounds,
}

impl Context<'_> {
    pub fn entity(&self, name: &str) -> Result<u16, String> {
        self.entities
            .id(name)
            .ok_or_else(|| format!("unknown entity type {name}"))
    }

    pub fn item(&self, name: &str) -> Result<i32, String> {
        self.items
            .id(name)
            .ok_or_else(|| format!("unknown item {name}"))
    }

    pub fn effect(&self, name: &str) -> Result<u16, String> {
        self.effects
            .id(name)
            .map(|id| id as u16)
            .ok_or_else(|| format!("unknown effect {name}"))
    }

    pub fn attribute(&self, name: &str) -> Result<u16, String> {
        self.attributes
            .id(name)
            .ok_or_else(|| format!("unknown attribute {name}"))
    }
}

/// An equipment slot as the facts name them (`EquipmentSlot`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Slot {
    MainHand,
    OffHand,
    Feet,
    Legs,
    Chest,
    Head,
    Body,
    Saddle,
}

impl Slot {
    pub fn parse(name: &str) -> Result<Slot, String> {
        Ok(match name {
            "mainhand" => Slot::MainHand,
            "offhand" => Slot::OffHand,
            "feet" => Slot::Feet,
            "legs" => Slot::Legs,
            "chest" => Slot::Chest,
            "head" => Slot::Head,
            "body" => Slot::Body,
            "saddle" => Slot::Saddle,
            other => return Err(format!("unknown equipment slot {other}")),
        })
    }
}

/// A Java float from the signed 32-bit integer of its bits
/// (`<<f::float-32>> = <<bits::signed-32>>`).
pub(crate) fn float_bits(json: &Json) -> Result<f32, String> {
    let n = json.as_f64()?;
    if n.fract() != 0.0 || n < i32::MIN as f64 || n > i32::MAX as f64 {
        return Err(format!("expected float bits, got {n}"));
    }
    Ok(f32::from_bits(n as i32 as u32))
}

/// Three float bits: a width, height and eye height.
pub(crate) fn dimensions(json: &Json) -> Result<[f32; 3], String> {
    let v = json.as_array()?;
    if v.len() != 3 {
        return Err("expected three dimensions".into());
    }
    Ok([float_bits(&v[0])?, float_bits(&v[1])?, float_bits(&v[2])?])
}

/// A big-endian double from 16 hex digits (`Base.decode16!` then
/// `<<v::float-64>>`).
pub(crate) fn hex_double(json: &Json) -> Result<f64, String> {
    let s = json.as_str()?;
    if s.len() != 16 {
        return Err(format!("expected 16 hex digits, got {s}"));
    }
    u64::from_str_radix(s, 16)
        .map(f64::from_bits)
        .map_err(|e| format!("{s}: {e}"))
}

/// Bytes from lowercase hex.
pub(crate) fn hex_bytes(json: &Json) -> Result<Vec<u8>, String> {
    let s = json.as_str()?;
    if !s.len().is_multiple_of(2) {
        return Err("odd hex length".into());
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|e| format!("{s}: {e}")))
        .collect()
}

pub(crate) fn int(json: &Json) -> Result<i32, String> {
    json.as_i32()
}

pub(crate) fn string(json: &Json) -> Result<String, String> {
    json.as_str().map(str::to_owned)
}

/// A string, or None for JSON null.
pub(crate) fn optional_string(json: Option<&Json>) -> Result<Option<String>, String> {
    match json {
        None | Some(Json::Null) => Ok(None),
        Some(j) => string(j).map(Some),
    }
}

pub(crate) fn strings(json: &Json) -> Result<Vec<String>, String> {
    json.as_array()?.iter().map(string).collect()
}

/// An object's entries mapped by `f`.
pub(crate) fn map<T>(
    json: &Json,
    mut f: impl FnMut(&str, &Json) -> Result<T, String>,
) -> Result<HashMap<String, T>, String> {
    json.entries()?
        .iter()
        .map(|(k, v)| {
            f(k, v)
                .map(|t| (k.clone(), t))
                .map_err(|e| format!("{k}: {e}"))
        })
        .collect()
}

/// `name` with the `minecraft:` namespace (Elixir accessors take either).
pub fn namespaced(name: &str) -> std::borrow::Cow<'_, str> {
    if name.contains(':') {
        std::borrow::Cow::Borrowed(name)
    } else {
        std::borrow::Cow::Owned(format!("minecraft:{name}"))
    }
}

#[cfg(test)]
pub(crate) mod tests;
