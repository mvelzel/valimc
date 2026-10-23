//! What the natural spawner reads (VMC-042a), installed once per VM: the
//! mob categories, every spawning type's facts (from the entity facts and the
//! spawn facts), every biome's natural spawns and spawn costs, the
//! dimensions' monster light rules, and per block state its `isValidSpawn`
//! kind and the spawn rules' block tests. The Elixir side assembles them
//! from `priv/registry/entity_facts.json` and `priv/registry/spawn_facts.json`.

use crate::worldgen::json::Json;
use std::collections::HashMap;

/// `MobCategory` in vanilla's order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Category {
    Monster,
    Creature,
    Ambient,
    Axolotls,
    UndergroundWaterCreature,
    WaterCreature,
    WaterAmbient,
    Misc,
}

pub const CATEGORIES: [Category; 8] = [
    Category::Monster,
    Category::Creature,
    Category::Ambient,
    Category::Axolotls,
    Category::UndergroundWaterCreature,
    Category::WaterCreature,
    Category::WaterAmbient,
    Category::Misc,
];

impl Category {
    pub fn name(self) -> &'static str {
        match self {
            Category::Monster => "monster",
            Category::Creature => "creature",
            Category::Ambient => "ambient",
            Category::Axolotls => "axolotls",
            Category::UndergroundWaterCreature => "underground_water_creature",
            Category::WaterCreature => "water_creature",
            Category::WaterAmbient => "water_ambient",
            Category::Misc => "misc",
        }
    }

    pub fn of(name: &str) -> Result<Category, String> {
        CATEGORIES
            .into_iter()
            .find(|c| c.name() == name)
            .ok_or_else(|| format!("unknown mob category {name}"))
    }

    pub fn index(self) -> usize {
        self as usize
    }
}

/// A category's caps and despawn rules (`MobCategory`).
#[derive(Clone, Copy, Debug)]
pub struct CategoryFacts {
    pub max: i32,
    pub friendly: bool,
    pub persistent: bool,
    pub despawn_distance: i32,
    pub no_despawn_distance: i32,
}

/// `SpawnPlacementType`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Placement {
    OnGround,
    InWater,
    InLava,
    NoRestrictions,
}

/// The type's registered `SpawnPredicate` (`SpawnPlacements`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rule {
    /// No registration: always.
    None,
    /// `Mob.checkMobSpawnRules`: a valid spawn below.
    Mob,
    Monster,
    SurfaceMonster,
    Animal,
    /// A block tag below (a spawn word bit) and bright enough.
    TagBright(u32),
    Axolotl,
    Bat,
    SurfaceWater,
    Nautilus,
    TropicalFish,
    Drowned,
    Guardian,
    Ghast,
    GlowSquid,
    MagmaCube,
    Always,
    Ocelot,
    NotOnWart,
    ZombifiedPiglin,
    Patrolling,
    PolarBear,
    Slime,
    Stray,
    Strider,
    Turtle,
    /// Endermite and silverfish: any light, no player within five blocks.
    NoPlayerNear,
}

/// `getWalkTargetValue`, which `PathfinderMob.checkSpawnRules` tests.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Walk {
    /// Not a `PathfinderMob`: `checkSpawnRules` is true.
    None,
    Zero,
    /// `Animal`: grass below 10, else the light cost.
    Animal,
    /// `MushroomCow`: mycelium below 10, else the light cost.
    Mooshroom,
    /// `Monster`: minus the light cost.
    Monster,
    /// `Silverfish`: an infestable block below 10, else as a monster.
    Silverfish,
    /// `Guardian`: in water 10 plus the light cost, else as a monster.
    Guardian,
    Turtle,
    Strider,
    Hoglin,
}

/// `checkSpawnObstruction`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Obstruction {
    /// `Mob`'s: no liquid in the box and unobstructed.
    Default,
    /// Water mobs' and striders': unobstructed.
    Unobstructed,
    Ocelot,
}

/// `removeWhenFarAway` of a fresh mob.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Removal {
    Always,
    Never,
    /// Ocelots and cats: after 2400 ticks (`tickCount > 2400`), untamed.
    Aged,
}

#[derive(Clone, Debug)]
pub struct TypeFacts {
    pub id: u16,
    pub name: String,
    pub category: Category,
    pub width: f32,
    pub height: f32,
    /// The spawn box's half width and height (`getSpawnAABB`).
    pub box_half: f32,
    pub box_height: f32,
    pub fire_immune: bool,
    pub spawn_far: bool,
    pub summonable: bool,
    pub peaceful: bool,
    pub placement: Placement,
    /// `Heightmap.Types` index of the type's spawn heightmap.
    pub heightmap: usize,
    pub cluster: i32,
    /// The spawn word bit of the block tag the type is immune to.
    pub immune: Option<u32>,
    pub rule: Rule,
    pub walk: Walk,
    pub obstruction: Obstruction,
    pub removal: Removal,
}

/// A count provider (`ConstantInt` draws nothing, `UniformInt` always draws).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Count {
    Constant(i32),
    Uniform(i32, i32),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Spawner {
    pub kind: u16,
    pub weight: i32,
    pub count: Count,
}

#[derive(Clone, Debug, Default)]
pub struct BiomeFacts {
    /// Per category its weighted spawners and their total weight.
    pub spawns: [Vec<Spawner>; 8],
    pub totals: [i32; 8],
    /// Per type its energy budget and charge (`MobSpawnCost`).
    pub costs: HashMap<u16, (f64, f64)>,
    pub creature_probability: f32,
    /// Biome tags the rules read.
    pub reduced_water_ambient: bool,
    pub polar_alternate: bool,
    pub tropical_any_height: bool,
    pub frequent_drowned: bool,
    pub surface_slimes: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct DimensionFacts {
    pub monster_light: Count,
    pub block_light_limit: i32,
    pub ambient_light: f32,
    pub ceiling: bool,
}

/// Spawn word bits by name (the oracle's `bit_names` order is checked at install).
pub mod bits {
    pub const PATHFINDABLE_LAND: u32 = 0;
    pub const BURNING: u32 = 1;
    pub const DANGEROUS: u32 = 2;
    pub const LIGHT_BLOCKS_SKY: u32 = 3;
    pub const PREVENT_SPAWNING_INSIDE: u32 = 4;
    pub const ANIMALS: u32 = 5;
    pub const MOOSHROOMS: u32 = 6;
    pub const PARROTS: u32 = 7;
    pub const FOXES: u32 = 8;
    pub const WOLVES: u32 = 9;
    pub const GOATS: u32 = 10;
    pub const RABBITS: u32 = 11;
    pub const FROGS: u32 = 12;
    pub const AXOLOTLS: u32 = 13;
    pub const ARMADILLO: u32 = 14;
    pub const CAMELS: u32 = 15;
    pub const POLAR_ALTERNATE: u32 = 16;
    pub const BATS: u32 = 17;
    pub const LEAVES: u32 = 18;
    pub const SAND: u32 = 19;
    pub const NAMES: [&str; 20] = [
        "pathfindable_land",
        "burning",
        "dangerous",
        "light_blocks_sky",
        "prevent_mob_spawning_inside",
        "animals_spawnable_on",
        "mooshrooms_spawnable_on",
        "parrots_spawnable_on",
        "foxes_spawnable_on",
        "wolves_spawnable_on",
        "goats_spawnable_on",
        "rabbits_spawnable_on",
        "frogs_spawnable_on",
        "axolotls_spawnable_on",
        "armadillo_spawnable_on",
        "camels_spawnable_on",
        "polar_bears_spawnable_on_alternate",
        "bats_spawnable_on",
        "leaves",
        "sand",
    ];
}

/// Single blocks the rules name, as spawn word bits found by name at install.
#[derive(Clone, Copy, Debug)]
pub struct Named {
    pub grass_block: u32,
    pub mycelium: u32,
    pub nether_wart_block: u32,
    pub nether_bricks: u32,
    pub water: u32,
    pub powder_snow: u32,
    pub crimson_nylium: u32,
    pub infested_host: u32,
}

/// A structure's spawn override in one category (`StructureSpawnOverride`,
/// VMC-042b): inside any piece or anywhere in the start's box, its own
/// weighted spawners instead of the biome's.
#[derive(Clone, Debug, Default)]
pub struct Override {
    pub piece: bool,
    pub spawns: Vec<Spawner>,
    pub total: i32,
}

pub struct Facts {
    pub categories: [CategoryFacts; 8],
    /// Per structure that overrides spawns (by index), per category its
    /// override; `structure_names` indexes them, `fortress` is the Nether
    /// fortress's (`isInNetherFortressBounds`).
    pub structures: Vec<[Option<Override>; 8]>,
    pub structure_names: HashMap<String, u16>,
    pub fortress: Option<u16>,
    /// By entity registry id.
    pub types: Vec<Option<TypeFacts>>,
    /// By biome registry id.
    pub biomes: Vec<BiomeFacts>,
    pub dimensions: HashMap<String, DimensionFacts>,
    /// Per state: 0 never, 1 every type, 2 ocelots and parrots, 3 polar
    /// bears, 4 fire-immune types (`isValidSpawn`).
    pub valid_spawn: Vec<u8>,
    /// Per state its spawn word.
    pub words: Vec<u64>,
    pub named: Named,
    pub plains: u16,
}

impl Facts {
    pub fn kind(&self, id: u16) -> Option<&TypeFacts> {
        self.types.get(id as usize).and_then(Option::as_ref)
    }

    pub fn biome(&self, id: u16) -> &BiomeFacts {
        self.biomes
            .get(id as usize)
            .unwrap_or(&self.biomes[self.plains as usize])
    }

    pub fn word(&self, state: u16) -> u64 {
        self.words.get(state as usize).copied().unwrap_or(0)
    }

    pub fn has(&self, state: u16, bit: u32) -> bool {
        self.word(state) >> bit & 1 != 0
    }

    pub fn category(&self, category: Category) -> &CategoryFacts {
        &self.categories[category.index()]
    }

    /// `isValidSpawn(level, pos, type)` of `state`.
    pub fn valid_spawn(&self, state: u16, kind: &TypeFacts) -> bool {
        match self.valid_spawn.get(state as usize).copied().unwrap_or(0) {
            1 => true,
            2 => kind.name == "minecraft:ocelot" || kind.name == "minecraft:parrot",
            3 => kind.name == "minecraft:polar_bear",
            4 => kind.fire_immune,
            _ => false,
        }
    }

    /// Parse the assembled facts (see the module doc for the sources):
    /// `{categories, types, biomes, biome_tags, dimensions, states}`.
    pub fn parse(json: &Json) -> Result<Facts, String> {
        let mut categories = [CategoryFacts {
            max: -1,
            friendly: true,
            persistent: true,
            despawn_distance: 128,
            no_despawn_distance: 32,
        }; 8];
        for (name, c) in object(json.field("categories")?)? {
            categories[Category::of(name)?.index()] = CategoryFacts {
                max: c.field("max")?.as_i32()?,
                friendly: c.field("friendly")?.as_bool()?,
                persistent: c.field("persistent")?.as_bool()?,
                despawn_distance: c.field("despawn_distance")?.as_i32()?,
                no_despawn_distance: c.field("no_despawn_distance")?.as_i32()?,
            };
        }

        let states = json.field("states")?;
        let names: Vec<&str> = states
            .field("bit_names")?
            .as_array()?
            .iter()
            .map(|n| n.as_str())
            .collect::<Result<_, _>>()?;
        for (i, name) in bits::NAMES.iter().enumerate() {
            if names.get(i) != Some(name) {
                return Err(format!("spawn word bit {i} is not {name}"));
            }
        }
        let bit = |name: &str| -> Result<u32, String> {
            names
                .iter()
                .position(|n| *n == name)
                .map(|i| i as u32)
                .ok_or_else(|| format!("no spawn word bit {name}"))
        };
        let named = Named {
            grass_block: bit("grass_block")?,
            mycelium: bit("mycelium")?,
            nether_wart_block: bit("nether_wart_block")?,
            nether_bricks: bit("nether_bricks")?,
            water: bit("water")?,
            powder_snow: bit("powder_snow")?,
            crimson_nylium: bit("crimson_nylium")?,
            infested_host: bit("infested_host")?,
        };
        let valid_spawn = hex(states.field("valid_spawn")?.as_str()?)?;
        let palette: Vec<u64> = states
            .field("palette")?
            .as_array()?
            .iter()
            .map(|v| v.as_f64().map(|f| f as u64))
            .collect::<Result<_, _>>()?;
        let words = hex(states.field("bits")?.as_str()?)?
            .into_iter()
            .map(|i| {
                palette
                    .get(i as usize)
                    .copied()
                    .ok_or("spawn word index past its palette")
            })
            .collect::<Result<Vec<u64>, _>>()?;
        if words.len() != valid_spawn.len() || valid_spawn.iter().any(|&v| v > 4) {
            return Err("spawn state columns disagree".into());
        }

        let mut types: Vec<Option<TypeFacts>> = Vec::new();
        let mut by_name: HashMap<String, u16> = HashMap::new();
        for (name, t) in object(json.field("types")?)? {
            let id = t.field("id")?.as_i32()? as u16;
            let placement = match t.get("spawn_placement") {
                Some(Json::String(p)) => match p.as_str() {
                    "on_ground" => Placement::OnGround,
                    "in_water" => Placement::InWater,
                    "in_lava" => Placement::InLava,
                    _ => Placement::NoRestrictions,
                },
                _ => Placement::NoRestrictions,
            };
            let heightmap = match t.get("spawn_heightmap") {
                Some(Json::String(h)) if h == "MOTION_BLOCKING" => 4,
                _ => 5,
            };
            let immune = match t.get("immune") {
                Some(Json::String(tag)) => names.iter().position(|n| n == tag).map(|i| i as u32),
                _ => None,
            };
            let category = Category::of(t.field("category")?.as_str()?)?;
            let pathfinder = matches!(t.get("pathfinder"), Some(Json::Bool(true)));
            let kind = TypeFacts {
                id,
                name: name.clone(),
                category,
                width: t.field("width")?.as_f64()? as f32,
                height: t.field("height")?.as_f64()? as f32,
                box_half: t.field("box")?.as_array()?[0].as_f64()? as f32,
                box_height: t.field("box")?.as_array()?[1].as_f64()? as f32,
                fire_immune: t.field("fire_immune")?.as_bool()?,
                spawn_far: t.field("spawn_far")?.as_bool()?,
                summonable: t.field("summonable")?.as_bool()?,
                peaceful: t.field("peaceful")?.as_bool()?,
                placement,
                heightmap,
                cluster: match t.get("cluster") {
                    Some(c) => c.as_i32()?,
                    None => 4,
                },
                immune,
                rule: rule(name, &bit)?,
                walk: if pathfinder {
                    walk(name, category)
                } else {
                    Walk::None
                },
                obstruction: obstruction(name),
                removal: removal(name, category),
            };
            if types.len() <= id as usize {
                types.resize(id as usize + 1, None);
            }
            by_name.insert(name.clone(), id);
            types[id as usize] = Some(kind);
        }

        let tag_sets: HashMap<&str, Vec<u16>> = object(json.field("biome_tags")?)?
            .iter()
            .map(|(name, ids)| {
                let ids = ids
                    .as_array()?
                    .iter()
                    .map(|i| i.as_i32().map(|v| v as u16))
                    .collect::<Result<Vec<_>, _>>()?;
                Ok((name.as_str(), ids))
            })
            .collect::<Result<_, String>>()?;
        let tagged = |tag: &str, id: u16| tag_sets.get(tag).is_some_and(|ids| ids.contains(&id));
        let mut biomes: Vec<BiomeFacts> = Vec::new();
        let mut plains = None;
        for (name, b) in object(json.field("biomes")?)? {
            let id = b.field("id")?.as_i32()? as u16;
            if name == "minecraft:plains" {
                plains = Some(id);
            }
            let mut facts = BiomeFacts {
                creature_probability: b.field("creature_probability")?.as_f64()? as f32,
                reduced_water_ambient: tagged("minecraft:reduce_water_ambient_spawns", id),
                polar_alternate: tagged("minecraft:polar_bears_spawn_on_alternate_blocks", id),
                tropical_any_height: tagged(
                    "minecraft:allows_tropical_fish_spawns_at_any_height",
                    id,
                ),
                frequent_drowned: tagged("minecraft:more_frequent_drowned_spawns", id),
                surface_slimes: tagged("minecraft:allows_surface_slime_spawns", id),
                ..BiomeFacts::default()
            };
            for (category, list) in object(b.field("spawns")?)? {
                let c = Category::of(category)?.index();
                let (spawns, total) = spawners(list, &by_name)?;
                facts.spawns[c] = spawns;
                facts.totals[c] = total;
            }
            for (kind, cost) in object(b.field("costs")?)? {
                let kind = *by_name.get(kind).ok_or("spawn cost of an unknown type")?;
                let cost = cost.as_array()?;
                facts
                    .costs
                    .insert(kind, (cost[0].as_f64()?, cost[1].as_f64()?));
            }
            if biomes.len() <= id as usize {
                biomes.resize(id as usize + 1, BiomeFacts::default());
            }
            biomes[id as usize] = facts;
        }

        let mut dimensions = HashMap::new();
        for (name, d) in object(json.field("dimensions")?)? {
            let light = d.field("monster_light")?.as_array()?;
            let (min, max) = (light[1].as_i32()?, light[2].as_i32()?);
            dimensions.insert(
                name.clone(),
                DimensionFacts {
                    monster_light: match light[0].as_str()? {
                        "constant" => Count::Constant(min),
                        _ => Count::Uniform(min, max),
                    },
                    block_light_limit: d.field("block_light_limit")?.as_i32()?,
                    ambient_light: d.field("ambient_light")?.as_f64()? as f32,
                    ceiling: d.field("ceiling")?.as_bool()?,
                },
            );
        }

        let mut structures = Vec::new();
        let mut structure_names = HashMap::new();
        if let Some(listed) = json.get("structures") {
            for (name, overrides) in object(listed)? {
                let mut by_category: [Option<Override>; 8] = Default::default();
                for (category, o) in object(overrides)? {
                    let (spawns, total) = spawners(o.field("spawns")?, &by_name)?;
                    by_category[Category::of(category)?.index()] = Some(Override {
                        piece: o.field("piece")?.as_bool()?,
                        spawns,
                        total,
                    });
                }
                structure_names.insert(name.clone(), structures.len() as u16);
                structures.push(by_category);
            }
        }
        let fortress = structure_names.get("minecraft:fortress").copied();

        Ok(Facts {
            categories,
            structures,
            structure_names,
            fortress,
            types,
            biomes,
            dimensions,
            valid_spawn,
            words,
            named,
            plains: plains.ok_or("no plains biome")?,
        })
    }
}

/// A weighted spawner list, `[type, weight, "constant" | "uniform", min,
/// max]` each, with its total weight.
fn spawners(list: &Json, by_name: &HashMap<String, u16>) -> Result<(Vec<Spawner>, i32), String> {
    let mut out = Vec::new();
    let mut total = 0;
    for s in list.as_array()? {
        let s = s.as_array()?;
        let kind = *by_name
            .get(s[0].as_str()?)
            .ok_or_else(|| format!("a spawn list names unknown {:?}", s[0]))?;
        let (min, max) = (s[3].as_i32()?, s[4].as_i32()?);
        let count = match s[2].as_str()? {
            "constant" => Count::Constant(min),
            _ => Count::Uniform(min, max),
        };
        let weight = s[1].as_i32()?;
        out.push(Spawner {
            kind,
            weight,
            count,
        });
        total += weight;
    }
    Ok((out, total))
}

fn object(json: &Json) -> Result<&[(String, Json)], String> {
    match json {
        Json::Object(fields) => Ok(fields),
        other => Err(format!("expected an object, got {other:?}")),
    }
}

fn hex(text: &str) -> Result<Vec<u8>, String> {
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(2) {
        return Err("odd hex column".into());
    }
    bytes
        .chunks(2)
        .map(|pair| {
            std::str::from_utf8(pair)
                .ok()
                .and_then(|s| u8::from_str_radix(s, 16).ok())
                .ok_or_else(|| "bad hex column".to_string())
        })
        .collect()
}

/// `SpawnPlacements`' predicate of a type, by name.
fn rule(name: &str, bit: &dyn Fn(&str) -> Result<u32, String>) -> Result<Rule, String> {
    let short = name.strip_prefix("minecraft:").unwrap_or(name);
    Ok(match short {
        "axolotl" => Rule::Axolotl,
        "cod" | "pufferfish" | "salmon" | "dolphin" | "squid" => Rule::SurfaceWater,
        "drowned" => Rule::Drowned,
        "guardian" | "elder_guardian" => Rule::Guardian,
        "tropical_fish" => Rule::TropicalFish,
        "armadillo" => Rule::TagBright(bit("armadillo_spawnable_on")?),
        "bat" => Rule::Bat,
        "blaze" | "breeze" | "zoglin" => Rule::Mob,
        "bogged" | "cave_spider" | "creeper" | "enderman" | "giant" | "skeleton" | "spider"
        | "witch" | "wither" | "wither_skeleton" | "creaking" | "zombie" | "zombie_horse"
        | "zombie_villager" | "evoker" | "illusioner" | "ravager" | "vex" | "vindicator"
        | "warden" => Rule::Monster,
        "camel" => Rule::TagBright(bit("camels_spawnable_on")?),
        "camel_husk" | "husk" | "parched" => Rule::SurfaceMonster,
        "chicken" | "cow" | "donkey" | "horse" | "llama" | "mule" | "pig" | "sheep"
        | "happy_ghast" | "cat" | "panda" | "trader_llama" | "skeleton_horse" => Rule::Animal,
        "endermite" | "silverfish" => Rule::NoPlayerNear,
        "ender_dragon" | "iron_golem" | "snow_golem" | "villager" | "phantom" | "shulker"
        | "wandering_trader" => Rule::Mob,
        "frog" => Rule::TagBright(bit("frogs_spawnable_on")?),
        "goat" => Rule::TagBright(bit("goats_spawnable_on")?),
        "wolf" => Rule::TagBright(bit("wolves_spawnable_on")?),
        "parrot" => Rule::TagBright(bit("parrots_spawnable_on")?),
        "rabbit" => Rule::TagBright(bit("rabbits_spawnable_on")?),
        "fox" => Rule::TagBright(bit("foxes_spawnable_on")?),
        "mooshroom" => Rule::TagBright(bit("mooshrooms_spawnable_on")?),
        "ghast" => Rule::Ghast,
        "glow_squid" => Rule::GlowSquid,
        "magma_cube" => Rule::MagmaCube,
        "sulfur_cube" => Rule::Always,
        "nautilus" => Rule::Nautilus,
        "ocelot" => Rule::Ocelot,
        "hoglin" | "piglin" => Rule::NotOnWart,
        "pillager" => Rule::Patrolling,
        "polar_bear" => Rule::PolarBear,
        "slime" => Rule::Slime,
        "stray" => Rule::Stray,
        "strider" => Rule::Strider,
        "turtle" => Rule::Turtle,
        "zombified_piglin" => Rule::ZombifiedPiglin,
        _ => Rule::None,
    })
}

/// A pathfinder's `getWalkTargetValue`, by name and category.
fn walk(name: &str, category: Category) -> Walk {
    let short = name.strip_prefix("minecraft:").unwrap_or(name);
    match short {
        "mooshroom" => Walk::Mooshroom,
        "turtle" => Walk::Turtle,
        "strider" => Walk::Strider,
        "hoglin" => Walk::Hoglin,
        "axolotl" | "nautilus" | "zombie_nautilus" | "enderman" => Walk::Zero,
        "silverfish" => Walk::Silverfish,
        "guardian" | "elder_guardian" => Walk::Guardian,
        "squid" | "glow_squid" | "dolphin" | "cod" | "salmon" | "pufferfish" | "tropical_fish"
        | "tadpole" => Walk::Zero,
        _ => match category {
            Category::Monster => Walk::Monster,
            Category::Creature | Category::Ambient | Category::Axolotls => Walk::Animal,
            _ => Walk::Zero,
        },
    }
}

fn obstruction(name: &str) -> Obstruction {
    let short = name.strip_prefix("minecraft:").unwrap_or(name);
    match short {
        "ocelot" => Obstruction::Ocelot,
        "squid" | "glow_squid" | "dolphin" | "cod" | "salmon" | "pufferfish" | "tropical_fish"
        | "tadpole" | "axolotl" | "guardian" | "elder_guardian" | "drowned" | "nautilus"
        | "zombie_nautilus" | "strider" => Obstruction::Unobstructed,
        _ => Obstruction::Default,
    }
}

fn removal(name: &str, category: Category) -> Removal {
    let short = name.strip_prefix("minecraft:").unwrap_or(name);
    match short {
        "ocelot" | "cat" => Removal::Aged,
        "zombie_horse" | "camel_husk" | "hoglin" | "nautilus" | "zombie_nautilus" => {
            Removal::Always
        }
        "villager" | "wandering_trader" | "iron_golem" | "snow_golem" | "allay" | "chicken" => {
            Removal::Never
        }
        _ if category == Category::Creature => Removal::Never,
        _ => Removal::Always,
    }
}
