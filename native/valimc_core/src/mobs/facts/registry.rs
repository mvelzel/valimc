//! The registries the mob AI names things by: entity types
//! (`Valimc.Data.EntityTypes`), attributes (`Valimc.Living.Attributes`),
//! items (`Valimc.Protocol.ItemTypes`), the block registry
//! (`Valimc.Data.Blocks`), tags and the protocol registries
//! (`Valimc.Protocol.Data`), sounds, sound sources and particles
//! (`Valimc.Protocol.CombatPackets` and each family's sound table), damage
//! types (`Valimc.Protocol.DamageTypes`) and biome climates
//! (`Valimc.World.Climate`).

use super::{int, map, optional_string, string, strings};
use crate::worldgen::json::Json;
use std::collections::HashMap;

/// Names by registry id and back.
#[derive(Debug, Default)]
pub struct Names {
    pub names: Vec<String>,
    pub ids: HashMap<String, u32>,
}

impl Names {
    pub fn new(names: Vec<String>) -> Result<Names, String> {
        let ids: HashMap<String, u32> = names
            .iter()
            .enumerate()
            .map(|(i, n)| (n.clone(), i as u32))
            .collect();
        if ids.len() != names.len() {
            return Err("duplicate registry names".into());
        }
        Ok(Names { names, ids })
    }

    /// The id of `name` (with or without namespace).
    pub fn id(&self, name: &str) -> Option<u32> {
        self.ids.get(super::namespaced(name).as_ref()).copied()
    }

    pub fn name(&self, id: u32) -> Option<&str> {
        self.names.get(id as usize).map(String::as_str)
    }

    pub fn len(&self) -> usize {
        self.names.len()
    }

    pub fn is_empty(&self) -> bool {
        self.names.is_empty()
    }
}

/// One entity type's facts (`EntityTypes.fetch/1`).
#[derive(Debug, Clone)]
pub struct EntityType {
    pub name: String,
    pub id: u16,
    pub category: String,
    pub width: f64,
    pub height: f64,
    pub eye_height: f64,
    pub fire_immune: bool,
    pub summonable: bool,
    pub saved: bool,
    pub peaceful: bool,
    pub spawn_far: bool,
    pub enemy: bool,
    pub tracking_range: i32,
    pub update_interval: i32,
    pub track_deltas: bool,
    pub description: String,
    pub loot_table: Option<String>,
    pub spawn_placement: Option<String>,
    pub spawn_heightmap: Option<String>,
    /// Default attributes `(attribute name, base)` in name order; None for a
    /// type that is not living.
    pub attributes: Option<Vec<(String, f64)>>,
}

impl EntityType {
    /// `EntityTypes.living?`.
    pub fn living(&self) -> bool {
        self.attributes.is_some()
    }

    /// A default attribute's base value.
    pub fn attribute(&self, name: &str) -> Option<f64> {
        let name = super::namespaced(name);
        self.attributes
            .as_ref()?
            .iter()
            .find(|(n, _)| *n == name)
            .map(|&(_, v)| v)
    }
}

/// A mob category's spawn cap and despawn rules (`EntityTypes.category/1`).
#[derive(Debug, Clone, PartialEq)]
pub struct Category {
    pub max: i32,
    pub friendly: bool,
    pub persistent: bool,
    pub despawn_distance: i32,
    pub no_despawn_distance: i32,
}

#[derive(Debug)]
pub struct EntityTypes {
    /// By registry id.
    pub types: Vec<EntityType>,
    pub ids: HashMap<String, u16>,
    pub categories: HashMap<String, Category>,
    /// Entity data fields: `name => (index, serializer)`.
    pub fields: HashMap<String, (i32, i32)>,
}

impl EntityTypes {
    pub fn parse(json: &Json) -> Result<EntityTypes, String> {
        let mut types: Vec<Option<EntityType>> = Vec::new();
        for (name, t) in json.field("types")?.entries()? {
            let f = |k: &str| t.field(k).map_err(|e| format!("{name}: {e}"));
            let b = |k: &str| f(k)?.as_bool();
            let id = int(f("id")?)?;
            if !(0..=u16::MAX as i32).contains(&id) {
                return Err(format!("{name}: bad id"));
            }
            let attributes = match t.get("attributes") {
                None | Some(Json::Null) => None,
                Some(a) => {
                    let mut a = a
                        .entries()?
                        .iter()
                        .map(|(k, v)| v.as_f64().map(|v| (k.clone(), v)))
                        .collect::<Result<Vec<_>, _>>()?;
                    a.sort_by(|x, y| x.0.cmp(&y.0));
                    Some(a)
                }
            };
            let row = EntityType {
                name: name.clone(),
                id: id as u16,
                category: string(f("category")?)?,
                width: f("width")?.as_f64()?,
                height: f("height")?.as_f64()?,
                eye_height: f("eye_height")?.as_f64()?,
                fire_immune: b("fire_immune")?,
                summonable: b("summonable")?,
                saved: b("saved")?,
                peaceful: b("peaceful")?,
                spawn_far: b("spawn_far")?,
                enemy: b("enemy")?,
                tracking_range: int(f("tracking_range")?)?,
                update_interval: int(f("update_interval")?)?,
                track_deltas: b("track_deltas")?,
                description: string(f("description")?)?,
                loot_table: optional_string(t.get("loot_table"))?,
                spawn_placement: optional_string(t.get("spawn_placement"))?,
                spawn_heightmap: optional_string(t.get("spawn_heightmap"))?,
                attributes,
            };
            let i = id as usize;
            if types.len() <= i {
                types.resize(i + 1, None);
            }
            if types[i].replace(row).is_some() {
                return Err(format!("{name}: duplicate id"));
            }
        }
        let types = types
            .into_iter()
            .collect::<Option<Vec<_>>>()
            .ok_or("entity type ids are not contiguous")?;
        let ids = types.iter().map(|t| (t.name.clone(), t.id)).collect();
        let categories = map(json.field("categories")?, |_, c| {
            Ok(Category {
                max: int(c.field("max")?)?,
                friendly: c.field("friendly")?.as_bool()?,
                persistent: c.field("persistent")?.as_bool()?,
                despawn_distance: int(c.field("despawn_distance")?)?,
                no_despawn_distance: int(c.field("no_despawn_distance")?)?,
            })
        })?;
        let fields = map(json.field("fields")?, |_, f| {
            Ok((int(f.field("index")?)?, int(f.field("serializer")?)?))
        })?;
        Ok(EntityTypes {
            types,
            ids,
            categories,
            fields,
        })
    }

    /// The registry id of type `name` (with or without namespace).
    pub fn id(&self, name: &str) -> Option<u16> {
        self.ids.get(super::namespaced(name).as_ref()).copied()
    }

    /// `EntityTypes.fetch/1` by registry id.
    pub fn get(&self, id: u16) -> Option<&EntityType> {
        self.types.get(id as usize)
    }

    /// `EntityTypes.fetch/1` by name.
    pub fn fetch(&self, name: &str) -> Option<&EntityType> {
        self.id(name).and_then(|id| self.get(id))
    }

    pub fn name(&self, id: u16) -> Option<&str> {
        self.get(id).map(|t| t.name.as_str())
    }

    /// Every type, in registry id order.
    pub fn types(&self) -> impl Iterator<Item = &EntityType> {
        self.types.iter()
    }
}

/// An attribute's registry facts (`Attributes.fetch/1`).
#[derive(Debug, Clone, PartialEq)]
pub struct Attribute {
    pub name: String,
    pub id: u16,
    pub default: f64,
    pub min: f64,
    pub max: f64,
    pub syncable: bool,
}

#[derive(Debug)]
pub struct Attributes {
    /// By registry id.
    pub attributes: Vec<Attribute>,
    pub ids: HashMap<String, u16>,
}

impl Attributes {
    pub fn parse(json: &Json) -> Result<Attributes, String> {
        let mut attributes = json
            .entries()?
            .iter()
            .map(|(name, a)| {
                Ok(Attribute {
                    name: name.clone(),
                    id: int(a.field("id")?)? as u16,
                    default: a.field("default")?.as_f64()?,
                    min: a.field("min")?.as_f64()?,
                    max: a.field("max")?.as_f64()?,
                    syncable: a.field("syncable")?.as_bool()?,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        attributes.sort_by_key(|a| a.id);
        if attributes
            .iter()
            .enumerate()
            .any(|(i, a)| a.id as usize != i)
        {
            return Err("attribute ids are not contiguous".into());
        }
        let ids = attributes.iter().map(|a| (a.name.clone(), a.id)).collect();
        Ok(Attributes { attributes, ids })
    }

    pub fn id(&self, name: &str) -> Option<u16> {
        self.ids.get(super::namespaced(name).as_ref()).copied()
    }

    /// `Attributes.fetch/1` by name (with or without namespace).
    pub fn fetch(&self, name: &str) -> Option<&Attribute> {
        self.id(name).map(|id| &self.attributes[id as usize])
    }
}

/// Items by protocol id (`Valimc.Protocol.ItemTypes`).
#[derive(Debug)]
pub struct Items {
    pub names: Names,
    /// Per item id its maximum stack size.
    pub max_stack: Vec<i32>,
}

impl Items {
    pub fn parse(json: &Json) -> Result<Items, String> {
        let mut rows = json
            .entries()?
            .iter()
            .map(|(name, i)| {
                Ok((
                    int(i.field("id")?)?,
                    name.clone(),
                    int(i.field("max_stack_size")?)?,
                ))
            })
            .collect::<Result<Vec<_>, String>>()?;
        rows.sort();
        if rows.iter().enumerate().any(|(i, r)| r.0 as usize != i) {
            return Err("item ids are not contiguous".into());
        }
        let max_stack = rows.iter().map(|r| r.2).collect();
        let names = Names::new(rows.into_iter().map(|r| r.1).collect())?;
        Ok(Items { names, max_stack })
    }

    /// `ItemTypes.id/1`.
    pub fn id(&self, name: &str) -> Option<i32> {
        self.names.id(name).map(|id| id as i32)
    }

    pub fn name(&self, id: i32) -> Option<&str> {
        u32::try_from(id).ok().and_then(|id| self.names.name(id))
    }
}

/// One block of the registry (`Valimc.Data.Blocks`).
#[derive(Debug, Clone)]
pub struct Block {
    pub name: String,
    pub first: u16,
    pub last: u16,
    pub default: u16,
    pub class: String,
    /// Property names and values in state order.
    pub properties: Vec<(String, Vec<String>)>,
}

#[derive(Debug)]
pub struct BlockRegistry {
    pub blocks: Vec<Block>,
    pub ids: HashMap<String, u16>,
    /// Per state its block's registry id.
    pub state_blocks: Vec<u16>,
}

impl BlockRegistry {
    pub fn parse(json: &Json) -> Result<BlockRegistry, String> {
        let classes = strings(json.field("classes")?)?;
        let definitions = json
            .field("properties")?
            .as_array()?
            .iter()
            .map(|d| match d.as_array()? {
                [name, values] => Ok((string(name)?, strings(values)?)),
                _ => Err("bad property definition".to_string()),
            })
            .collect::<Result<Vec<_>, String>>()?;
        let mut blocks = Vec::new();
        let mut state_blocks = Vec::new();
        for (id, row) in json.field("blocks")?.as_array()?.iter().enumerate() {
            let [name, first, default, class, properties] = row.as_array()? else {
                return Err("bad block row".into());
            };
            let properties = properties
                .as_array()?
                .iter()
                .map(|p| {
                    definitions
                        .get(int(p)? as usize)
                        .cloned()
                        .ok_or_else(|| "bad property index".to_string())
                })
                .collect::<Result<Vec<_>, String>>()?;
            let size: usize = properties.iter().map(|(_, v)| v.len()).product();
            let first = int(first)?;
            if first as usize != state_blocks.len() {
                return Err(format!("block {id} is not contiguous"));
            }
            state_blocks.extend(std::iter::repeat_n(id as u16, size));
            blocks.push(Block {
                name: string(name)?,
                first: first as u16,
                last: (first as usize + size - 1) as u16,
                default: int(default)? as u16,
                class: classes
                    .get(int(class)? as usize)
                    .cloned()
                    .ok_or("bad block class")?,
                properties,
            });
        }
        if int(json.field("state_count")?)? as usize != state_blocks.len() {
            return Err("block registry state count differs".into());
        }
        let ids = blocks
            .iter()
            .enumerate()
            .map(|(i, b)| (b.name.clone(), i as u16))
            .collect();
        Ok(BlockRegistry {
            blocks,
            ids,
            state_blocks,
        })
    }

    /// `Blocks.block_id/1`: the block owning `state`.
    pub fn block_id(&self, state: u16) -> Option<u16> {
        self.state_blocks.get(state as usize).copied()
    }

    /// `Blocks.id/1` (a name without namespace, as the Elixir takes it, or
    /// with one).
    pub fn id(&self, name: &str) -> Option<u16> {
        let name = name.strip_prefix("minecraft:").unwrap_or(name);
        self.ids.get(name).copied()
    }

    pub fn block(&self, id: u16) -> Option<&Block> {
        self.blocks.get(id as usize)
    }

    /// Whether `state` is a state of block `name`.
    pub fn is(&self, state: u16, name: &str) -> bool {
        self.id(name)
            .is_some_and(|id| self.block_id(state) == Some(id))
    }

    /// `Blocks.default_state/1`.
    pub fn default_state(&self, name: &str) -> Option<u16> {
        self.id(name).map(|id| self.blocks[id as usize].default)
    }

    /// `Blocks.properties/1`: `(name, value)` pairs of `state` in
    /// definition order.
    pub fn properties(&self, state: u16) -> Option<Vec<(&str, &str)>> {
        let block = self.block(self.block_id(state)?)?;
        let mut rest = (state - block.first) as usize;
        let mut pairs = Vec::with_capacity(block.properties.len());
        for (name, values) in block.properties.iter().rev() {
            pairs.push((name.as_str(), values[rest % values.len()].as_str()));
            rest /= values.len();
        }
        pairs.reverse();
        Some(pairs)
    }

    /// One property's value of `state`.
    pub fn property(&self, state: u16, property: &str) -> Option<&str> {
        self.properties(state)?
            .into_iter()
            .find(|(n, _)| *n == property)
            .map(|(_, v)| v)
    }

    /// `Blocks.state/2`: block `name`'s state with `changes` applied to its
    /// default's properties.
    pub fn state(&self, name: &str, changes: &[(&str, &str)]) -> Option<u16> {
        let block = self.block(self.id(name)?)?;
        let current = self.properties(block.default)?;
        let mut offset = 0usize;
        for ((property, values), (_, value)) in block.properties.iter().zip(current) {
            let value = changes
                .iter()
                .find(|(p, _)| p == property)
                .map_or(value, |&(_, v)| v);
            let index = values.iter().position(|v| v == value)?;
            offset = offset * values.len() + index;
        }
        Some(block.first + offset as u16)
    }
}

/// Tags by registry and tag (both namespaced), as sorted registry ids
/// (`Protocol.Data.tags/0`).
#[derive(Debug, Default)]
pub struct Tags {
    pub tags: HashMap<String, HashMap<String, Vec<i32>>>,
}

impl Tags {
    pub fn parse(json: &Json) -> Result<Tags, String> {
        let tags = map(json, |_, registry| {
            map(registry, |_, ids| {
                let mut ids = ids
                    .as_array()?
                    .iter()
                    .map(int)
                    .collect::<Result<Vec<_>, _>>()?;
                ids.sort_unstable();
                ids.dedup();
                Ok(ids)
            })
        })?;
        Ok(Tags { tags })
    }

    /// The ids of tag `tag` (with or without namespace) of `registry`.
    pub fn get(&self, registry: &str, tag: &str) -> Option<&[i32]> {
        let tag = tag.strip_prefix('#').unwrap_or(tag);
        self.tags
            .get(registry)?
            .get(super::namespaced(tag).as_ref())
            .map(Vec::as_slice)
    }

    /// Whether `id` is in the tag (an unknown tag holds nothing).
    pub fn has(&self, registry: &str, tag: &str, id: i32) -> bool {
        self.get(registry, tag)
            .is_some_and(|ids| ids.binary_search(&id).is_ok())
    }
}

/// The protocol's registries by name: entries in network order
/// (`Protocol.Data.registries/0`).
#[derive(Debug, Default)]
pub struct Registries {
    pub registries: HashMap<String, Names>,
}

impl Registries {
    pub fn parse(json: &Json) -> Result<Registries, String> {
        let registries = map(json, |_, entries| Names::new(strings(entries)?))?;
        Ok(Registries { registries })
    }

    /// `Data.registry_id/2` (None: unknown).
    pub fn id(&self, registry: &str, entry: &str) -> Option<u32> {
        self.registries.get(registry)?.ids.get(entry).copied()
    }

    /// `Data.registry_name/2`.
    pub fn name(&self, registry: &str, id: u32) -> Option<&str> {
        self.registries.get(registry)?.name(id)
    }

    pub fn get(&self, registry: &str) -> Option<&Names> {
        self.registries.get(registry)
    }
}

/// Sound events, sound sources and particles by protocol id. One table for
/// the AI's, the families' and combat's sounds: their files agree on every
/// name they share (checked at install).
#[derive(Debug, Default)]
pub struct Sounds {
    pub sounds: HashMap<String, i32>,
    pub sources: HashMap<String, i32>,
    pub particles: HashMap<String, i32>,
}

impl Sounds {
    /// Combat's tables, then each named source's `sounds`.
    pub fn parse(combat: &Json, others: &[(&str, &Json)]) -> Result<Sounds, String> {
        let ids = |j: &Json| map(j, |_, v| int(v));
        let mut sounds = ids(combat.field("sounds")?)?;
        for (source, table) in others {
            for (name, id) in ids(table)? {
                match sounds.insert(name.clone(), id) {
                    Some(old) if old != id => {
                        return Err(format!("{source} sound {name}: {id} differs from {old}"))
                    }
                    _ => {}
                }
            }
        }
        Ok(Sounds {
            sounds,
            sources: ids(combat.field("sound_sources")?)?,
            particles: ids(combat.field("particles")?)?,
        })
    }

    /// The protocol id of sound event `name` (`Facts.sound_id/1` and each
    /// family's `sound_id/1`).
    pub fn id(&self, name: &str) -> Option<i32> {
        self.sounds.get(name).copied()
    }

    /// `CombatPackets.source/1`.
    pub fn source(&self, name: &str) -> Option<i32> {
        self.sources.get(name).copied()
    }

    /// `CombatPackets.particle_id/1`.
    pub fn particle(&self, name: &str) -> Option<i32> {
        self.particles.get(name).copied()
    }
}

/// A damage type (`Valimc.Protocol.DamageTypes`, `combat_facts`'s
/// `damage_types`).
#[derive(Debug, Clone, PartialEq)]
pub struct DamageType {
    pub name: String,
    pub message_id: String,
    pub scaling: String,
}

#[derive(Debug, Default)]
pub struct DamageTypes {
    /// By registry id.
    pub types: Vec<DamageType>,
    pub ids: HashMap<String, u16>,
}

impl DamageTypes {
    pub fn parse(registries: &Registries, facts: &Json) -> Result<DamageTypes, String> {
        let names = registries
            .get("minecraft:damage_type")
            .ok_or("no damage type registry")?;
        let types = names
            .names
            .iter()
            .map(|name| {
                let row = facts.field(name)?;
                Ok(DamageType {
                    name: name.clone(),
                    message_id: string(row.field("message_id")?)?,
                    scaling: string(row.field("scaling")?)?,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        let ids = types
            .iter()
            .enumerate()
            .map(|(i, t)| (t.name.clone(), i as u16))
            .collect();
        Ok(DamageTypes { types, ids })
    }

    /// `DamageTypes.id/1` (with or without namespace).
    pub fn id(&self, name: &str) -> Option<u16> {
        self.ids.get(super::namespaced(name).as_ref()).copied()
    }
}

/// A biome's climate (`Worldgen.Facts.biome_climates/0`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Climate {
    pub temperature: f64,
    pub frozen: bool,
    pub precipitation: bool,
}

/// Climates by biome registry id from `[name, temperature, frozen,
/// precipitation]` rows; every biome of the registry has one.
pub fn climates(registries: &Registries, json: &Json) -> Result<Vec<Climate>, String> {
    let biomes = registries
        .get("minecraft:worldgen/biome")
        .ok_or("no biome registry")?;
    let mut out = vec![None; biomes.len()];
    for row in json.as_array()? {
        let [name, temperature, frozen, precipitation] = row.as_array()? else {
            return Err("bad climate row".into());
        };
        let id = biomes
            .id(name.as_str()?)
            .ok_or_else(|| format!("unknown biome {name:?}"))?;
        out[id as usize] = Some(Climate {
            temperature: temperature.as_f64()?,
            frozen: frozen.as_bool()?,
            precipitation: precipitation.as_bool()?,
        });
    }
    out.into_iter()
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| "climates do not cover the biome registry".into())
}
