//! The families' facts: combat's (`Valimc.Protocol.CombatPackets`,
//! `Valimc.Living.Weapons`: mob sounds, experience, item attribute
//! modifiers), the hostiles' (`Valimc.Data.HostileFacts`), the animals'
//! (`Valimc.Entity.Animal`) and the villages' (`Valimc.AI.Villagers`).

use super::{
    dimensions, float_bits, hex_double, int, map, optional_string, string, strings, Context, Slot,
};
use crate::worldgen::json::Json;
use std::collections::{HashMap, HashSet};

/// A mob type's hurt and death sounds and sound source
/// (`CombatPackets.mob_sounds/1`).
#[derive(Debug, Clone, PartialEq)]
pub struct MobSounds {
    pub hurt: Option<String>,
    pub death: Option<String>,
    pub source: i32,
    pub animal: bool,
}

/// An attribute modifier an item gives (`attribute_modifiers`).
#[derive(Debug, Clone, PartialEq)]
pub struct ItemModifier {
    pub attribute: u16,
    pub id: String,
    pub amount: f64,
    /// 0 add value, 1 add multiplied base, 2 add multiplied total.
    pub operation: u8,
    pub slot: String,
}

fn operation(name: &str) -> Result<u8, String> {
    Ok(match name {
        "add_value" => 0,
        "add_multiplied_base" => 1,
        "add_multiplied_total" => 2,
        other => return Err(format!("unknown operation {other}")),
    })
}

#[derive(Debug)]
pub struct CombatFacts {
    /// By entity type id.
    pub mobs: HashMap<u16, MobSounds>,
    /// What a type combat does not model sounds like: no hurt or death sound,
    /// the neutral source.
    pub unmodelled: MobSounds,
    /// Experience a kill drops by entity type id.
    pub experience: HashMap<u16, i32>,
    /// Attribute modifiers by item id.
    pub items: HashMap<i32, Vec<ItemModifier>>,
}

impl CombatFacts {
    pub(crate) fn parse(ctx: &Context, json: &Json) -> Result<CombatFacts, String> {
        let mut mobs = HashMap::new();
        for (name, row) in json.field("mobs")?.entries()? {
            mobs.insert(
                ctx.entity(name)?,
                MobSounds {
                    hurt: optional_string(row.get("hurt_sound"))?,
                    death: optional_string(row.get("death_sound"))?,
                    source: int(row.field("sound_source")?)?,
                    animal: row.field("animal")?.as_bool()?,
                },
            );
        }
        let neutral = ctx.sounds.source("neutral").ok_or("no neutral source")?;
        let mut experience = HashMap::new();
        for (name, xp) in json.field("experience")?.entries()? {
            experience.insert(ctx.entity(name)?, int(xp)?);
        }
        let mut items = HashMap::new();
        for (name, components) in json.field("items")?.entries()? {
            let Some(modifiers) = components.get("minecraft:attribute_modifiers") else {
                continue;
            };
            let modifiers = modifiers
                .as_array()?
                .iter()
                .map(|m| {
                    Ok(ItemModifier {
                        attribute: ctx.attribute(m.field("type")?.as_str()?)?,
                        id: string(m.field("id")?)?,
                        amount: m.field("amount")?.as_f64()?,
                        operation: operation(m.field("operation")?.as_str()?)?,
                        slot: string(m.field("slot")?)?,
                    })
                })
                .collect::<Result<Vec<_>, String>>()?;
            items.insert(ctx.item(name)?, modifiers);
        }
        Ok(CombatFacts {
            mobs,
            unmodelled: MobSounds {
                hurt: None,
                death: None,
                source: neutral,
                animal: false,
            },
            experience,
            items,
        })
    }

    /// `CombatPackets.mob_sounds/1`.
    pub fn mob_sounds(&self, id: u16) -> &MobSounds {
        self.mobs.get(&id).unwrap_or(&self.unmodelled)
    }
}

/// An effect's attribute modifier (`HostileFacts.effect_modifiers/2`).
#[derive(Debug, Clone, PartialEq)]
pub struct EffectModifier {
    pub attribute: u16,
    pub id: String,
    pub operation: u8,
    /// The amounts at amplifiers 0 to 3.
    pub amounts: Vec<f64>,
}

#[derive(Debug)]
pub struct HostileFacts {
    /// Armour item ids per slot (head, chest, legs, feet) and material 0-5.
    pub armour: HashMap<Slot, Vec<i32>>,
    pub drop_chance: f32,
    /// `{min cost, max cost span, enchantment tag}`.
    pub enchanting: (i32, i32, String),
    /// Babies' `[width, height, eye height]` by entity type id.
    pub babies: HashMap<u16, [f32; 3]>,
    pub burn_period: i32,
    /// `(ticks, value)` keyframes of `monsters_burn`.
    pub burn_frames: Vec<(i32, bool)>,
    /// Item id => where it is worn, the types that may wear it (None: any)
    /// and its equip sound.
    pub equippable: HashMap<i32, (Slot, Option<Vec<u16>>, String)>,
    /// Entity type ids water and rain hurt.
    pub water_sensitive: HashSet<u16>,
    /// By effect id.
    pub effect_modifiers: HashMap<u16, Vec<EffectModifier>>,
    /// `(entity type id, effect id)` pairs `canBeAffected` refuses.
    pub effect_immunities: HashSet<(u16, i32)>,
    /// Biome name => villager type name.
    pub villager_types: HashMap<String, String>,
    pub default_villager_type: String,
    /// Villager types in network order.
    pub villager_type_ids: Vec<String>,
    /// Professions in registry order.
    pub professions: Vec<String>,
}

impl HostileFacts {
    pub(crate) fn parse(ctx: &Context, json: &Json) -> Result<HostileFacts, String> {
        let mut armour = HashMap::new();
        for (slot, items) in json.field("armour")?.entries()? {
            let items = items
                .as_array()?
                .iter()
                .map(|i| ctx.item(i.as_str()?))
                .collect::<Result<Vec<_>, _>>()?;
            armour.insert(Slot::parse(slot)?, items);
        }
        let enchanting = json.field("spawn_enchanting")?;
        let mut babies = HashMap::new();
        for (name, dims) in json.field("babies")?.entries()? {
            babies.insert(ctx.entity(name)?, dimensions(dims)?);
        }
        let burn = json.field("monsters_burn")?;
        let burn_frames = burn
            .field("keyframes")?
            .as_array()?
            .iter()
            .map(|k| Ok((int(k.field("ticks")?)?, k.field("value")?.as_bool()?)))
            .collect::<Result<Vec<_>, String>>()?;
        if burn_frames.is_empty() {
            return Err("no monsters_burn keyframes".into());
        }
        let mut equippable = HashMap::new();
        for (item, row) in json.field("equippable")?.entries()? {
            let [slot, types, sound] = row.as_array()? else {
                return Err(format!("{item}: bad equippable"));
            };
            let types = match types {
                Json::Null => None,
                t => Some(
                    t.as_array()?
                        .iter()
                        .map(|t| ctx.entity(t.as_str()?))
                        .collect::<Result<Vec<_>, _>>()?,
                ),
            };
            equippable.insert(
                ctx.item(item)?,
                (Slot::parse(slot.as_str()?)?, types, string(sound)?),
            );
        }
        let mut effect_modifiers = HashMap::new();
        for (effect, rows) in json.field("effect_modifiers")?.entries()? {
            let rows = rows
                .as_array()?
                .iter()
                .map(|r| match r.as_array()? {
                    [attribute, id, op, amounts] => Ok(EffectModifier {
                        attribute: ctx.attribute(attribute.as_str()?)?,
                        id: string(id)?,
                        operation: operation(op.as_str()?)?,
                        amounts: amounts
                            .as_array()?
                            .iter()
                            .map(hex_double)
                            .collect::<Result<_, _>>()?,
                    }),
                    _ => Err("bad effect modifier".to_string()),
                })
                .collect::<Result<Vec<_>, String>>()?;
            effect_modifiers.insert(ctx.effect(effect)?, rows);
        }
        let mut effect_immunities = HashSet::new();
        if let Some(rows) = json.get("effect_immunities") {
            for (entity, effects) in rows.entries()? {
                let entity = ctx.entity(entity)?;
                for effect in effects.as_array()? {
                    effect_immunities.insert((entity, ctx.effect(effect.as_str()?)? as i32));
                }
            }
        }
        Ok(HostileFacts {
            armour,
            drop_chance: float_bits(json.field("drop_chance")?)?,
            enchanting: (
                int(enchanting.field("min_cost")?)?,
                int(enchanting.field("max_cost_span")?)?,
                string(enchanting.field("tag")?)?,
            ),
            babies,
            burn_period: int(burn.field("period")?)?,
            burn_frames,
            equippable,
            water_sensitive: json
                .field("water_sensitive")?
                .as_array()?
                .iter()
                .map(|t| ctx.entity(t.as_str()?))
                .collect::<Result<_, _>>()?,
            effect_modifiers,
            effect_immunities,
            villager_types: map(json.field("villager_types")?, |_, t| string(t))?,
            default_villager_type: string(json.field("default_villager_type")?)?,
            villager_type_ids: strings(json.field("villager_type_ids")?)?,
            professions: strings(json.field("professions")?)?,
        })
    }

    /// `HostileFacts.armour/2`: material 0-5 of `slot`.
    pub fn armour(&self, slot: Slot, material: usize) -> Option<i32> {
        self.armour.get(&slot)?.get(material).copied()
    }

    /// `HostileFacts.monsters_burn?/1` at overworld clock `ticks`: each
    /// keyframe holds until the next, looping.
    pub fn monsters_burn(&self, ticks: i64) -> bool {
        let t = ticks.rem_euclid(self.burn_period as i64);
        let mut held = self.burn_frames.last().is_some_and(|f| f.1);
        for &(at, value) in &self.burn_frames {
            if t >= at as i64 {
                held = value;
            }
        }
        held
    }

    /// `HostileFacts.effect_modifiers/2`: `(attribute, id, amount,
    /// operation)`; past the facts' amplifiers the amount grows by the
    /// first's.
    pub fn effect_modifiers(&self, effect: u16, amplifier: i32) -> Vec<(u16, &str, f64, u8)> {
        self.effect_modifiers
            .get(&effect)
            .map(|rows| {
                rows.iter()
                    .map(|m| {
                        let amount = match usize::try_from(amplifier) {
                            Ok(a) if a < m.amounts.len() => m.amounts[a],
                            _ => m.amounts[0] * (amplifier + 1) as f64,
                        };
                        (m.attribute, m.id.as_str(), amount, m.operation)
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Whether type `entity` refuses effect `effect` (`canBeAffected`).
    pub fn immune(&self, entity: u16, effect: i32) -> bool {
        self.effect_immunities.contains(&(entity, effect))
    }

    /// `HostileFacts.villager_type/1`.
    pub fn villager_type(&self, biome: &str) -> &str {
        self.villager_types
            .get(biome)
            .unwrap_or(&self.default_villager_type)
    }
}

/// A spawn condition of a variant selector (`Animal.spawn_variant/4`).
#[derive(Debug, Clone, PartialEq)]
pub enum Condition {
    Biomes(String),
    Structures(HashSet<String>),
    /// The moon's brightness range, either end open.
    Moon(Option<f64>, Option<f64>),
}

/// A variant and its selectors `(priority, condition)`.
#[derive(Debug, Clone, PartialEq)]
pub struct Variant {
    pub name: String,
    pub selectors: Vec<(i32, Option<Condition>)>,
}

/// A sound variant's sounds: one set, or an adult's and a baby's.
#[derive(Debug, Clone, PartialEq)]
pub struct SoundVariant {
    pub adult: HashMap<String, String>,
    pub baby: Option<HashMap<String, String>>,
}

/// One animal's facts.
#[derive(Debug, Clone, PartialEq)]
pub struct AnimalFact {
    pub adult: [f32; 3],
    pub baby: [f32; 3],
    /// Sorted food item ids.
    pub food: Vec<i32>,
}

#[derive(Debug)]
pub struct AnimalFacts {
    pub group_baby_chance: f32,
    /// By entity type id: the baby chance and a baby's dimensions.
    pub water_ageable: HashMap<u16, (f32, [f32; 3])>,
    /// By entity type id.
    pub animals: HashMap<u16, AnimalFact>,
    /// Vanilla `Monster`s by entity type id.
    pub monsters: HashSet<u16>,
    /// Flower item name => `(effect id, duration)`.
    pub stew_flowers: HashMap<String, Vec<(u16, i32)>>,
    /// By variant registry.
    pub variants: HashMap<String, Vec<Variant>>,
    /// By sound variant registry, then variant.
    pub sound_variants: HashMap<String, HashMap<String, SoundVariant>>,
    /// The dye two dye colours craft (`Sheep`'s `findColorMixInRecipes`,
    /// from the crafting recipes): `(colour, colour) => colour`.
    pub sheep_mixes: HashMap<(i32, i32), i32>,
}

fn sound_set(json: &Json) -> Result<HashMap<String, String>, String> {
    map(json, |_, s| string(s))
}

impl AnimalFacts {
    pub(crate) fn parse(
        ctx: &Context,
        json: &Json,
        structure_tags: &Json,
    ) -> Result<AnimalFacts, String> {
        let mut water_ageable = HashMap::new();
        for (name, row) in json.field("water_ageable")?.entries()? {
            water_ageable.insert(
                ctx.entity(name)?,
                (
                    float_bits(row.field("baby_chance")?)?,
                    dimensions(row.field("baby")?)?,
                ),
            );
        }
        let mut animals = HashMap::new();
        for (name, row) in json.field("animals")?.entries()? {
            let mut food = row
                .field("food")?
                .as_array()?
                .iter()
                .map(|i| ctx.item(i.as_str()?))
                .collect::<Result<Vec<_>, _>>()?;
            food.sort_unstable();
            animals.insert(
                ctx.entity(name)?,
                AnimalFact {
                    adult: dimensions(row.field("adult")?)?,
                    baby: dimensions(row.field("baby")?)?,
                    food,
                },
            );
        }
        let stew_flowers = map(json.field("stew_flowers")?, |_, effects| {
            effects
                .as_array()?
                .iter()
                .map(|e| match e.as_array()? {
                    [effect, duration] => Ok((ctx.effect(effect.as_str()?)?, int(duration)?)),
                    _ => Err("bad stew effect".to_string()),
                })
                .collect()
        })?;
        let condition = |s: &Json| -> Result<Option<Condition>, String> {
            if let Some(tag) = s.get("biomes") {
                return Ok(optional_string(Some(tag))?.map(Condition::Biomes));
            }
            if let Some(tag) = s.get("structures") {
                let tag = tag.as_str()?;
                let names = structure_tags
                    .get(tag)
                    .ok_or_else(|| format!("unknown structure tag {tag}"))?;
                let names = strings(names)?.into_iter().collect();
                return Ok(Some(Condition::Structures(names)));
            }
            if let Some(moon) = s.get("moon") {
                let [min, max] = moon.as_array()? else {
                    return Err("bad moon condition".into());
                };
                let bound = |j: &Json| match j {
                    Json::Null => Ok(None),
                    j => j.as_f64().map(Some),
                };
                return Ok(Some(Condition::Moon(bound(min)?, bound(max)?)));
            }
            Err("unknown variant condition".into())
        };
        let variants = map(json.field("variants")?, |_, list| {
            list.as_array()?
                .iter()
                .map(|v| {
                    Ok(Variant {
                        name: string(v.field("name")?)?,
                        selectors: v
                            .field("selectors")?
                            .as_array()?
                            .iter()
                            .map(|s| Ok((int(s.field("priority")?)?, condition(s)?)))
                            .collect::<Result<_, String>>()?,
                    })
                })
                .collect()
        })?;
        let sound_variants = map(json.field("sound_variants")?, |_, variants| {
            map(variants, |_, v| match (v.get("adult"), v.get("baby")) {
                (Some(adult), baby) => Ok(SoundVariant {
                    adult: sound_set(adult)?,
                    baby: baby.map(sound_set).transpose()?,
                }),
                (None, _) => Ok(SoundVariant {
                    adult: sound_set(v)?,
                    baby: None,
                }),
            })
        })?;
        let mut sheep_mixes = HashMap::new();
        if let Some(mixes) = json.get("sheep_mixes") {
            for row in mixes.as_array()? {
                match row.as_array()? {
                    [a, b, Json::Null] => {
                        let _ = (int(a)?, int(b)?);
                    }
                    [a, b, m] => {
                        sheep_mixes.insert((int(a)?, int(b)?), int(m)?);
                    }
                    _ => return Err("bad sheep mix".into()),
                }
            }
        }
        Ok(AnimalFacts {
            sheep_mixes,
            group_baby_chance: float_bits(json.field("spawn_group_baby_chance")?)?,
            water_ageable,
            animals,
            monsters: json
                .field("monsters")?
                .as_array()?
                .iter()
                .map(|t| ctx.entity(t.as_str()?))
                .collect::<Result<_, _>>()?,
            stew_flowers,
            variants,
            sound_variants,
        })
    }

    /// `Animal.animal?/1`.
    pub fn animal(&self, id: u16) -> bool {
        self.animals.contains_key(&id)
    }

    /// `Animal.food?/2`.
    pub fn food(&self, id: u16, item: Option<i32>) -> bool {
        match (self.animals.get(&id), item) {
            (Some(a), Some(item)) => a.food.binary_search(&item).is_ok(),
            _ => false,
        }
    }

    /// `Animal.monster?/1`.
    pub fn monster(&self, id: u16) -> bool {
        self.monsters.contains(&id)
    }
}

/// A villager profession (`Villagers.profession/1`).
#[derive(Debug, Clone, PartialEq)]
pub struct Profession {
    pub name: String,
    pub id: i32,
    pub held: Vec<String>,
    pub acquirable: Vec<String>,
    pub secondary: Vec<String>,
    pub work_sound: Option<String>,
    /// `requestedItems` (VMC-044c2).
    pub requested: Vec<String>,
}

/// A POI type (`Villagers.poi_facts/0`).
#[derive(Debug, Clone, PartialEq)]
pub struct PoiType {
    pub states: Vec<u16>,
    pub max_tickets: i32,
    pub valid_range: i32,
    pub tags: Vec<String>,
}

/// The schedule's activities from a day tick on.
pub type Schedule = Vec<(i32, String)>;

#[derive(Debug)]
pub struct VillageFacts {
    pub poi_types: HashMap<String, PoiType>,
    /// In registry id order.
    pub professions: Vec<Profession>,
    /// Villager type name => network id.
    pub types: HashMap<String, i32>,
    pub by_biome: HashMap<String, String>,
    pub adult: Schedule,
    pub baby: Schedule,
    /// Each POI block state's type (`Pois.of_state/1`).
    pub by_state: HashMap<u16, String>,
    /// `VILLAGER_FOOD`'s nutrition by item (VMC-044c2).
    pub food: HashMap<String, i32>,
    /// `#villager_picks_up`.
    pub picks_up: Vec<String>,
}

impl VillageFacts {
    pub(crate) fn parse(json: &Json) -> Result<VillageFacts, String> {
        let poi_types = map(json.field("poi_types")?, |_, p| {
            Ok(PoiType {
                states: p
                    .field("states")?
                    .as_array()?
                    .iter()
                    .map(|s| int(s).map(|s| s as u16))
                    .collect::<Result<_, _>>()?,
                max_tickets: int(p.field("max_tickets")?)?,
                valid_range: int(p.field("valid_range")?)?,
                tags: strings(p.field("tags")?)?,
            })
        })?;
        let mut professions = json
            .field("professions")?
            .as_array()?
            .iter()
            .map(|p| {
                Ok(Profession {
                    name: string(p.field("name")?)?,
                    id: int(p.field("id")?)?,
                    held: strings(p.field("held")?)?,
                    acquirable: strings(p.field("acquirable")?)?,
                    secondary: strings(p.field("secondary_poi")?)?,
                    work_sound: optional_string(p.get("work_sound"))?,
                    requested: strings(p.field("requested_items")?)?,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        professions.sort_by_key(|p| p.id);
        let types = json
            .field("villager_types")?
            .as_array()?
            .iter()
            .map(|t| Ok((string(t.field("name")?)?, int(t.field("id")?)?)))
            .collect::<Result<_, String>>()?;
        let schedules = json.field("schedules")?.entries()?;
        let first = &schedules.first().ok_or("no villager schedules")?.1;
        if schedules.iter().any(|(_, s)| s != first) {
            return Err("villager schedules differ between dimensions".into());
        }
        let runs = |key: &str| -> Result<Schedule, String> {
            first
                .field(key)?
                .as_array()?
                .iter()
                .map(|r| match r.as_array()? {
                    [from, activity] => Ok((int(from)?, string(activity)?)),
                    _ => Err("bad schedule run".to_string()),
                })
                .collect()
        };
        let by_state = poi_types
            .iter()
            .flat_map(|(name, t): (&String, &PoiType)| {
                t.states.iter().map(move |&s| (s, name.clone()))
            })
            .collect();
        Ok(VillageFacts {
            by_state,
            poi_types,
            professions,
            types,
            by_biome: map(json.field("villager_type_by_biome")?, |_, t| string(t))?,
            adult: runs("adult")?,
            baby: runs("baby")?,
            food: match json.get("villager_food") {
                Some(f) => map(f, |_, n| int(n))?,
                None => HashMap::new(),
            },
            picks_up: match json.get("villager_picks_up") {
                Some(p) => strings(p)?,
                None => Vec::new(),
            },
        })
    }

    /// `Pois.of_state/1`: the POI type of a block state.
    pub fn poi_of_state(&self, state: u16) -> Option<&str> {
        self.by_state.get(&state).map(String::as_str)
    }

    /// `Villagers.profession/1`.
    pub fn profession(&self, name: &str) -> Option<&Profession> {
        self.professions.iter().find(|p| p.name == name)
    }

    /// `Villagers.type_of_biome/1`.
    pub fn type_of_biome(&self, biome: &str) -> &str {
        self.by_biome
            .get(biome)
            .map_or("minecraft:plains", String::as_str)
    }

    /// `Villagers.profession_for/1`: the first profession in registry order
    /// holding a job site of `poi`.
    pub fn profession_for(&self, poi: &str) -> Option<&Profession> {
        self.professions
            .iter()
            .find(|p| p.held.iter().any(|h| h == poi))
    }

    /// `Villagers.scheduled/2`: the activity at day tick `ticks`.
    pub fn scheduled(&self, ticks: i64, baby: bool) -> &str {
        let t = ticks.rem_euclid(24_000);
        let runs = if baby { &self.baby } else { &self.adult };
        runs.iter()
            .take_while(|(from, _)| *from as i64 <= t)
            .last()
            .map_or("", |(_, a)| a.as_str())
    }
}
