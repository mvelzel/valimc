//! The block registry as decoration reads it (VMC-025): blocks with their
//! state runs and properties (`priv/registry/blocks.json`), block and fluid
//! tags, and per state the block fact table's flags, fluid and heightmap
//! predicates (`crate::facts`, VMC-077d).

use std::collections::HashMap;

use super::json::Json;
use crate::facts::{StateFacts, FLAMMABLE};

/// Worldgen flags per state: the block fact table's flag bits 0..31.
pub const AIR: u32 = 1;
pub const REPLACEABLE: u32 = 1 << 1;
pub const SOLID: u32 = 1 << 2;
pub const BLOCK_ENTITY: u32 = 1 << 3;
pub const POST_PROCESS: u32 = 1 << 4;
/// Sturdy full face, shifted by the direction's index (down, up, north,
/// south, west, east).
pub const STURDY: u32 = 1 << 5;
pub const LIQUID_BLOCK: u32 = 1 << 11;
/// `BlockState.liquid()`.
pub const LIQUID: u32 = 1 << 12;
pub const DOUBLE_PLANT: u32 = 1 << 13;
pub const MOSSY_CARPET: u32 = 1 << 14;
/// A post-processing position above the block (soul sand, magma).
pub const POST_PROCESS_ABOVE: u32 = 1 << 15;
pub const SOLID_RENDER: u32 = 1 << 16;
/// A full collision face, shifted by the direction's index.
pub const COLLISION_FULL: u32 = 1 << 17;
/// `isCollisionShapeFullBlock`.
pub const FULL_COLLISION: u32 = 1 << 23;
/// A full face occlusion shape, shifted by the direction's index.
pub const OCCLUDES: u32 = 1 << 24;
/// A `LiquidBlockContainer`, and a `SimpleWaterloggedBlock`.
pub const LIQUID_CONTAINER: u32 = 1 << 30;
pub const SIMPLE_WATERLOGGED: u32 = 1 << 31;

/// The second word of worldgen flags per state (VMC-025f).
/// A full outline shape (`Block.isShapeFullBlock` of `getShape`).
pub const FULL_SHAPE: u32 = 1;
/// A sturdy centre on the bottom face (`SupportType.CENTER`).
pub const CENTER_SUPPORT_DOWN: u32 = 1 << 1;
/// A `FallingBlock`.
pub const FALLING: u32 = 1 << 2;
/// `isRedstoneConductor`.
pub const REDSTONE_CONDUCTOR: u32 = 1 << 3;
/// `isSignalSource`.
pub const SIGNAL_SOURCE: u32 = 1 << 4;
/// The bottom face of the collision shape covers a wall's post test shape;
/// then its north, east, south and west side test shapes.
pub const COVERS_WALL_POST: u32 = 1 << 5;
pub const COVERS_WALL_SIDE: u32 = 1 << 6;
/// `Block.isExceptionForConnection`.
pub const CONNECTION_EXCEPTION: u32 = 1 << 10;
/// Block classes: `IronBarsBlock` (bars and panes), `StairBlock`,
/// `FenceGateBlock`, `WallBlock`, `FenceBlock`.
pub const IRON_BARS: u32 = 1 << 11;
pub const STAIRS: u32 = 1 << 12;
pub const FENCE_GATE: u32 = 1 << 13;
pub const WALL: u32 = 1 << 14;
pub const FENCE: u32 = 1 << 15;
pub const DOOR: u32 = 1 << 16;

/// Fluid registry ids.
pub const FLUID_EMPTY: u8 = 0;
pub const FLUID_FLOWING_WATER: u8 = 1;
pub const FLUID_WATER: u8 = 2;
pub const FLUID_FLOWING_LAVA: u8 = 3;
pub const FLUID_LAVA: u8 = 4;
pub const FLUID_NAMES: [&str; 5] = [
    "minecraft:empty",
    "minecraft:flowing_water",
    "minecraft:water",
    "minecraft:flowing_lava",
    "minecraft:lava",
];

/// Heightmap types, in vanilla's order (bits of a state's heightmap mask).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Heightmap {
    WorldSurfaceWg = 0,
    WorldSurface = 1,
    OceanFloorWg = 2,
    OceanFloor = 3,
    MotionBlocking = 4,
    MotionBlockingNoLeaves = 5,
}

impl Heightmap {
    pub const ALL: [Heightmap; 6] = [
        Heightmap::WorldSurfaceWg,
        Heightmap::WorldSurface,
        Heightmap::OceanFloorWg,
        Heightmap::OceanFloor,
        Heightmap::MotionBlocking,
        Heightmap::MotionBlockingNoLeaves,
    ];

    pub fn parse(name: &str) -> Result<Heightmap, String> {
        Ok(match name {
            "WORLD_SURFACE_WG" => Heightmap::WorldSurfaceWg,
            "WORLD_SURFACE" => Heightmap::WorldSurface,
            "OCEAN_FLOOR_WG" => Heightmap::OceanFloorWg,
            "OCEAN_FLOOR" => Heightmap::OceanFloor,
            "MOTION_BLOCKING" => Heightmap::MotionBlocking,
            "MOTION_BLOCKING_NO_LEAVES" => Heightmap::MotionBlockingNoLeaves,
            other => return Err(format!("unknown heightmap {other}")),
        })
    }
}

/// A set of blocks (a holder set: one block, a list or a tag).
#[derive(Clone, Debug, Default)]
pub struct BlockSet(Vec<u64>);

impl BlockSet {
    pub fn from_blocks(blocks: impl IntoIterator<Item = u16>) -> Self {
        let mut words = Vec::new();
        for b in blocks {
            let word = b as usize / 64;
            if words.len() <= word {
                words.resize(word + 1, 0);
            }
            words[word] |= 1 << (b % 64);
        }
        BlockSet(words)
    }

    pub fn contains(&self, block: u16) -> bool {
        self.0
            .get(block as usize / 64)
            .is_some_and(|w| w & (1 << (block % 64)) != 0)
    }
}

/// A block's properties: name and values, in state order.
#[derive(Clone, Debug)]
pub struct Property {
    pub name: String,
    pub values: Vec<String>,
}

#[derive(Debug)]
pub struct BlockTable {
    /// Per block: its name with namespace, first and default state, class
    /// and properties (the last varies fastest within its states).
    pub names: Vec<String>,
    pub ids: HashMap<String, u16>,
    pub first: Vec<u16>,
    pub default: Vec<u16>,
    pub class: Vec<u16>,
    pub classes: Vec<String>,
    pub properties: Vec<Vec<Property>>,
    /// Per state.
    pub block_of: Vec<u16>,
    pub flags: Vec<u32>,
    /// The second flag word (`FULL_SHAPE`, …): the table's flag bits 32..48.
    pub flags2: Vec<u32>,
    /// Per block, the block entity type it creates.
    pub block_entity_types: Vec<Option<&'static str>>,
    pub fluid: Vec<u8>,
    /// Fluid amount (0..8) and the falling flag (bit 4).
    pub fluid_level: Vec<u8>,
    /// What base block removal leaves (the state's fluid as a block).
    pub remains: Vec<u16>,
    /// The redstone signals (`StateFacts::signal`).
    signal: Vec<u64>,
    pub heightmaps: Vec<u8>,
    /// States fire can burn (`FireBlock.canBurn`), a bit per state.
    flammable: Vec<u64>,
    tags: HashMap<String, BlockSet>,
    /// Each block tag's blocks in vanilla's order (a holder set's contents).
    tag_lists: HashMap<String, Vec<u16>>,
    fluid_tags: HashMap<String, Vec<u8>>,
}

impl BlockTable {
    /// `registry` is `priv/registry/blocks.json`; `facts` holds the tags and
    /// block entity types Elixir passes (`block_tags`, `fluid_tags`,
    /// `block_entity_types`); `states` is the installed per-state facts.
    pub fn parse(registry: &Json, facts: &Json, states: &StateFacts) -> Result<BlockTable, String> {
        let count = registry.field("state_count")?.as_i32()? as usize;
        if states.state_count() != count {
            return Err("block facts and the block registry differ in state count".into());
        }
        let definitions: Vec<Property> = registry
            .field("properties")?
            .as_array()?
            .iter()
            .map(|p| {
                let [name, values] = p.as_array()? else {
                    return Err("property definition".to_string());
                };
                Ok(Property {
                    name: name.as_str()?.to_string(),
                    values: values
                        .as_array()?
                        .iter()
                        .map(|v| v.as_str().map(str::to_string))
                        .collect::<Result<_, _>>()?,
                })
            })
            .collect::<Result<_, String>>()?;
        let classes = registry
            .field("classes")?
            .as_array()?
            .iter()
            .map(|c| c.as_str().map(str::to_string))
            .collect::<Result<Vec<_>, _>>()?;
        let mut table = BlockTable {
            names: Vec::new(),
            ids: HashMap::new(),
            first: Vec::new(),
            default: Vec::new(),
            class: Vec::new(),
            classes,
            properties: Vec::new(),
            block_of: vec![0; count],
            flags: states.flags.iter().map(|&f| f as u32).collect(),
            flags2: states
                .flags
                .iter()
                .map(|&f| (f >> 32) as u32 & 0x1_ffff)
                .collect(),
            block_entity_types: Vec::new(),
            fluid: states.fluid.clone(),
            fluid_level: states.fluid_level.clone(),
            remains: states.remains.clone(),
            signal: states.signal.clone(),
            heightmaps: states.heightmaps.clone(),
            flammable: vec![0; count.div_ceil(64)],
            tags: HashMap::new(),
            tag_lists: HashMap::new(),
            fluid_tags: HashMap::new(),
        };
        for (id, row) in registry.field("blocks")?.as_array()?.iter().enumerate() {
            let [name, first, default, class, properties] = row.as_array()? else {
                return Err("block row".into());
            };
            let properties: Vec<Property> = properties
                .as_array()?
                .iter()
                .map(|p| Ok(definitions[p.as_i32()? as usize].clone()))
                .collect::<Result<_, String>>()?;
            let size: usize = properties.iter().map(|p| p.values.len()).product();
            let first = first.as_i32()? as usize;
            for state in first..first + size {
                table.block_of[state] = id as u16;
            }
            let name = format!("minecraft:{}", name.as_str()?);
            table.ids.insert(name.clone(), id as u16);
            table.names.push(name);
            table.first.push(first as u16);
            table.default.push(default.as_i32()? as u16);
            table.class.push(class.as_i32()? as u16);
            table.properties.push(properties);
        }
        for (state, &flags) in states.flags.iter().enumerate() {
            if flags & FLAMMABLE != 0 {
                table.flammable[state / 64] |= 1 << (state % 64);
            }
        }
        for (tag, blocks) in facts.field("block_tags")?.entries()? {
            let blocks = blocks
                .as_array()?
                .iter()
                .map(|b| b.as_i32().map(|b| b as u16))
                .collect::<Result<Vec<_>, _>>()?;
            table
                .tags
                .insert(tag.clone(), BlockSet::from_blocks(blocks.iter().copied()));
            table.tag_lists.insert(tag.clone(), blocks);
        }
        for (tag, fluids) in facts.field("fluid_tags")?.entries()? {
            let fluids = fluids
                .as_array()?
                .iter()
                .map(|f| f.as_i32().map(|f| f as u8))
                .collect::<Result<Vec<_>, _>>()?;
            table.fluid_tags.insert(tag.clone(), fluids);
        }
        table.block_entity_types = vec![None; table.names.len()];
        if let Some(types @ Json::Object(_)) = facts.get("block_entity_types") {
            for (block, kind) in types.entries()? {
                if let Some(&id) = table.ids.get(block) {
                    table.block_entity_types[id as usize] =
                        Some(super::region::entity_kind(kind.as_str()?));
                }
            }
        }
        Ok(table)
    }

    pub fn block(&self, name: &str) -> Result<u16, String> {
        let name = if name.contains(':') {
            name.to_string()
        } else {
            format!("minecraft:{name}")
        };
        self.ids
            .get(&name)
            .copied()
            .ok_or_else(|| format!("unknown block {name}"))
    }

    pub fn default_state(&self, name: &str) -> Result<u16, String> {
        Ok(self.default[self.block(name)? as usize])
    }

    /// A block's default state, by block id.
    pub fn default_state_of(&self, block: u16) -> u16 {
        self.default[block as usize]
    }

    /// The names of a state's properties, in state order.
    pub fn property_names(&self, state: u16) -> impl Iterator<Item = &str> {
        self.properties[self.block_of(state) as usize]
            .iter()
            .map(|p| p.name.as_str())
    }

    pub fn block_of(&self, state: u16) -> u16 {
        self.block_of[state as usize]
    }

    pub fn class_name(&self, state: u16) -> &str {
        &self.classes[self.class[self.block_of(state) as usize] as usize]
    }

    pub fn flag(&self, state: u16, flag: u32) -> bool {
        self.flags[state as usize] & flag != 0
    }

    /// A flag of the second word (`FULL_SHAPE`, …).
    pub fn flag2(&self, state: u16, flag: u32) -> bool {
        self.flags2[state as usize] & flag != 0
    }

    /// The block entity type the state's block creates, if any.
    pub fn block_entity_type(&self, state: u16) -> Option<&'static str> {
        self.block_entity_types
            .get(self.block_of(state) as usize)
            .copied()
            .flatten()
    }

    /// `FireBlock.canBurn`.
    pub fn flammable(&self, state: u16) -> bool {
        self.flammable[state as usize / 64] & (1 << (state % 64)) != 0
    }

    pub fn is_air(&self, state: u16) -> bool {
        self.flag(state, AIR)
    }

    pub fn fluid(&self, state: u16) -> u8 {
        self.fluid[state as usize]
    }

    /// `getSignal` toward direction `d`; a signal that reads the level (powered
    /// wire, comparators, trapped chests) is 0 here.
    pub fn signal(&self, state: u16, d: usize) -> i32 {
        (self.signal[state as usize] >> (4 * d) & 15) as i32
    }

    /// `getDirectSignal` toward direction `d`, as `signal`.
    pub fn direct_signal(&self, state: u16, d: usize) -> i32 {
        (self.signal[state as usize] >> (24 + 4 * d) & 15) as i32
    }

    /// The state's heightmap predicate for `kind`.
    pub fn heightmap(&self, state: u16, kind: Heightmap) -> bool {
        self.heightmaps[state as usize] & (1 << kind as u8) != 0
    }

    pub fn tag(&self, name: &str) -> Result<&BlockSet, String> {
        let name = name.strip_prefix('#').unwrap_or(name);
        self.tags
            .get(name)
            .ok_or_else(|| format!("unknown block tag {name}"))
    }

    /// A block tag's blocks in vanilla's order.
    pub fn tag_blocks(&self, name: &str) -> Result<&[u16], String> {
        self.tag_lists
            .get(name)
            .map(Vec::as_slice)
            .ok_or_else(|| format!("no block tag {name}"))
    }

    pub fn in_tag(&self, state: u16, tag: &BlockSet) -> bool {
        tag.contains(self.block_of(state))
    }

    /// A block holder set: `minecraft:x`, `#tag` or a list of blocks.
    pub fn block_set(&self, json: &Json) -> Result<BlockSet, String> {
        match json {
            Json::String(s) if s.starts_with('#') => Ok(self.tag(s)?.clone()),
            Json::String(s) => Ok(BlockSet::from_blocks([self.block(s)?])),
            Json::Array(items) => Ok(BlockSet::from_blocks(
                items
                    .iter()
                    .map(|b| self.block(b.as_str()?))
                    .collect::<Result<Vec<_>, _>>()?,
            )),
            _ => Err("block set".into()),
        }
    }

    /// A fluid holder set, as fluid ids.
    pub fn fluid_set(&self, json: &Json) -> Result<Vec<u8>, String> {
        let one = |name: &str| -> Result<Vec<u8>, String> {
            if let Some(tag) = name.strip_prefix('#') {
                return self
                    .fluid_tags
                    .get(tag)
                    .cloned()
                    .ok_or_else(|| format!("unknown fluid tag {tag}"));
            }
            FLUID_NAMES
                .iter()
                .position(|n| *n == name)
                .map(|i| vec![i as u8])
                .ok_or_else(|| format!("unknown fluid {name}"))
        };
        match json {
            Json::String(s) => one(s),
            Json::Array(items) => {
                let mut out = Vec::new();
                for item in items {
                    out.extend(one(item.as_str()?)?);
                }
                Ok(out)
            }
            _ => Err("fluid set".into()),
        }
    }

    /// A property's value index in a state, if the block has it.
    pub fn value_index(&self, state: u16, property: &str) -> Option<usize> {
        let block = self.block_of(state) as usize;
        let offset = (state - self.first[block]) as usize;
        let mut stride = 1;
        let mut found = None;
        for p in self.properties[block].iter().rev() {
            if p.name == property {
                found = Some((offset / stride) % p.values.len());
            }
            stride *= p.values.len();
        }
        found
    }

    pub fn value(&self, state: u16, property: &str) -> Option<&str> {
        let block = self.block_of(state) as usize;
        let index = self.value_index(state, property)?;
        self.properties[block]
            .iter()
            .find(|p| p.name == property)
            .map(|p| p.values[index].as_str())
    }

    /// `state.setValue(property, value)`; `None` when the block lacks the
    /// property or value.
    pub fn with(&self, state: u16, property: &str, value: &str) -> Option<u16> {
        let block = self.block_of(state) as usize;
        let properties = &self.properties[block];
        let mut stride = 1usize;
        for p in properties.iter().rev() {
            if p.name == property {
                let new = p.values.iter().position(|v| v == value)?;
                let offset = (state - self.first[block]) as usize;
                let old = (offset / stride) % p.values.len();
                return Some((offset + new * stride - old * stride) as u16 + self.first[block]);
            }
            stride *= p.values.len();
        }
        None
    }

    pub fn has_property(&self, state: u16, property: &str) -> bool {
        self.properties[self.block_of(state) as usize]
            .iter()
            .any(|p| p.name == property)
    }

    /// A block state as 26.3's codecs write it: `minecraft:x`,
    /// `{"id": …, "properties": {…}}` or `{"Name": …, "Properties": {…}}`.
    pub fn state(&self, json: &Json) -> Result<u16, String> {
        let (name, properties) = match json {
            Json::String(name) => (name.as_str(), None),
            _ => match json.get("id").or_else(|| json.get("Name")) {
                Some(name) => (
                    name.as_str()?,
                    json.get("properties").or_else(|| json.get("Properties")),
                ),
                None => return Err("block state".into()),
            },
        };
        let mut state = self.default_state(name)?;
        if let Some(properties) = properties {
            for (key, value) in properties.entries()? {
                state = self.with(state, key, value.as_str()?).ok_or_else(|| {
                    format!("{name} has no {key}={}", value.as_str().unwrap_or("?"))
                })?;
            }
        }
        Ok(state)
    }

    /// `FluidState.createLegacyBlock` of a fluid state written as
    /// `{"id": fluid, "properties": {…}}`, and the fluid id.
    pub fn fluid_state(&self, json: &Json) -> Result<(u16, u8), String> {
        let name = json.field("id")?.as_str()?;
        let fluid = FLUID_NAMES
            .iter()
            .position(|n| *n == name)
            .ok_or_else(|| format!("unknown fluid {name}"))? as u8;
        let property = |key: &str| json.get("properties").and_then(|p| p.get(key));
        let falling = match property("falling") {
            Some(v) => v.as_str()? == "true",
            None => false,
        };
        let block = match fluid {
            FLUID_WATER | FLUID_FLOWING_WATER => "water",
            FLUID_LAVA | FLUID_FLOWING_LAVA => "lava",
            _ => return Ok((self.default_state("air")?, fluid)),
        };
        // `FlowingFluid.getLegacyLevel`: sources 0, else 8 - amount, plus 8
        // when falling.
        let level = if fluid == FLUID_WATER || fluid == FLUID_LAVA {
            0
        } else {
            let amount = match property("level") {
                Some(v) => v.as_str()?.parse::<i32>().map_err(|e| e.to_string())?,
                None => 8,
            };
            8 - amount.min(8) + if falling { 8 } else { 0 }
        };
        let state = self
            .with(self.default_state(block)?, "level", &level.to_string())
            .ok_or("fluid level")?;
        Ok((state, fluid))
    }
}
