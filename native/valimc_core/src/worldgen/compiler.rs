//! Worldgen state for one seed and noise settings (VMC-023c), vanilla's
//! `RandomState` with its `DensityFunctionCompiler`: noise instances seeded
//! from the world seed, and density functions optimised and compiled to
//! samplers as vanilla does it:
//!
//! 1. Registry references are inlined; every `cache` becomes a prepared cache,
//!    shared by all caches with an equal input, its input optimised and
//!    compiled once.
//! 2. Functions that ignore an axis their parent uses are sliced at 0 on it
//!    (`SliceUniformAxes`), so they are sampled once per column or plane.
//! 3. The result compiles to samplers, taking vanilla's shortcuts (constant
//!    operands, `min`/`max` decided by ranges, constant lerp ends).

mod place;
pub use place::{Placed, Placement, Plan};

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, OnceLock};

use super::beard::Beardifier;
use super::blocks::BlockTable;
use super::carver::{self, Carver, CarvingMask, GenContext};
use super::climate::{quantize, ParameterList};
use super::density::{
    Axis, Binary, Df, Env, ShiftKind, Simple, Spline, Tiling, ALL_AXES, AXIS_X, AXIS_Y, AXIS_Z,
};
use super::feature::{Decoration, DecorationFacts};
use super::interval::{Interval, NAI};
use super::json::Json;
use super::noise::{BlendedParameters, NormalNoise, Simplex, Stack};
use super::random::{Positional, Random};
use super::region::{Area, ProtoChunk, Region, SpawnStructure};
use super::sampler::{Context, Field, GradientKind, Sampler, SplineNode};
use super::starts::{Around, StartTable};
use super::structure::place::{place_in_chunk, visit_order, writable_area, Ctx, Placer};
use super::structure::{
    ClimateBiomes, Heights, Start, StructureDef, StructureEnv, StructureRegistry, DECORATION_STEPS,
};
use super::surface::{
    self, Biomes, ChunkBlocks, MaterialRegistry, MaterialSystem, Rule, SurfaceEnv, SurfaceInput,
    Terracotta,
};
use super::template::Templates;
use super::terrain::{self, Aquifer, AquiferSamplers, FilledChunk, TerrainBlocks};
use super::volume::Volume;
use crate::column::{
    Column, HEIGHT as COLUMN_HEIGHT, MIN_Y as COLUMN_MIN_Y, SECTIONS as COLUMN_SECTIONS,
};
use crate::facts::StateFacts;
use crate::rules::shapes::Shapes;
use crate::rules::support::Support;
use crate::rules::Rules;
use crate::section::{index as section_index, Biomes as SectionBiomes, Storage};

/// Noise settings: vertical bounds, random algorithm and the named functions
/// of the noise router and aquifers.
#[derive(Clone, Debug)]
pub struct Settings {
    pub min_y: i32,
    pub height: i32,
    pub sea_level: i32,
    /// Global state ids.
    pub default_block: u16,
    pub default_fluid: u16,
    pub legacy_random_source: bool,
    pub router: Vec<(String, Df)>,
    pub aquifers: Vec<(String, Df)>,
    pub material_rule: Rule,
    /// The spawn target (VMC-027d).
    pub spawn_target: Vec<SpawnPoint>,
}

/// Block states worldgen places or tests, as global state ids.
#[derive(Clone, Debug, Default)]
pub struct BlockFacts {
    pub air: u16,
    pub water: u16,
    pub lava: u16,
    pub terracotta: Terracotta,
    pub snow_block: u16,
    pub packed_ice: u16,
    /// Per state: bit 0 air, bit 1 contains a fluid, bit 2 a water block.
    pub flags: Vec<u8>,
}

/// The generated worldgen facts, decoded.
pub struct Facts<'a> {
    pub noises: &'a Json,
    pub density_functions: &'a Json,
    pub noise_settings: &'a Json,
    pub biome_parameters: &'a Json,
    pub material_rules: &'a Json,
    pub material_conditions: &'a Json,
    pub biomes: &'a Json,
    pub carvers: &'a Json,
    pub blocks: &'a Json,
    /// The normal world preset's dimensions (VMC-026a), when given.
    pub dimensions: Option<&'a Json>,
    /// Decoration (VMC-025), when present: features, placed features, state
    /// providers, the feature order, survival facts, the block registry and
    /// per-state block facts.
    pub decoration: Option<DecorationJson<'a>>,
    /// Structures, structure sets and structure templates (VMC-025e), when
    /// present.
    pub structures: Option<StructureJson<'a>>,
}

pub struct DecorationJson<'a> {
    pub features: &'a Json,
    pub placed_features: &'a Json,
    pub block_state_providers: &'a Json,
    pub feature_order: &'a Json,
    pub support: &'a Json,
    pub shapes: Option<&'a Json>,
    /// Live play's survival facts (VMC-077m), when given.
    pub live_support: Option<&'a Json>,
    /// Every structure template, the block transforms and the processor
    /// lists (VMC-025c, VMC-025f), when given.
    pub templates: Option<(&'a Json, &'a Json, &'a Json)>,
    pub block_registry: &'a Json,
    pub block_facts: &'a Json,
}

impl<'a> Facts<'a> {
    /// The facts from one object keyed by fact file name.
    pub fn from_object(json: &'a Json) -> Result<Facts<'a>, String> {
        Ok(Facts {
            noises: json.field("noises")?,
            density_functions: json.field("density_functions")?,
            noise_settings: json.field("noise_settings")?,
            biome_parameters: json.field("biome_parameters")?,
            material_rules: json.field("material_rules")?,
            material_conditions: json.field("material_conditions")?,
            biomes: json.field("biomes")?,
            carvers: json.field("carvers")?,
            blocks: json.field("blocks")?,
            dimensions: json.get("dimensions"),
            decoration: match json.get("features") {
                None => None,
                Some(features) => Some(DecorationJson {
                    features,
                    placed_features: json.field("placed_features")?,
                    block_state_providers: json.field("block_state_providers")?,
                    feature_order: json.field("feature_order")?,
                    support: json.field("support")?,
                    shapes: json.get("shapes"),
                    live_support: json.get("live_support"),
                    templates: match (
                        json.get("structure_templates"),
                        json.get("block_transforms"),
                        json.get("processor_lists"),
                    ) {
                        (Some(t), Some(b), Some(l)) => Some((t, b, l)),
                        _ => None,
                    },
                    block_registry: json.field("block_registry")?,
                    block_facts: json.field("block_facts")?,
                }),
            },
            structures: match (
                json.get("structures"),
                json.get("structure_sets"),
                json.get("template_pools"),
                json.get("structure_templates"),
            ) {
                (Some(structures), Some(sets), Some(pools), Some(templates)) => {
                    Some(StructureJson {
                        structures,
                        sets,
                        pools,
                        templates,
                    })
                }
                _ => None,
            },
        })
    }
}

/// Structures, structure sets, template pools and structure templates.
pub struct StructureJson<'a> {
    pub structures: &'a Json,
    pub sets: &'a Json,
    pub pools: &'a Json,
    pub templates: &'a Json,
}

/// The worldgen registries ValiMC reads from generated facts.
#[derive(Clone, Debug, Default)]
pub struct Registry {
    pub noises: HashMap<String, NormalNoise>,
    pub functions: HashMap<String, Df>,
    pub settings: HashMap<String, Settings>,
    /// Multi-noise biome parameter presets, with their biomes' registry ids.
    pub biome_parameters: HashMap<String, (Arc<ParameterList>, Vec<u16>)>,
    pub biomes: Biomes,
    pub materials: MaterialRegistry,
    pub blocks: BlockFacts,
    pub carvers: HashMap<String, Carver>,
    /// Per biome registry id, its carvers in order.
    pub biome_carvers: Vec<Vec<String>>,
    /// The normal world preset's dimensions (VMC-026a), by dimension id.
    pub dimensions: HashMap<String, Dimension>,
    /// Decoration per biome source of those dimensions (VMC-025, VMC-026a),
    /// when its facts were given.
    pub decorations: HashMap<String, Arc<Decoration>>,
    /// Structures and structure sets (VMC-025e), when their facts were given.
    pub structures: Option<Arc<StructureRegistry>>,
    /// The block rules decoration and live play share (VMC-077m), with the
    /// decoration facts.
    pub rules: Option<Arc<Rules>>,
}

/// A dimension of the normal world preset (`dimensions.json`): its dimension
/// type's build bounds, its noise settings and biome source.
#[derive(Clone, Debug)]
pub struct Dimension {
    pub min_y: i32,
    pub height: i32,
    pub noise_settings: String,
    pub biome_source: String,
}

/// `TheEndBiomeSource.possibleBiomes`.
const END_BIOMES: [&str; 5] = [
    "minecraft:the_end",
    "minecraft:end_highlands",
    "minecraft:end_midlands",
    "minecraft:small_end_islands",
    "minecraft:end_barrens",
];

/// One chunk's biomes as `fill_biomes` computes them.
#[derive(Clone, Debug)]
pub struct ChunkBiomes {
    /// Per section from the bottom, 64 entries in index order (y, z, x):
    /// indices into the parameter list's biomes.
    pub biomes: Vec<u16>,
    /// The climate target of every lookup, in lookup order.
    pub targets: Vec<[i64; 6]>,
}

/// The climate functions of the noise router, in vanilla's sampling order.
const CLIMATE: [&str; 6] = [
    "temperature",
    "vegetation",
    "continents",
    "erosion",
    "depth",
    "ridges",
];

/// A spawn target point: functions and their quantized parameter ranges.
pub type SpawnPoint = Vec<(Df, i64, i64)>;

/// `SpawnTargetPoint`s: function references with `[min, max]` parameters,
/// quantized as `Climate.quantizeCoord` does.
fn spawn_target(json: Option<&Json>) -> Result<Vec<SpawnPoint>, String> {
    let Some(points) = json else {
        return Ok(vec![]);
    };
    let quantize =
        |v: &Json| -> Result<i64, String> { Ok((v.as_f64()? as f32 * 10000.0f32) as i64) };
    points
        .as_array()?
        .iter()
        .map(|point| {
            point
                .entries()?
                .iter()
                .map(|(name, range)| match range.as_array()? {
                    [min, max] => Ok((
                        Df::parse(&Json::String(name.clone()))?,
                        quantize(min)?,
                        quantize(max)?,
                    )),
                    _ => Err(format!("spawn target {name}: not a range")),
                })
                .collect()
        })
        .collect()
}

fn named_functions(json: Option<&Json>) -> Result<Vec<(String, Df)>, String> {
    match json {
        None => Ok(vec![]),
        Some(object) => object
            .entries()?
            .iter()
            .map(|(name, f)| {
                Ok((
                    name.clone(),
                    Df::parse(f).map_err(|e| format!("{name}: {e}"))?,
                ))
            })
            .collect(),
    }
}

impl Registry {
    /// Parses the generated facts; block states in settings and material
    /// rules are global state ids, and `states` is the installed per-state
    /// block facts.
    pub fn parse(facts: &Facts, states: &StateFacts) -> Result<Registry, String> {
        let mut registry = Registry::default();
        let state = |json: &Json| -> Result<u16, String> {
            u16::try_from(json.as_i32()?).map_err(|_| "state id out of range".to_string())
        };
        let blocks = facts.blocks;
        let terracotta = blocks.field("terracotta")?.as_array()?;
        if terracotta.len() != 7 {
            return Err("seven terracotta states".into());
        }
        registry.blocks = BlockFacts {
            air: state(blocks.field("air")?)?,
            water: state(blocks.field("water")?)?,
            lava: state(blocks.field("lava")?)?,
            terracotta: std::array::from_fn(|i| state(&terracotta[i]).unwrap_or(0)),
            snow_block: state(blocks.field("snow_block")?)?,
            packed_ice: state(blocks.field("packed_ice")?)?,
            flags: blocks
                .field("flags")?
                .as_array()?
                .iter()
                .map(|f| f.as_i32().map(|f| f as u8))
                .collect::<Result<_, _>>()?,
        };
        registry.biomes = Biomes::parse(facts.biomes)?;
        for (id, json) in facts.carvers.entries()? {
            registry.carvers.insert(
                id.clone(),
                Carver::parse(json).map_err(|e| format!("carver {id}: {e}"))?,
            );
        }
        for (id, json) in facts.biomes.entries()? {
            let carvers = match json.get("carvers") {
                None => vec![],
                Some(Json::String(c)) => vec![c.clone()],
                Some(list) => list
                    .as_array()?
                    .iter()
                    .map(|c| c.as_str().map(str::to_string))
                    .collect::<Result<_, _>>()?,
            };
            if let Some(missing) = carvers.iter().find(|c| !registry.carvers.contains_key(*c)) {
                return Err(format!("biome {id} has unknown carver {missing}"));
            }
            registry.biome_carvers.push(carvers);
        }
        registry.materials = MaterialRegistry::parse(
            facts.material_rules,
            facts.material_conditions,
            &registry.biomes,
        )?;
        for (id, rows) in facts.biome_parameters.entries()? {
            let list =
                ParameterList::parse(rows).map_err(|e| format!("biome parameters {id}: {e}"))?;
            let ids = list
                .biomes
                .iter()
                .map(|b| registry.biomes.id(b))
                .collect::<Result<Vec<_>, _>>()?;
            registry
                .biome_parameters
                .insert(id.clone(), (Arc::new(list), ids));
        }
        if let Some(json) = &facts.structures {
            let biomes = &registry.biomes;
            let parsed = StructureRegistry::parse(
                json.structures,
                json.sets,
                json.pools,
                json.templates,
                &|name| biomes.id(name),
            )?;
            registry.structures = Some(Arc::new(parsed));
        }
        let (noises, functions, settings) =
            (facts.noises, facts.density_functions, facts.noise_settings);
        for (id, json) in noises.entries()? {
            registry.noises.insert(
                id.clone(),
                NormalNoise::parse(json).map_err(|e| format!("noise {id}: {e}"))?,
            );
        }
        for (id, json) in functions.entries()? {
            registry.functions.insert(
                id.clone(),
                Df::parse(json).map_err(|e| format!("density function {id}: {e}"))?,
            );
        }
        for (id, json) in settings.entries()? {
            let noise = json.field("noise")?;
            let parsed = Settings {
                min_y: noise.field("min_y")?.as_i32()?,
                height: noise.field("height")?.as_i32()?,
                sea_level: json.field("sea_level")?.as_i32()?,
                default_block: state(json.field("default_block")?)?,
                default_fluid: state(json.field("default_fluid")?)?,
                legacy_random_source: json.field("legacy_random_source")?.as_bool()?,
                router: named_functions(Some(json.field("noise_router")?))?,
                aquifers: named_functions(json.get("aquifers"))?,
                material_rule: Rule::parse(json.field("material_rule")?, &registry.biomes)?,
                spawn_target: spawn_target(json.get("spawn_target"))?,
            };
            registry.settings.insert(id.clone(), parsed);
        }
        if let Some(json) = facts.dimensions {
            for (id, dimension) in json.entries()? {
                registry.dimensions.insert(
                    id.clone(),
                    Dimension {
                        min_y: dimension.field("min_y")?.as_i32()?,
                        height: dimension.field("height")?.as_i32()?,
                        noise_settings: dimension.field("noise_settings")?.as_str()?.to_string(),
                        biome_source: dimension.field("biome_source")?.as_str()?.to_string(),
                    },
                );
            }
        }
        if let Some(json) = &facts.decoration {
            let table = Arc::new(BlockTable::parse(
                json.block_registry,
                json.block_facts,
                states,
            )?);
            let support = Arc::new(Support::parse(json.support)?);
            let shapes = json.shapes.map(Shapes::parse).transpose()?.map(Arc::new);
            let live = json.live_support.map(Support::parse).transpose()?;
            let rules = Arc::new(Rules::new(table.clone(), support, shapes, live)?);
            registry.rules = Some(rules.clone());
            let templates = json
                .templates
                .map(|(t, b, l)| Templates::parse(t, b, l, &table))
                .transpose()?
                .map(Arc::new);
            let biomes = registry.biomes.clone();
            // The placed features jigsaw pools place (VMC-025f): trees, piles
            // and patches no biome orders.
            let pool_features = match &facts.structures {
                Some(s) => pool_features(s.pools)?,
                None => Vec::new(),
            };
            let mut dimensions: Vec<_> = registry.dimensions.values().cloned().collect();
            dimensions.sort_by(|a, b| a.biome_source.cmp(&b.biome_source));
            for dimension in dimensions {
                let source = &dimension.biome_source;
                let Some(order) = json.feature_order.get(source) else {
                    continue;
                };
                let mut source_biomes = if source == "minecraft:the_end" {
                    END_BIOMES
                        .iter()
                        .map(|b| biomes.id(b))
                        .collect::<Result<Vec<_>, _>>()?
                } else {
                    registry
                        .biome_parameters
                        .get(source)
                        .ok_or_else(|| format!("no biome parameters {source}"))?
                        .1
                        .clone()
                };
                source_biomes.sort_unstable();
                source_biomes.dedup();
                let settings = registry
                    .settings
                    .get(&dimension.noise_settings)
                    .ok_or_else(|| {
                        format!("unknown noise settings {}", dimension.noise_settings)
                    })?;
                // `WorldGenerationContext`: the dimension's bounds within the
                // generator's, and the generator's sea level.
                let context = GenContext {
                    min_y: dimension.min_y.max(settings.min_y),
                    height: dimension.height.min(settings.height),
                    sea_level: settings.sea_level,
                };
                let decoration = Decoration::parse(
                    table.clone(),
                    DecorationFacts {
                        features: json.features,
                        placed_features: json.placed_features,
                        block_state_providers: json.block_state_providers,
                        order,
                        biomes: facts.biomes,
                        rules: rules.clone(),
                        templates: templates.clone(),
                        biome_ids: &|name| biomes.id(name),
                        biome_count: biomes.names.len(),
                        source_biomes: &source_biomes,
                        climates: biomes.climate.clone(),
                        extra_placed: &pool_features,
                    },
                    context,
                    (dimension.min_y, dimension.height),
                )
                .map_err(|e| format!("decoration of {source}: {e}"))?;
                registry
                    .decorations
                    .insert(source.clone(), Arc::new(decoration));
            }
        }
        Ok(registry)
    }
}

#[derive(Clone, Debug)]
struct Prepared {
    range: Interval,
    axes: u8,
    sampler: Option<Arc<Sampler>>,
}

/// A dimension's biome source (VMC-077n), parsed once from its name: a
/// multi-noise preset (`minecraft:overworld`, `minecraft:nether`, a data
/// pack's), the End's, or one biome everywhere (`fixed:BIOME`, VMC-028b).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum BiomeSource {
    MultiNoise(Arc<str>),
    End,
    Fixed(u16),
}

const END_SOURCE: &str = "minecraft:the_end";

impl BiomeSource {
    pub fn parse(name: &str, registry: &Registry) -> Result<BiomeSource, String> {
        if name == END_SOURCE {
            Ok(BiomeSource::End)
        } else if let Some(biome) = name.strip_prefix(FIXED) {
            Ok(BiomeSource::Fixed(registry.biomes.id(biome)?))
        } else if registry.biome_parameters.contains_key(name) {
            Ok(BiomeSource::MultiNoise(name.into()))
        } else {
            Err(format!("unknown biome source {name}"))
        }
    }

    /// The name its decoration facts are kept under; none for a fixed source.
    fn preset(&self) -> Option<&str> {
        match self {
            BiomeSource::MultiNoise(id) => Some(id),
            BiomeSource::End => Some(END_SOURCE),
            BiomeSource::Fixed(_) => None,
        }
    }

    /// A multi-noise source's parameter list and its biomes' registry ids.
    fn parameters(&self, registry: &Registry) -> Result<(Arc<ParameterList>, Vec<u16>), String> {
        match self {
            BiomeSource::MultiNoise(id) => registry
                .biome_parameters
                .get(&**id)
                .cloned()
                .ok_or_else(|| format!("unknown biome source {id}")),
            other => Err(format!("{other} is not a multi-noise biome source")),
        }
    }
}

impl std::fmt::Display for BiomeSource {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            BiomeSource::MultiNoise(id) => f.write_str(id),
            BiomeSource::End => f.write_str(END_SOURCE),
            BiomeSource::Fixed(biome) => write!(f, "{FIXED}#{biome}"),
        }
    }
}

/// A cache key: a biome source and a chunk.
type ChunkKey = (BiomeSource, i32, i32);

/// What a seed compiles (vanilla's `RandomState`): its noises and its
/// density functions, prepared and compiled once.
#[derive(Default)]
struct Compiled {
    noises: HashMap<String, Arc<Stack>>,
    prepared: Vec<Prepared>,
    prepared_keys: HashMap<Df, usize>,
    samplers: HashMap<Df, Arc<Sampler>>,
}

/// One seed's generation under one noise settings (VMC-077n): compiled
/// eagerly (`compile`), then shared by every call through an `Arc`. Besides
/// its compile state (complete after `compile`) it holds only bounded caches
/// of pure values, which any call may fill: every call gets the same chunks.
pub struct SeedContext {
    registry: Arc<Registry>,
    settings: Settings,
    seed: i64,
    positional: Positional,
    compiled: Mutex<Compiled>,
    material_system: OnceLock<Arc<MaterialSystem>>,
    /// Structure generation per biome source (VMC-025e).
    structure_envs: Mutex<HashMap<BiomeSource, Arc<StructureEnv>>>,
    /// Decorations of fixed biome sources by biome (VMC-028b), derived once.
    fixed_decorations: Mutex<HashMap<u16, Arc<Decoration>>>,
    /// Chunk biomes by biome source and chunk: each chunk's surface needs its
    /// 3 × 3 chunks' biomes, so neighbouring chunks share them.
    chunk_biomes: Mutex<HashMap<ChunkKey, Arc<Vec<u16>>>>,
    /// Carver biomes by biome source and chunk (each chunk's carvers look at
    /// the 17 × 17 around it).
    carver_biomes: Mutex<HashMap<ChunkKey, u16>>,
    /// The bounds chunk biomes cover: those of the dimension whose generator
    /// uses these noise settings (a chunk holds biomes for all its
    /// sections), else the noise settings' own.
    biome_bounds: (i32, i32),
}

/// A call's handle on a seed's context: generation methods take it mutably
/// (they fill the context's caches) but share everything with other calls.
pub struct Worldgen {
    ctx: Arc<SeedContext>,
}

impl std::ops::Deref for Worldgen {
    type Target = SeedContext;
    fn deref(&self) -> &SeedContext {
        &self.ctx
    }
}

/// Chunks whose biomes the context keeps (about 3 KB each).
const CHUNK_BIOME_CACHE_LIMIT: usize = 8192;
/// A fixed biome source's name: this prefix and the biome (VMC-028b).
pub const FIXED: &str = "fixed:";
const CARVER_BIOME_CACHE_LIMIT: usize = 65536;

/// Insert into a bounded cache, emptying it when full.
fn bounded_insert<K: std::hash::Hash + Eq, V>(
    cache: &mut HashMap<K, V>,
    limit: usize,
    key: K,
    value: V,
) {
    if cache.len() >= limit {
        cache.clear();
    }
    cache.insert(key, value);
}

impl SurfaceEnv for Worldgen {
    fn sampler(&mut self, function: &Df) -> Result<Arc<Sampler>, String> {
        self.ctx.sampler(function)
    }

    fn noise(&mut self, id: &str) -> Result<Arc<Stack>, String> {
        self.ctx.noise(id)
    }

    fn random_factory(&mut self, name: &str) -> Positional {
        self.positional.from_hash_of(name).fork_positional()
    }
}

const TEMPERATURE_NETHER: &str = "minecraft:nether/temperature";
const VEGETATION_NETHER: &str = "minecraft:nether/vegetation";
const TERRAIN_SEED: &str = "minecraft:terrain";
const AQUIFER_SEED: &str = "minecraft:aquifer";

impl SeedContext {
    fn new(registry: Arc<Registry>, seed: i64, settings: &str) -> Result<SeedContext, String> {
        let settings_id = settings;
        let settings = registry
            .settings
            .get(settings)
            .ok_or_else(|| format!("unknown noise settings {settings}"))?
            .clone();
        let mut dimensions: Vec<_> = registry.dimensions.iter().collect();
        dimensions.sort_by(|a, b| a.0.cmp(b.0));
        let biome_bounds = dimensions
            .into_iter()
            .find(|(_, d)| d.noise_settings == settings_id)
            .map_or((settings.min_y, settings.height), |(_, d)| {
                (d.min_y, d.height)
            });
        let mut base = if settings.legacy_random_source {
            Random::legacy(seed)
        } else {
            Random::xoroshiro(seed)
        };
        Ok(SeedContext {
            positional: base.fork_positional(),
            registry,
            settings,
            seed,
            compiled: Mutex::new(Compiled::default()),
            material_system: OnceLock::new(),
            structure_envs: Mutex::new(HashMap::new()),
            fixed_decorations: Mutex::new(HashMap::new()),
            chunk_biomes: Mutex::new(HashMap::new()),
            carver_biomes: Mutex::new(HashMap::new()),
            biome_bounds,
        })
    }

    /// The context of `seed` under the noise settings `settings`, with every
    /// function of its noise router and aquifers compiled and its material
    /// system built: what each chunk's terrain needs, so no call compiles.
    pub fn compile(
        registry: Arc<Registry>,
        seed: i64,
        settings: &str,
    ) -> Result<Arc<SeedContext>, String> {
        let ctx = Arc::new(SeedContext::new(registry, seed, settings)?);
        let mut worldgen = Worldgen::of(&ctx);
        let functions: Vec<Df> = ctx
            .settings
            .router
            .iter()
            .chain(&ctx.settings.aquifers)
            .map(|(_, f)| f.clone())
            .collect();
        for function in &functions {
            worldgen.sampler(function)?;
        }
        worldgen.material_system()?;
        Ok(ctx)
    }

    pub fn settings(&self) -> &Settings {
        &self.settings
    }

    pub fn registry(&self) -> &Arc<Registry> {
        &self.registry
    }

    fn function(&self, id: &str) -> Result<&Df, String> {
        self.registry
            .functions
            .get(id)
            .ok_or_else(|| format!("unknown density function {id}"))
    }

    fn normal_noise(&self, id: &str) -> Result<&NormalNoise, String> {
        self.registry
            .noises
            .get(id)
            .ok_or_else(|| format!("unknown noise {id}"))
    }

    fn compiling<T>(
        &self,
        f: impl FnOnce(&mut Compiling) -> Result<T, String>,
    ) -> Result<T, String> {
        let mut compiled = self
            .compiled
            .lock()
            .map_err(|_| "worldgen compile state poisoned")?;
        f(&mut Compiling {
            ctx: self,
            c: &mut compiled,
        })
    }

    /// The compiled sampler of a function (vanilla's `getSampler`).
    pub fn sampler(&self, function: &Df) -> Result<Arc<Sampler>, String> {
        self.compiling(|c| c.sampler(function))
    }

    /// The noise a density function samples (vanilla's `createNoiseSampler`).
    pub fn noise(&self, id: &str) -> Result<Arc<Stack>, String> {
        self.compiling(|c| c.noise(id))
    }

    /// Approximate bytes the context holds beyond its registry: compiled
    /// functions and noises are counted by entry, caches by their values.
    pub fn heap_bytes(&self) -> usize {
        let compiled = self.compiled.lock().map_or(0, |c| {
            (c.samplers.len() + c.prepared.len()) * 512 + c.noises.len() * 4096
        });
        let biomes = self
            .chunk_biomes
            .lock()
            .map_or(0, |c| c.values().map(|b| b.len() * 2 + 64).sum());
        let carvers = self.carver_biomes.lock().map_or(0, |c| c.len() * 48);
        compiled + biomes + carvers
    }
}

impl Worldgen {
    /// A fresh context's handle, compiled lazily (tools and tests; live
    /// generation shares a `SeedContext::compile`d one).
    pub fn new(registry: Arc<Registry>, seed: i64, settings: &str) -> Result<Worldgen, String> {
        Ok(Worldgen {
            ctx: Arc::new(SeedContext::new(registry, seed, settings)?),
        })
    }

    /// A handle on `ctx` for one call.
    pub fn of(ctx: &Arc<SeedContext>) -> Worldgen {
        Worldgen { ctx: ctx.clone() }
    }

    pub fn context(&self) -> &Arc<SeedContext> {
        &self.ctx
    }

    /// A named function: `router:FIELD`, `aquifers:FIELD` or a registry id.
    pub fn named(&self, name: &str) -> Result<Df, String> {
        let lookup = |list: &[(String, Df)], field: &str| {
            list.iter()
                .find(|(n, _)| n == field)
                .map(|(_, f)| f.clone())
                .ok_or_else(|| format!("unknown function {name}"))
        };
        if let Some(field) = name.strip_prefix("router:") {
            lookup(&self.settings.router, field)
        } else if let Some(field) = name.strip_prefix("aquifers:") {
            lookup(&self.settings.aquifers, field)
        } else {
            self.function(name)?;
            Ok(Df::Ref(name.to_string()))
        }
    }

    /// A chunk's multi-noise biomes, as vanilla's chunk generation fills them
    /// (`createResolverForChunk` and `fillBiomesFromNoise`): the six climate
    /// functions sampled over the chunk's quart volume through one cached
    /// context, then one lookup per quart, section by section, X outer and Z
    /// inner. `last` carries the lookup history between chunks.
    pub fn fill_biomes(
        &mut self,
        list: &ParameterList,
        chunk_x: i32,
        chunk_z: i32,
        last: &mut Option<usize>,
    ) -> Result<ChunkBiomes, String> {
        let (min_y, height) = self.biome_bounds;
        let volume = Volume::new(
            [4, height / 4, 4],
            [chunk_x.wrapping_mul(16), min_y, chunk_z.wrapping_mul(16)],
            [4, 4, 4],
        )?;
        let mut ctx = Context::cached();
        let mut climate = Vec::with_capacity(CLIMATE.len());
        for field in CLIMATE {
            let function = self.named(&format!("router:{field}"))?;
            let sampler = self.sampler(&function)?;
            let mut values = vec![0.0f32; volume.len()];
            sampler.fill(&mut ctx, &mut values, &volume);
            climate.push(values);
        }
        let sections = height / 16;
        let mut biomes = vec![0u16; sections as usize * 64];
        let mut targets = Vec::with_capacity(volume.len());
        for section in 0..sections {
            for x in 0..4 {
                for y in 0..4 {
                    for z in 0..4 {
                        let i = volume.index(x, section * 4 + y, z);
                        let target: [i64; 6] = std::array::from_fn(|c| quantize(climate[c][i]));
                        let biome = list.find(&target, last);
                        biomes[(section * 64 + (y * 4 + z) * 4 + x) as usize] = biome;
                        targets.push(target);
                    }
                }
            }
        }
        Ok(ChunkBiomes { biomes, targets })
    }

    /// A chunk's noise terrain (vanilla's `doFill`, without structures):
    /// final density over the chunk at block resolution, then the aquifer.
    pub fn fill_terrain(&mut self, chunk_x: i32, chunk_z: i32) -> Result<FilledChunk, String> {
        self.terrain(chunk_x, chunk_z, None, false, None)
    }

    /// A chunk's terrain as vanilla's `buildTerrain` makes it, without
    /// structures: the noise fill, the material rule, and with `carve` the
    /// carvers of the 17 × 17 chunks around, all through one noise chunk
    /// context. Biomes come from `biome_source` (a multi-noise preset or
    /// `minecraft:the_end`): chunk biomes each filled from a fresh lookup
    /// history, and single lookups (carver biomes) likewise.
    pub fn build_terrain(
        &mut self,
        chunk_x: i32,
        chunk_z: i32,
        biome_source: &BiomeSource,
        carve: bool,
    ) -> Result<FilledChunk, String> {
        self.terrain(chunk_x, chunk_z, Some(biome_source), carve, None)
    }

    fn chunk_volume(&self, chunk_x: i32, chunk_z: i32) -> Result<Volume, String> {
        Volume::new(
            [16, self.settings.height, 16],
            [
                chunk_x.wrapping_mul(16),
                self.settings.min_y,
                chunk_z.wrapping_mul(16),
            ],
            [1, 1, 1],
        )
    }

    fn aquifer_samplers(&mut self) -> Result<Option<(AquiferSamplers, Positional)>, String> {
        if self.settings.aquifers.is_empty() {
            return Ok(None);
        }
        let mut compile = |field: &str| -> Result<Arc<Sampler>, String> {
            let function = self.named(&format!("aquifers:{field}"))?;
            self.sampler(&function)
        };
        let samplers = AquiferSamplers {
            barrier: compile("barrier")?,
            floodedness: compile("fluid_level_floodedness")?,
            spread: compile("fluid_level_spread")?,
            lava: compile("lava")?,
            exclusion: compile("exclusion")?,
            surface_level: compile("surface_level")?,
        };
        let positional = self.positional.from_hash_of(AQUIFER_SEED).fork_positional();
        Ok(Some((samplers, positional)))
    }

    fn terrain(
        &mut self,
        chunk_x: i32,
        chunk_z: i32,
        biome_source: Option<&BiomeSource>,
        carve: bool,
        beard: Option<Arc<Beardifier>>,
    ) -> Result<FilledChunk, String> {
        let volume = self.chunk_volume(chunk_x, chunk_z)?;
        let b = &self.registry.blocks;
        let blocks = TerrainBlocks {
            air: b.air,
            water: b.water,
            lava: b.lava,
            default_block: self.settings.default_block,
            default_fluid: self.settings.default_fluid,
        };
        let mut ctx = Context::cached();
        ctx.beardifier = beard;
        let aquifer_samplers = self.aquifer_samplers()?;
        let mut aquifer = Aquifer::new(
            &mut ctx,
            aquifer_samplers.as_ref().map(|(s, p)| (s, *p)),
            &volume,
            self.settings.sea_level,
            blocks,
        );
        let final_density = self.named("router:final_density")?;
        let final_density = self.sampler(&final_density)?;
        let mut filled = terrain::fill(&mut ctx, &final_density, &mut aquifer, &volume, blocks);
        let Some(biome_source) = biome_source else {
            return Ok(filled);
        };

        // The 3 × 3 chunks' biomes, x major.
        let mut biomes = Vec::with_capacity(9);
        for dx in -1..=1 {
            for dz in -1..=1 {
                biomes.push(self.cached_chunk_biomes(biome_source, chunk_x + dx, chunk_z + dz)?);
            }
        }
        let point_biomes = self.point_biomes(biome_source)?;
        let system = self.material_system()?;
        let registry = self.registry.clone();
        let settings = self.settings.clone();
        let zoom = surface::ChunkZoom::new(
            surface::biome_zoom_seed(self.seed),
            chunk_x,
            chunk_z,
            settings.min_y,
            settings.height,
        );
        let (min_quart, quart_height) = (self.biome_bounds.0 >> 2, self.biome_bounds.1 >> 2);
        let biome_at = |x: i32, y: i32, z: i32| -> u16 {
            let (qx, qy, qz) = zoom.zoom(x, y, z);
            let column = &biomes
                [((qx >> 2) - chunk_x + 1) as usize * 3 + ((qz >> 2) - chunk_z + 1) as usize];
            let qy = qy.clamp(min_quart, min_quart + quart_height - 1) - min_quart;
            column[((qy >> 2) * 64 + ((qy & 3) * 4 + (qz & 3)) * 4 + (qx & 3)) as usize]
        };
        let mut input = SurfaceInput {
            materials: &registry.materials,
            biomes: &registry.biomes,
            system: &system,
            rule: &settings.material_rule,
            biome_at: &biome_at,
            flags: &registry.blocks.flags,
            min_y: settings.min_y,
            height: settings.height,
            sea_level: settings.sea_level,
        };
        let flags = &registry.blocks.flags;
        let mut surface_heights = [settings.min_y; 256];
        for (column, height) in surface_heights.iter_mut().enumerate() {
            let base = column * settings.height as usize;
            if let Some(top) = (0..settings.height as usize)
                .rev()
                .find(|&y| flags[filled.blocks[base + y] as usize] & 1 == 0)
            {
                *height = settings.min_y + top as i32 + 1;
            }
        }
        let mut fluid_updates = std::mem::take(&mut filled.fluid_updates);
        let mut chunk = ChunkBlocks {
            blocks: &mut filled.blocks,
            min_y: settings.min_y,
            height: settings.height,
            chunk_x,
            chunk_z,
            flags,
            surface: surface_heights,
            fluid_updates: &mut fluid_updates,
        };
        let frozen = [
            registry.biomes.id("minecraft:frozen_ocean")?,
            registry.biomes.id("minecraft:deep_frozen_ocean")?,
        ];
        let eroded = registry.biomes.id("minecraft:eroded_badlands")?;
        surface::build_surface(self, &mut ctx, &input, &mut chunk, frozen, eroded)?;

        if carve {
            let context = GenContext {
                min_y: settings.min_y,
                height: settings.height,
                sea_level: settings.sea_level,
            };
            let mut mask =
                CarvingMask::new(settings.min_y + 1, settings.min_y + settings.height - 1 - 7);
            let mut random = Random::legacy(0);
            let sources: Vec<(i32, i32)> = (-8..=8)
                .flat_map(|dx| (-8..=8).map(move |dz| (chunk_x + dx, chunk_z + dz)))
                .collect();
            let known: Vec<Option<u16>> = {
                let cache = self
                    .carver_biomes
                    .lock()
                    .map_err(|_| "carver biomes poisoned")?;
                sources
                    .iter()
                    .map(|&(x, z)| cache.get(&(biome_source.clone(), x, z)).copied())
                    .collect()
            };
            let mut found = Vec::new();
            let biomes: Vec<u16> = sources
                .iter()
                .zip(known)
                .map(|(&(x, z), known)| {
                    known.unwrap_or_else(|| {
                        let biome = point_biomes.biome(x * 4, 0, z * 4);
                        found.push(((biome_source.clone(), x, z), biome));
                        biome
                    })
                })
                .collect();
            if !found.is_empty() {
                let mut cache = self
                    .carver_biomes
                    .lock()
                    .map_err(|_| "carver biomes poisoned")?;
                for (key, biome) in found {
                    bounded_insert(&mut cache, CARVER_BIOME_CACHE_LIMIT, key, biome);
                }
            }
            for (&source, &biome) in sources.iter().zip(&biomes) {
                for (index, carver) in registry.biome_carvers[biome as usize].iter().enumerate() {
                    let carver = &registry.carvers[carver];
                    carver::set_large_feature_seed(
                        &mut random,
                        self.seed.wrapping_add(index as i64),
                        source.0,
                        source.1,
                    );
                    if carver.is_start(&mut random) {
                        carver.carve(context, &mut random, (chunk_x, chunk_z), source, &mut mask);
                    }
                }
            }
            if !mask.is_empty() {
                let carver_biome_at = |x: i32, y: i32, z: i32| -> u16 {
                    let (qx, qy, qz) = zoom.zoom(x, y, z);
                    point_biomes.biome(qx, qy, qz)
                };
                input.biome_at = &carver_biome_at;
                apply_carving_mask(self, &mut ctx, &input, &mut chunk, &mut aquifer, &mask)?;
            }
        }
        filled.fluid_updates = fluid_updates;
        Ok(filled)
    }

    /// Structure generation for `biome_source` (VMC-025e): placement, ring
    /// positions and starts, built once per source. The Nether's and the
    /// End's levels are 256 blocks high from y 0, the overworld's those of
    /// its noise settings.
    pub fn structure_env(
        &mut self,
        biome_source: &BiomeSource,
    ) -> Result<Arc<StructureEnv>, String> {
        let known = self
            .structure_envs
            .lock()
            .map_err(|_| "structure envs poisoned")?
            .get(biome_source)
            .cloned();
        if let Some(env) = known {
            return Ok(env);
        }
        let registry = self
            .registry
            .structures
            .clone()
            .ok_or("no structure facts")?;
        let biomes = if *biome_source == BiomeSource::End {
            let erosion = self.named("router:erosion")?;
            let b = &self.registry.biomes;
            let mut ids = [0u16; 5];
            for (id, name) in ids.iter_mut().zip([
                "minecraft:the_end",
                "minecraft:end_highlands",
                "minecraft:end_midlands",
                "minecraft:small_end_islands",
                "minecraft:end_barrens",
            ]) {
                *id = b.id(name)?;
            }
            ClimateBiomes::End {
                erosion: self.sampler(&erosion)?,
                ids,
            }
        } else {
            let (list, ids) = biome_source.parameters(&self.registry)?;
            let mut samplers = Vec::with_capacity(6);
            for field in CLIMATE {
                let function = self.named(&format!("router:{field}"))?;
                samplers.push(self.sampler(&function)?);
            }
            ClimateBiomes::MultiNoise {
                samplers,
                list,
                ids,
            }
        };
        let (level_min_y, level_height) = match biome_source.preset() {
            Some("minecraft:nether" | END_SOURCE) => (0, 256),
            _ => (self.settings.min_y, self.settings.height),
        };
        let final_density = self.named("router:final_density")?;
        let b = &self.registry.blocks;
        let blocks = TerrainBlocks {
            air: b.air,
            water: b.water,
            lava: b.lava,
            default_block: self.settings.default_block,
            default_fluid: self.settings.default_fluid,
        };
        let heights = Heights {
            final_density: self.sampler(&final_density)?,
            aquifer: self.aquifer_samplers()?,
            blocks,
            min_y: self.settings.min_y.max(level_min_y),
            height: (self.settings.min_y + self.settings.height).min(level_min_y + level_height)
                - self.settings.min_y.max(level_min_y),
            level_min_y,
            level_height,
            sea_level: self.settings.sea_level,
            flags: Arc::new(self.registry.blocks.flags.clone()),
        };
        let env = Arc::new(StructureEnv::new(
            registry,
            self.seed,
            biomes,
            heights,
            Arc::new(self.registry.biomes.climate.clone()),
        ));
        Ok(self
            .structure_envs
            .lock()
            .map_err(|_| "structure envs poisoned")?
            .entry(biome_source.clone())
            .or_insert(env)
            .clone())
    }

    /// Single biome lookups for `biome_source` (vanilla's uncached biome
    /// resolver), each from a fresh lookup history.
    fn point_biomes(&mut self, biome_source: &BiomeSource) -> Result<PointBiomes, String> {
        if let BiomeSource::Fixed(biome) = *biome_source {
            return Ok(PointBiomes::Fixed(biome));
        }
        if *biome_source == BiomeSource::End {
            let erosion = self.named("router:erosion")?;
            let b = &self.registry.biomes;
            let mut ids = [0u16; 5];
            for (id, name) in ids.iter_mut().zip([
                "minecraft:the_end",
                "minecraft:end_highlands",
                "minecraft:end_midlands",
                "minecraft:small_end_islands",
                "minecraft:end_barrens",
            ]) {
                *id = b.id(name)?;
            }
            return Ok(PointBiomes::End {
                erosion: self.sampler(&erosion)?,
                ids,
            });
        }
        let (list, ids) = biome_source.parameters(&self.registry)?;
        let mut samplers = Vec::with_capacity(6);
        for field in CLIMATE {
            let function = self.named(&format!("router:{field}"))?;
            samplers.push(self.sampler(&function)?);
        }
        Ok(PointBiomes::MultiNoise {
            samplers,
            list,
            ids,
        })
    }

    /// Vanilla's `MaterialSystem` for this seed, built once.
    fn material_system(&mut self) -> Result<Arc<MaterialSystem>, String> {
        if let Some(system) = self.material_system.get() {
            return Ok(system.clone());
        }
        let preliminary = self.named("router:chunk_surface_level")?;
        let preliminary_surface = self.sampler(&preliminary)?;
        let noise_random = self.positional;
        let bands = surface::clay_bands(
            &mut self.positional.from_hash_of("minecraft:clay_bands"),
            self.registry.blocks.terracotta,
        );
        let system = Arc::new(MaterialSystem {
            default_block: self.settings.default_block,
            sea_level: self.settings.sea_level,
            clay_bands: bands,
            noise_random,
            preliminary_surface,
            clay_bands_offset: self.noise("minecraft:clay_bands_offset")?,
            surface: self.noise("minecraft:surface")?,
            surface_secondary: self.noise("minecraft:surface_secondary")?,
            badlands_pillar: self.noise("minecraft:badlands_pillar")?,
            badlands_pillar_roof: self.noise("minecraft:badlands_pillar_roof")?,
            badlands_surface: self.noise("minecraft:badlands_surface")?,
            iceberg_pillar: self.noise("minecraft:iceberg_pillar")?,
            iceberg_pillar_roof: self.noise("minecraft:iceberg_pillar_roof")?,
            iceberg_surface: self.noise("minecraft:iceberg_surface")?,
            snow_block: self.registry.blocks.snow_block,
            packed_ice: self.registry.blocks.packed_ice,
        });
        Ok(self.material_system.get_or_init(|| system).clone())
    }

    fn cached_chunk_biomes(
        &mut self,
        biome_source: &BiomeSource,
        chunk_x: i32,
        chunk_z: i32,
    ) -> Result<Arc<Vec<u16>>, String> {
        let key = (biome_source.clone(), chunk_x, chunk_z);
        let known = self
            .chunk_biomes
            .lock()
            .map_err(|_| "chunk biomes poisoned")?
            .get(&key)
            .cloned();
        if let Some(biomes) = known {
            return Ok(biomes);
        }
        // Made outside the lock: another call may make the same chunk
        // meanwhile, with the same result.
        let biomes = Arc::new(self.chunk_biome_ids(biome_source, chunk_x, chunk_z)?);
        let mut cache = self
            .chunk_biomes
            .lock()
            .map_err(|_| "chunk biomes poisoned")?;
        bounded_insert(&mut cache, CHUNK_BIOME_CACHE_LIMIT, key, biomes.clone());
        Ok(biomes)
    }

    /// Decoration over an area (VMC-025): the `size` × `size` chunks from
    /// (`x`, `z`) get their terrain (as `build_terrain` with carvers, with
    /// its fluid post-processing marks) and chunk biomes, then each chunk in
    /// `order` is decorated through a region centred on it. `included`
    /// limits the placed features by (step, global index).
    pub fn decorate_area(
        &mut self,
        biome_source: &BiomeSource,
        (x, z): (i32, i32),
        size: i32,
        order: &[(i32, i32)],
        included: Option<&HashSet<(usize, usize)>>,
    ) -> Result<Area, String> {
        Ok(self
            .decorate_area_timed(biome_source, (x, z), size, order, included)?
            .0)
    }

    /// `decorate_area`, with the time decoration took (terrain excluded).
    pub fn decorate_area_timed(
        &mut self,
        biome_source: &BiomeSource,
        (x, z): (i32, i32),
        size: i32,
        order: &[(i32, i32)],
        included: Option<&HashSet<(usize, usize)>>,
    ) -> Result<(Area, std::time::Duration), String> {
        let mut chunks = Vec::with_capacity((size * size) as usize);
        for dz in 0..size {
            for dx in 0..size {
                chunks.push(self.proto_terrain(x + dx, z + dz, biome_source)?);
            }
        }
        let mut area = Area::of(chunks)?;
        let start = std::time::Instant::now();
        self.decorate_held(biome_source, &mut area, order, included, false)?;
        Ok((area, start.elapsed()))
    }

    /// Decoration with structures over an area (VMC-025f), as
    /// `decorate_area` with every placed feature: the starts of every chunk
    /// within 8 of a chunk in `order` (of the structures in `included`, when
    /// given), each chunk's references, then each chunk in `order` decorated
    /// with its structures placed in their steps. Returns the area and the
    /// starts as placement left them, by start chunk and structure.
    pub fn decorate_area_structures(
        &mut self,
        biome_source: &BiomeSource,
        (x, z): (i32, i32),
        size: i32,
        order: &[(i32, i32)],
        included: Option<&HashSet<usize>>,
    ) -> Result<(Area, Vec<Start>), String> {
        self.decorate_area_with_starts(biome_source, (x, z), size, order, included, false)
    }

    /// What live generation makes of `order` decorated one after the other
    /// over the `size` × `size` chunks from (`x`, `z`) (VMC-077n), all in one
    /// call: the reference the generation scheduler's chunks equal, with
    /// structures when the dimension generates them. Reads beyond the area
    /// see empty chunks, as in live generation.
    pub fn reference_area(
        &mut self,
        biome_source: &BiomeSource,
        (x, z): (i32, i32),
        size: i32,
        order: &[(i32, i32)],
        structures: bool,
    ) -> Result<Area, String> {
        if structures && self.registry.structures.is_some() {
            return Ok(self
                .decorate_area_with_starts(biome_source, (x, z), size, order, None, true)?
                .0);
        }
        let mut chunks = Vec::with_capacity((size * size) as usize);
        for dz in 0..size {
            for dx in 0..size {
                chunks.push(self.proto_terrain(x + dx, z + dz, biome_source)?);
            }
        }
        let mut area = Area::of(chunks)?;
        self.decorate_held(biome_source, &mut area, order, None, true)?;
        Ok(area)
    }

    fn decorate_area_with_starts(
        &mut self,
        biome_source: &BiomeSource,
        (x, z): (i32, i32),
        size: i32,
        order: &[(i32, i32)],
        included: Option<&HashSet<usize>>,
        lenient: bool,
    ) -> Result<(Area, Vec<Start>), String> {
        let env = self.structure_env(biome_source)?;
        // Starts within 8 chunks of every chunk of the area: the references
        // of its chunks (beards in their terrain) and of the decorated ones.
        let mut starts: HashMap<(i32, i32), Vec<Start>> = HashMap::new();
        for sx in x - 8..x + size + 8 {
            for sz in z - 8..z + size + 8 {
                let (found, _) = env.create_structures(sx, sz)?;
                let found = found
                    .into_iter()
                    .filter(|s| included.is_none_or(|set| set.contains(&s.structure)))
                    .collect();
                starts.insert((sx, sz), found);
            }
        }
        let registry = env.registry.clone();
        let mut chunks = Vec::with_capacity((size * size) as usize);
        for dz in 0..size {
            for dx in 0..size {
                let (cx, cz) = (x + dx, z + dz);
                let references = env.references(cx, cz, &|sx, sz| {
                    starts.get(&(sx, sz)).map(|v| v.as_slice())
                })?;
                let beard = beardifier(&registry, &starts, &references, (cx, cz));
                chunks.push(self.proto_terrain_bearded(cx, cz, biome_source, beard)?);
            }
        }
        let mut area = Area::of(chunks)?;
        self.decorate_with_starts(biome_source, &env, &mut area, order, &mut starts, lenient)?;
        let mut placed: Vec<Start> = starts.into_values().flatten().collect();
        placed.sort_by_key(|s| (s.chunk, s.structure));
        Ok((area, placed))
    }

    /// Decorates the chunks of `order` over `area`, each step placing the
    /// starts' structures (`starts` by start chunk; placement changes them)
    /// before its features, as `applyBiomeDecoration` does with structures
    /// on; the reads of chunks the area lacks when `lenient`.
    fn decorate_with_starts(
        &mut self,
        biome_source: &BiomeSource,
        env: &StructureEnv,
        area: &mut Area,
        order: &[(i32, i32)],
        starts: &mut dyn StartStore,
        lenient: bool,
    ) -> Result<u32, String> {
        let registry = env.registry.clone();
        let mut by_step: Vec<Vec<usize>> = vec![Vec::new(); DECORATION_STEPS.len()];
        for (index, def) in registry.structures.iter().enumerate() {
            by_step[def.step].push(index);
        }
        let decoration = self.decoration(biome_source)?;
        let placer = Placer::new(&decoration, self.seed)?;
        let zoom_seed = surface::biome_zoom_seed(self.seed);
        let (min_y, height) = (area.min_y, area.height);
        let mut lenient_reads = 0;
        for &(cx, cz) in order {
            let references = env.references(cx, cz, &|sx, sz| starts.view((sx, sz)))?;
            let visits = visit_order(&references);
            let chunk_box = writable_area((cx, cz), min_y, height);
            let mut region = Region::new(
                area,
                &decoration.table,
                (cx, cz),
                self.seed,
                zoom_seed,
                self.settings.sea_level,
            )?;
            region.lenient = lenient;
            // The starts natural spawning reads as placing them left them
            // (VMC-042b: a hut settles its height as it is placed).
            let mut placed: Vec<((i32, i32), usize, SpawnStructure)> = Vec::new();
            let mut place = |step: usize, region: &mut Region, random: &mut Random, seed: i64| {
                for (index, structure) in by_step.get(step).into_iter().flatten().enumerate() {
                    random.set_feature_seed(seed, index as i32, step as i32);
                    for source in visits.get(structure).into_iter().flatten() {
                        starts.place(*source, *structure, &mut |start| {
                            let mut c = Ctx {
                                placer: &placer,
                                region: &mut *region,
                                random: &mut *random,
                                chunk_box,
                                chunk: (cx, cz),
                                reference: [0; 3],
                            };
                            place_in_chunk(start, &mut c, &registry).map_err(|e| {
                                format!("{}: {e}", registry.structures[*structure].id)
                            })?;
                            let def = &registry.structures[*structure];
                            if def.spawn_overrides {
                                placed.push((
                                    *source,
                                    *structure,
                                    spawn_structure(def, start, (cx, cz)),
                                ));
                            }
                            Ok(())
                        })?;
                    }
                }
                Ok(())
            };
            decoration
                .decorate_with(&mut region, None, Some(&mut place))
                .map_err(|e| format!("decorating {cx}, {cz}: {e}"))?;
            lenient_reads += region.lenient_reads;
            drop(region);
            // The chunk keeps the starts natural spawning reads (VMC-042b):
            // those it placed as they are now, the others as they were.
            let mut kept = Vec::new();
            for &(index, source) in &references {
                let def = &registry.structures[index];
                if !def.spawn_overrides {
                    continue;
                }
                if let Some((_, _, now)) = placed.iter().find(|p| p.0 == source && p.1 == index) {
                    kept.push(now.clone());
                } else if let Some(start) = starts
                    .view(source)
                    .into_iter()
                    .flatten()
                    .find(|s| s.structure == index)
                {
                    kept.push(spawn_structure(def, start, (cx, cz)));
                }
            }
            if let Some(chunk) = area.chunk_mut(cx, cz) {
                chunk.structures = kept;
            }
        }
        Ok(lenient_reads)
    }

    /// A chunk's terrain for live generation (VMC-077n): `proto_terrain`,
    /// with structures the beards of the starts that reach it, from the
    /// dimension's start table.
    pub fn generation_terrain(
        &mut self,
        chunk_x: i32,
        chunk_z: i32,
        biome_source: &BiomeSource,
        starts: Option<&StartTable>,
    ) -> Result<ProtoChunk, String> {
        let Some(table) = starts.filter(|_| self.registry.structures.is_some()) else {
            return self.proto_terrain(chunk_x, chunk_z, biome_source);
        };
        let env = self.structure_env(biome_source)?;
        let starts = table
            .around(&env, (chunk_x, chunk_z), (chunk_x, chunk_z))?
            .view()?;
        let references = env.references(chunk_x, chunk_z, &|sx, sz| {
            starts.get(&(sx, sz)).map(|v| v.as_slice())
        })?;
        let beard = beardifier(&env.registry, &starts, &references, (chunk_x, chunk_z));
        self.proto_terrain_bearded(chunk_x, chunk_z, biome_source, beard)
    }

    /// Decorate chunk `center` over `area` (its 3 × 3) for live generation
    /// (VMC-077n): with structures, each step first places the pieces of the
    /// starts that reach the chunk, from the start table, changing them as
    /// vanilla changes its saved starts; the chunk then no longer counts for
    /// those starts. Reads of chunks the area lacks see empty chunks; their
    /// count is returned.
    pub fn generation_decorate(
        &mut self,
        biome_source: &BiomeSource,
        area: &mut Area,
        center: (i32, i32),
        starts: Option<&StartTable>,
    ) -> Result<u32, String> {
        let Some(table) = starts.filter(|_| self.registry.structures.is_some()) else {
            return self.decorate_held(biome_source, area, &[center], None, true);
        };
        let env = self.structure_env(biome_source)?;
        let around = table.around(&env, center, center)?;
        let mut store = TableStarts {
            view: around.view()?,
            around: &around,
        };
        let lenient =
            self.decorate_with_starts(biome_source, &env, area, &[center], &mut store, true)?;
        around.decorated(center)?;
        Ok(lenient)
    }

    /// A chunk at status `terrain` (VMC-025d): `build_terrain` with carvers,
    /// its fluid post-processing marks, its chunk biomes and primed
    /// heightmaps.
    pub fn proto_terrain(
        &mut self,
        chunk_x: i32,
        chunk_z: i32,
        biome_source: &BiomeSource,
    ) -> Result<ProtoChunk, String> {
        self.proto_terrain_bearded(chunk_x, chunk_z, biome_source, None)
    }

    /// `proto_terrain` with the chunk's beardifier (VMC-025f3) in the noise
    /// fill.
    pub fn proto_terrain_bearded(
        &mut self,
        chunk_x: i32,
        chunk_z: i32,
        biome_source: &BiomeSource,
        beard: Option<Arc<Beardifier>>,
    ) -> Result<ProtoChunk, String> {
        let decoration = self.decoration(biome_source)?;
        let (min_y, height) = decoration.dimension;
        let filled = self.terrain(chunk_x, chunk_z, Some(biome_source), true, beard)?;
        let blocks = self.dimension_blocks(filled.blocks, min_y, height)?;
        let biomes = self.cached_chunk_biomes(biome_source, chunk_x, chunk_z)?;
        if biomes.len() != (height / 16 * 64) as usize {
            return Err(format!(
                "chunk biomes do not cover {biome_source}'s dimension"
            ));
        }
        let mut chunk = ProtoChunk::new(
            chunk_x,
            chunk_z,
            (min_y, height),
            blocks,
            biomes,
            &decoration.table,
        );
        for (fx, fy, fz) in filled.fluid_updates {
            chunk.mark([fx, fy, fz]);
        }
        chunk.touched = false;
        Ok(chunk)
    }

    /// Decorate the chunks in `order` through regions over `area` with
    /// `biome_source`'s decoration, every placed feature (or those in
    /// `included`). `lenient` (live generation) lets reads of chunks the area
    /// does not hold see empty chunks; the count of such reads is returned.
    pub fn decorate_held(
        &mut self,
        biome_source: &BiomeSource,
        area: &mut Area,
        order: &[(i32, i32)],
        included: Option<&HashSet<(usize, usize)>>,
        lenient: bool,
    ) -> Result<u32, String> {
        let decoration = self.decoration(biome_source)?;
        let zoom_seed = surface::biome_zoom_seed(self.seed);
        let mut lenient_reads = 0;
        for &(cx, cz) in order {
            let mut region = Region::new(
                area,
                &decoration.table,
                (cx, cz),
                self.seed,
                zoom_seed,
                self.settings.sea_level,
            )?;
            region.lenient = lenient;
            decoration
                .decorate(&mut region, included)
                .map_err(|e| format!("decorating {cx}, {cz}: {e}"))?;
            lenient_reads += region.lenient_reads;
        }
        Ok(lenient_reads)
    }

    /// The decoration of `biome_source`: a preset's (multi-noise presets, the
    /// End), or for `fixed:BIOME` (VMC-028b) the one derived from the
    /// overworld's (or another preset's, the first holding the biome).
    pub fn decoration(&mut self, biome_source: &BiomeSource) -> Result<Arc<Decoration>, String> {
        let biome = match biome_source {
            BiomeSource::Fixed(biome) => *biome,
            preset => {
                let name = preset.preset().unwrap_or_default();
                return self
                    .registry
                    .decorations
                    .get(name)
                    .cloned()
                    .ok_or_else(|| format!("no decoration facts for {biome_source}"));
            }
        };
        let known = self
            .fixed_decorations
            .lock()
            .map_err(|_| "fixed decorations poisoned")?
            .get(&biome)
            .cloned();
        if let Some(decoration) = known {
            return Ok(decoration);
        }
        let name = self
            .registry
            .biomes
            .names
            .get(biome as usize)
            .cloned()
            .unwrap_or_default();
        let mut sources: Vec<_> = self.registry.decorations.iter().collect();
        sources.sort_by_key(|(id, _)| (id.as_str() != "minecraft:overworld", id.to_string()));
        let base = sources
            .into_iter()
            .map(|(_, d)| d)
            .find(|d| d.has_source_biome(biome))
            .ok_or_else(|| format!("no decoration holds the biome {name}"))?;
        let decoration = Arc::new(base.fixed(biome)?);
        Ok(self
            .fixed_decorations
            .lock()
            .map_err(|_| "fixed decorations poisoned")?
            .entry(biome)
            .or_insert(decoration)
            .clone())
    }

    /// The block table decoration uses (proto chunk encoding; every biome
    /// source's decoration shares it).
    pub fn block_table(&self) -> Result<&BlockTable, String> {
        Ok(&self
            .registry
            .decorations
            .get("minecraft:overworld")
            .ok_or("no decoration facts")?
            .table)
    }

    /// A chunk's terrain (noise settings' bounds) within its dimension's
    /// bounds: air above and below what the generator fills (the Nether and
    /// the End fill 128 of their 256 blocks).
    fn dimension_blocks(
        &self,
        blocks: Vec<u16>,
        min_y: i32,
        height: i32,
    ) -> Result<Vec<u16>, String> {
        let (gen_min, gen_height) = (self.settings.min_y, self.settings.height);
        if (gen_min, gen_height) == (min_y, height) {
            return Ok(blocks);
        }
        if gen_min < min_y || gen_min + gen_height > min_y + height {
            return Err("noise settings outside their dimension's bounds".into());
        }
        let (gen_height, height) = (gen_height as usize, height as usize);
        let below = (gen_min - min_y) as usize;
        let mut out = vec![self.registry.blocks.air; 256 * height];
        for column in 0..256 {
            out[column * height + below..column * height + below + gen_height]
                .copy_from_slice(&blocks[column * gen_height..(column + 1) * gen_height]);
        }
        Ok(out)
    }

    /// A generated chunk as a ValiMC column (VMC-024d): the carved terrain in
    /// 24 sections and its biomes as protocol biome ids (`protocol_biomes`,
    /// indexed by biome registry id), with each column's highest non-air block
    /// (`WORLD_SURFACE_WG - 1`, z * 16 + x order; below the world when none).
    /// Another dimension's blocks keep their Y in the overworld's 24 sections
    /// (VMC-026b), the rest air.
    pub fn generate_column(
        &mut self,
        chunk_x: i32,
        chunk_z: i32,
        biome_source: &BiomeSource,
        protocol_biomes: &[u16],
    ) -> Result<(Column, [i32; 256]), String> {
        let filled = self.build_terrain(chunk_x, chunk_z, biome_source, true)?;
        let biomes = self.cached_chunk_biomes(biome_source, chunk_x, chunk_z)?;
        self.column_of(
            &filled.blocks,
            (self.settings.min_y, self.settings.height),
            &biomes,
            self.biome_bounds.0,
            protocol_biomes,
        )
    }

    /// A finished proto chunk as a ValiMC column (VMC-025d), as
    /// `generate_column` makes one from terrain.
    pub fn final_column(
        &self,
        chunk: &ProtoChunk,
        protocol_biomes: &[u16],
    ) -> Result<(Column, [i32; 256]), String> {
        self.column_of(
            &chunk.blocks,
            (chunk.min_y, chunk.height),
            &chunk.biomes,
            chunk.min_y,
            protocol_biomes,
        )
    }

    /// Blocks (Y fastest from `min_y`, then X, then Z, `height` of them per
    /// column) and chunk biomes (sections from `biome_min_y`) as a column of
    /// the overworld's 24 sections: blocks outside their bounds are air,
    /// sections outside the biomes' take the nearest section's. With each
    /// column's highest non-air block.
    fn column_of(
        &self,
        blocks: &[u16],
        (min_y, height): (i32, i32),
        biomes: &[u16],
        biome_min_y: i32,
        protocol_biomes: &[u16],
    ) -> Result<(Column, [i32; 256]), String> {
        let air = self.registry.blocks.air;
        let rows = height as usize;
        if blocks.len() != 256 * rows || biomes.is_empty() || !biomes.len().is_multiple_of(64) {
            return Err("a chunk's blocks or biomes do not fit its bounds".into());
        }
        // The block at column Y index `y` (0 at the overworld's bottom).
        let at = |x: usize, y: usize, z: usize| -> u16 {
            let world_y = COLUMN_MIN_Y + y as i32;
            if world_y < min_y || world_y >= min_y + height {
                air
            } else {
                blocks[(world_y - min_y) as usize + (x + z * 16) * rows]
            }
        };
        let biome_sections = (biomes.len() / 64) as i32;
        let first_biome_section = (biome_min_y - COLUMN_MIN_Y).div_euclid(16);
        let mut sections = Vec::with_capacity(COLUMN_SECTIONS);
        let mut section_biomes = Vec::with_capacity(COLUMN_SECTIONS);
        for s in 0..COLUMN_SECTIONS {
            let first = at(0, s * 16, 0);
            let mut storage = Storage::Single(first);
            for y in 0..16 {
                for z in 0..16 {
                    for x in 0..16 {
                        let state = at(x, s * 16 + y, z);
                        if state != first {
                            storage.set(section_index(x, y, z), state);
                        }
                    }
                }
            }
            storage.normalize();
            sections.push(storage);
            let b = (s as i32 - first_biome_section).clamp(0, biome_sections - 1) as usize;
            let cells: Vec<u16> = biomes[b * 64..b * 64 + 64]
                .iter()
                .map(|&b| {
                    protocol_biomes
                        .get(b as usize)
                        .copied()
                        .ok_or("biome without protocol id")
                })
                .collect::<Result<_, _>>()?;
            section_biomes.push(if cells.iter().all(|&b| b == cells[0]) {
                SectionBiomes::Single(cells[0])
            } else {
                SectionBiomes::Cells(Box::new(cells.try_into().expect("64 biomes")))
            });
        }
        let flags = &self.registry.blocks.flags;
        let mut heights = [COLUMN_MIN_Y - 1; 256];
        for z in 0..16 {
            for x in 0..16 {
                if let Some(top) = (0..COLUMN_HEIGHT)
                    .rev()
                    .find(|&y| flags[at(x, y, z) as usize] & 1 == 0)
                {
                    heights[z * 16 + x] = COLUMN_MIN_Y + top as i32;
                }
            }
        }
        Ok((Column::new(sections, Some(section_biomes)), heights))
    }

    /// A chunk's biomes as registry ids (sections from the bottom, each in
    /// index order y, z, x), with a fresh lookup history.
    pub fn chunk_biome_ids(
        &mut self,
        biome_source: &BiomeSource,
        chunk_x: i32,
        chunk_z: i32,
    ) -> Result<Vec<u16>, String> {
        match *biome_source {
            BiomeSource::End => return self.end_biomes(chunk_x, chunk_z),
            BiomeSource::Fixed(biome) => {
                return Ok(vec![biome; (self.settings.height / 16 * 64) as usize])
            }
            BiomeSource::MultiNoise(_) => {}
        }
        let (list, ids) = biome_source.parameters(&self.registry)?;
        let filled = self.fill_biomes(&list, chunk_x, chunk_z, &mut None)?;
        Ok(filled.biomes.into_iter().map(|b| ids[b as usize]).collect())
    }

    /// `TheEndBiomeSource`: the main island within 64 chunks of the origin,
    /// elsewhere by the erosion function at the centre of the chunk.
    fn end_biomes(&mut self, chunk_x: i32, chunk_z: i32) -> Result<Vec<u16>, String> {
        let erosion = self.named("router:erosion")?;
        let erosion = self.sampler(&erosion)?;
        let b = &self.registry.biomes;
        let [end, highlands, midlands, islands, barrens] = [
            "minecraft:the_end",
            "minecraft:end_highlands",
            "minecraft:end_midlands",
            "minecraft:small_end_islands",
            "minecraft:end_barrens",
        ]
        .map(|n| b.id(n));
        let (end, highlands, midlands, islands, barrens) =
            (end?, highlands?, midlands?, islands?, barrens?);
        let mut ctx = Context::cached();
        let sections = self.biome_bounds.1 / 16;
        let min_quart = self.biome_bounds.0 >> 2;
        let mut out = vec![0u16; sections as usize * 64];
        for section in 0..sections {
            for x in 0..4 {
                for y in 0..4 {
                    for z in 0..4 {
                        let (qx, qy, qz) = (
                            chunk_x * 4 + x,
                            min_quart + section * 4 + y,
                            chunk_z * 4 + z,
                        );
                        let (bx, by, bz) = (qx << 2, qy << 2, qz << 2);
                        let (cx, cz) = ((bx >> 4) as i64, (bz >> 4) as i64);
                        let biome = if cx * cx + cz * cz <= 4096 {
                            end
                        } else {
                            let wx = ((bx >> 4) * 2 + 1) * 8;
                            let wz = ((bz >> 4) * 2 + 1) * 8;
                            let height = erosion.value(&mut ctx, wx, by, wz) as f64;
                            if height > 0.25 {
                                highlands
                            } else if height >= -0.0625 {
                                midlands
                            } else if height < -0.21875 {
                                islands
                            } else {
                                barrens
                            }
                        };
                        out[(section * 64 + (y * 4 + z) * 4 + x) as usize] = biome;
                    }
                }
            }
        }
        Ok(out)
    }

    pub fn biome_parameters(&self, preset: &str) -> Result<Arc<ParameterList>, String> {
        self.registry
            .biome_parameters
            .get(preset)
            .map(|(list, _)| list.clone())
            .ok_or_else(|| format!("unknown biome parameter preset {preset}"))
    }

    /// The compiled sampler of a function (vanilla's `getSampler`).
    pub fn sampler(&mut self, function: &Df) -> Result<Arc<Sampler>, String> {
        self.ctx.sampler(function)
    }
}

/// A seed's compile state borrowed for one compilation (`SeedContext::sampler`).
struct Compiling<'a> {
    ctx: &'a SeedContext,
    c: &'a mut Compiled,
}

impl Env for Compiling<'_> {
    fn function(&self, id: &str) -> Result<&Df, String> {
        self.ctx.function(id)
    }

    fn noise_range(&self, id: &str) -> Result<f32, String> {
        Ok(self.ctx.normal_noise(id)?.range_bound())
    }

    fn prepared(&self, index: usize) -> (Interval, u8) {
        self.c
            .prepared
            .get(index)
            .map_or((NAI, 0), |p| (p.range, p.axes))
    }
}

impl Compiling<'_> {
    /// The noise a density function samples (vanilla's `createNoiseSampler`):
    /// the nether climate noises use the legacy initialiser on their own
    /// legacy randoms; every other noise is created once per seed from the
    /// positional random of its identifier.
    fn noise(&mut self, id: &str) -> Result<Arc<Stack>, String> {
        let legacy_offset = match id {
            TEMPERATURE_NETHER => Some(0),
            VEGETATION_NETHER => Some(1),
            _ => None,
        };
        if let Some(offset) = legacy_offset {
            let mut random = Random::legacy(self.ctx.seed.wrapping_add(offset));
            return Ok(Arc::new(
                self.ctx
                    .normal_noise(id)?
                    .create_legacy_nether(&mut random)?,
            ));
        }
        if let Some(noise) = self.c.noises.get(id) {
            return Ok(noise.clone());
        }
        let noise = Arc::new(
            self.ctx
                .normal_noise(id)?
                .create(&mut self.ctx.positional.from_hash_of(id)),
        );
        self.c.noises.insert(id.to_string(), noise.clone());
        Ok(noise)
    }

    /// The compiled sampler of a function (vanilla's `getSampler`).
    fn sampler(&mut self, function: &Df) -> Result<Arc<Sampler>, String> {
        if let Some(sampler) = self.c.samplers.get(function) {
            return Ok(sampler.clone());
        }
        let optimized = self.optimize(function)?;
        let sampler = Arc::new(self.compile(&optimized)?);
        self.c.samplers.insert(function.clone(), sampler.clone());
        Ok(sampler)
    }

    fn optimize(&mut self, function: &Df) -> Result<Df, String> {
        let inlined = self.inline(function)?;
        self.slice(&inlined, ALL_AXES)
    }

    fn inline(&mut self, function: &Df) -> Result<Df, String> {
        let mut current = function.clone();
        while let Df::Ref(id) = &current {
            current = self.function(id)?.clone();
        }
        match current {
            Df::Cache(input) => Ok(Df::Prepared(self.prepare(&input)?)),
            other => other.map_children(&mut |child| self.inline(child)),
        }
    }

    fn prepare(&mut self, input: &Df) -> Result<usize, String> {
        if let Some(&id) = self.c.prepared_keys.get(input) {
            return Ok(id);
        }
        let id = self.c.prepared.len();
        self.c.prepared.push(Prepared {
            range: NAI,
            axes: 0,
            sampler: None,
        });
        let optimized = self.optimize(input)?;
        let sampler = self.compile(&optimized)?;
        self.c.prepared[id] = Prepared {
            range: optimized.range(self)?,
            axes: optimized.axes(self)?,
            sampler: Some(Arc::new(sampler)),
        };
        self.c.prepared_keys.insert(input.clone(), id);
        Ok(id)
    }

    /// `SliceUniformAxes`: slice functions that ignore axes their parent uses.
    fn slice(&self, function: &Df, parent: u8) -> Result<Df, String> {
        if matches!(function, Df::Constant(_) | Df::Gradient { .. }) {
            return Ok(function.clone());
        }
        let axes = function.axes(self)?;
        if axes == parent {
            return function.map_children(&mut |child| self.slice(child, parent));
        }
        let rewritten = function.map_children(&mut |child| self.slice(child, axes))?;
        let mut existing = 0;
        let mut inner = &rewritten;
        while let Df::Slice { axis, input, .. } = inner {
            existing |= axis.bit();
            inner = input;
        }
        let removed = parent & !axes & !existing;
        let mut result = rewritten;
        for (bit, axis) in [(AXIS_X, Axis::X), (AXIS_Z, Axis::Z), (AXIS_Y, Axis::Y)] {
            if removed & bit != 0 {
                result = Df::Slice {
                    axis,
                    coordinate: 0,
                    input: Box::new(result),
                };
            }
        }
        Ok(result)
    }

    fn compile(&mut self, function: &Df) -> Result<Sampler, String> {
        let b = |s: Sampler| Box::new(s);
        Ok(match function {
            Df::Constant(v) => Sampler::Constant(v.0),
            Df::Ref(id) => return Err(format!("reference {id} was not inlined")),
            Df::Simple(kind) => match kind {
                Simple::BlendAlpha => Sampler::Field(Field::BlendAlpha, 1.0),
                Simple::BlendOffset => Sampler::Field(Field::BlendOffset, 0.0),
                Simple::Beardifier => Sampler::Field(Field::Beardifier, 0.0),
            },
            Df::Noise {
                noise,
                xz_scale,
                y_scale,
                shift,
            } => {
                let noise = self.noise(noise)?;
                let (xz, y) = (xz_scale.0, y_scale.0);
                if shift.iter().all(Df::is_zero) {
                    Sampler::Noise { noise, xz, y }
                } else {
                    let shift_x = self.compile(&shift[0])?;
                    let shift_z = self.compile(&shift[2])?;
                    if shift[1].is_zero() {
                        Sampler::ShiftedXz {
                            shift_x: b(shift_x),
                            shift_z: b(shift_z),
                            noise,
                            xz,
                            y,
                        }
                    } else {
                        let shift_y = self.compile(&shift[1])?;
                        Sampler::ShiftedXyz {
                            shift: Box::new([shift_x, shift_y, shift_z]),
                            noise,
                            xz,
                            y,
                        }
                    }
                }
            }
            Df::EndIslands => {
                let mut random = Random::legacy(self.ctx.seed);
                random.consume_count(17292);
                Sampler::EndIslands(Arc::new(Simplex::new(&mut random, true)))
            }
            Df::Distance { point, metric } => Sampler::Distance(*point, *metric),
            Df::Gradient {
                axis,
                tiling,
                from,
                to,
                from_value,
                to_value,
            } => {
                let range = to.wrapping_sub(*from);
                Sampler::Gradient {
                    axis: *axis,
                    kind: match tiling {
                        Tiling::ClampToEdge => GradientKind::Clamped {
                            min: *from.min(to),
                            max: *from.max(to),
                        },
                        Tiling::Repeat => GradientKind::Repeat { range },
                        Tiling::MirroredRepeat => GradientKind::Mirrored { range },
                    },
                    from: *from,
                    from_value: from_value.0,
                    factor: (to_value.0 - from_value.0) / range as f32,
                }
            }
            Df::Shift { kind, noise } => {
                let noise = self.noise(noise)?;
                match kind {
                    ShiftKind::A => Sampler::ConstMul(
                        b(Sampler::Noise {
                            noise,
                            xz: 0.25,
                            y: 0.0,
                        }),
                        4.0,
                    ),
                    ShiftKind::Xyz => Sampler::ConstMul(
                        b(Sampler::Noise {
                            noise,
                            xz: 0.25,
                            y: 0.25,
                        }),
                        4.0,
                    ),
                    ShiftKind::B => Sampler::ShiftB(noise),
                }
            }
            Df::Unary(op, input) => Sampler::Unary(*op, b(self.compile(input)?)),
            Df::Binary(op, l, r) => self.compile_binary(*op, l, r)?,
            Df::Spline(spline) => {
                let mut indices: HashMap<Df, usize> = HashMap::new();
                let mut coordinates = Vec::new();
                let node = self.compile_spline(spline, &mut indices, &mut coordinates)?;
                Sampler::Spline {
                    spline: Box::new(node),
                    coordinates,
                }
            }
            Df::Lerp(args) => {
                let alpha = self.compile(&args[0])?;
                let first = self.compile(&args[1])?;
                let second = self.compile(&args[2])?;
                if let Df::Constant(f) = args[1] {
                    Sampler::LerpConstFirst(b(alpha), f.0, b(second))
                } else if let Df::Constant(s) = args[2] {
                    Sampler::LerpConstSecond(b(alpha), b(first), s.0)
                } else {
                    Sampler::Lerp(Box::new([alpha, first, second]))
                }
            }
            Df::Clamp { input, min, max } => Sampler::Clamp(b(self.compile(input)?), min.0, max.0),
            Df::RangeChoice {
                input,
                min,
                max,
                in_range,
                out_of_range,
            } => {
                let input = b(self.compile(input)?);
                match (&**in_range, &**out_of_range) {
                    (Df::Constant(i), Df::Constant(o)) => Sampler::RangeChoiceConst {
                        input,
                        min: min.0,
                        max: max.0,
                        in_range: i.0,
                        out_of_range: o.0,
                    },
                    _ => Sampler::RangeChoice {
                        input,
                        min: min.0,
                        max: max.0,
                        in_range: b(self.compile(in_range)?),
                        out_of_range: b(self.compile(out_of_range)?),
                    },
                }
            }
            Df::IntervalSelect {
                input,
                thresholds,
                functions,
            } => {
                let input = b(self.compile(input)?);
                if thresholds.len() == 1 {
                    Sampler::IntervalSelectSingle {
                        input,
                        threshold: thresholds[0].0,
                        below: b(self.compile(&functions[0])?),
                        above: b(self.compile(&functions[functions.len() - 1])?),
                    }
                } else {
                    Sampler::IntervalSelect {
                        input,
                        thresholds: thresholds.iter().map(|t| t.0).collect(),
                        samplers: functions
                            .iter()
                            .map(|f| self.compile(f))
                            .collect::<Result<_, _>>()?,
                    }
                }
            }
            Df::Cache(_) => return Err("cache compiled before it was prepared".into()),
            Df::Prepared(id) => Sampler::Cache {
                id: *id,
                input: self.c.prepared[*id]
                    .sampler
                    .clone()
                    .ok_or("cache used while it is being prepared")?,
            },
            Df::BlendDensity(input) => Sampler::BlendDensity(b(self.compile(input)?)),
            Df::Interpolated { input, xz, y } => Sampler::Interpolated {
                input: b(self.compile(input)?),
                xz: *xz,
                y: *y,
                xz_inv: 1.0 / *xz as f32,
                y_inv: 1.0 / *y as f32,
            },
            Df::Slice {
                axis,
                coordinate,
                input,
            } => match (axis, &**input) {
                (
                    Axis::X | Axis::Z,
                    Df::Slice {
                        axis: inner_axis,
                        coordinate: inner_coordinate,
                        input: inner,
                    },
                ) if *inner_axis != *axis && *inner_axis != Axis::Y => {
                    let (x, z) = if *axis == Axis::X {
                        (*coordinate, *inner_coordinate)
                    } else {
                        (*inner_coordinate, *coordinate)
                    };
                    Sampler::SliceXz(b(self.compile(inner)?), x, z)
                }
                _ => {
                    let input = b(self.compile(input)?);
                    match axis {
                        Axis::X => Sampler::SliceX(input, *coordinate),
                        Axis::Y => Sampler::SliceY(input, *coordinate),
                        Axis::Z => Sampler::SliceZ(input, *coordinate),
                    }
                }
            },
            Df::FindTopSurface {
                density,
                upper,
                lower,
                cell,
            } => {
                let density = b(self.compile(density)?);
                let upper = b(self.compile(upper)?);
                Sampler::SliceY(
                    b(Sampler::FindTopSurface {
                        density,
                        upper,
                        lower: *lower,
                        cell: *cell,
                    }),
                    0,
                )
            }
            Df::Blended(p) => {
                let params = BlendedParameters {
                    xz_scale: p[0].0,
                    y_scale: p[1].0,
                    xz_factor: p[2].0,
                    y_factor: p[3].0,
                    smear_scale_multiplier: p[4].0,
                };
                let mut random = if self.ctx.settings.legacy_random_source {
                    Random::legacy(self.ctx.seed)
                } else {
                    self.ctx.positional.from_hash_of(TERRAIN_SEED)
                };
                let set = params.fbm_set(&mut random);
                let (xz, y) = (params.xz_multiplier(), params.y_multiplier());
                let noise = |stack, xz, y| Sampler::Noise {
                    noise: Arc::new(stack),
                    xz,
                    y,
                };
                let min = noise(set.min_limit, xz, y);
                let max = noise(set.max_limit, xz, y);
                let main = noise(set.main, xz / params.xz_factor, y / params.y_factor);
                let choice = Sampler::Clamp(b(Sampler::ConstAdd(b(main), 0.5)), 0.0, 1.0);
                Sampler::Lerp(Box::new([choice, min, max]))
            }
        })
    }

    fn compile_binary(&mut self, op: Binary, l: &Df, r: &Df) -> Result<Sampler, String> {
        let b = Box::new;
        let left = self.compile(l)?;
        let right = self.compile(r)?;
        let (lc, rc) = (constant(l), constant(r));
        Ok(match op {
            Binary::Add => match (lc, rc) {
                (Some(c), _) => Sampler::ConstAdd(b(right), c),
                (_, Some(c)) => Sampler::ConstAdd(b(left), c),
                _ => Sampler::Add(b(left), b(right)),
            },
            Binary::Sub => match (lc, rc) {
                (Some(c), _) => Sampler::ConstSub(c, b(right)),
                (_, Some(c)) => Sampler::ConstAdd(b(left), -c),
                _ => Sampler::Sub(b(left), b(right)),
            },
            Binary::Mul => match (lc, rc) {
                (Some(c), _) => Sampler::ConstMul(b(right), c),
                (_, Some(c)) => Sampler::ConstMul(b(left), c),
                _ => Sampler::Mul(b(left), b(right)),
            },
            Binary::Div => match (lc, rc) {
                (Some(c), _) => Sampler::ConstDiv(c, b(right)),
                (_, Some(c)) => Sampler::ConstMul(b(left), 1.0 / c),
                _ => Sampler::Div(b(left), b(right)),
            },
            Binary::Min => {
                let (lr, rr) = (l.range(self)?, r.range(self)?);
                if lr.max < rr.min {
                    left
                } else if rr.max < lr.min {
                    right
                } else {
                    match (lc, rc) {
                        (Some(c), _) => Sampler::ConstMin(b(right), c),
                        (_, Some(c)) => Sampler::ConstMin(b(left), c),
                        _ => Sampler::Min(b(left), b(right), rr.min),
                    }
                }
            }
            Binary::Max => {
                let (lr, rr) = (l.range(self)?, r.range(self)?);
                if lr.min > rr.max {
                    left
                } else if rr.min > lr.max {
                    right
                } else {
                    match (lc, rc) {
                        (Some(c), _) => Sampler::ConstMax(b(right), c),
                        (_, Some(c)) => Sampler::ConstMax(b(left), c),
                        _ => Sampler::Max(b(left), b(right), rr.max),
                    }
                }
            }
        })
    }

    fn compile_spline(
        &mut self,
        spline: &Spline,
        indices: &mut HashMap<Df, usize>,
        coordinates: &mut Vec<Sampler>,
    ) -> Result<SplineNode, String> {
        Ok(match spline {
            Spline::Constant(v) => SplineNode::Constant(v.0),
            Spline::Multipoint {
                coordinate,
                locations,
                values,
                derivatives,
            } => {
                let index = match indices.get(coordinate) {
                    Some(&i) => i,
                    None => {
                        let i = coordinates.len();
                        coordinates.push(self.compile(coordinate)?);
                        indices.insert(coordinate.clone(), i);
                        i
                    }
                };
                SplineNode::Multipoint {
                    coordinate: index,
                    locations: locations.iter().map(|l| l.0).collect(),
                    values: values
                        .iter()
                        .map(|v| self.compile_spline(v, indices, coordinates))
                        .collect::<Result<_, _>>()?,
                    derivatives: derivatives.iter().map(|d| d.0).collect(),
                }
            }
        })
    }
}

/// Where a decoration finds structure starts: their views for references
/// (which read nothing placement changes) and each one to place, mutably.
/// A start chunk `chunk` keeps for natural spawning (VMC-042b): its box and
/// its pieces that reach the chunk's columns.
fn spawn_structure(def: &StructureDef, start: &Start, chunk: (i32, i32)) -> SpawnStructure {
    let corners = |b: &crate::worldgen::structure::piece::BoundingBox| {
        [b.min_x, b.min_y, b.min_z, b.max_x, b.max_y, b.max_z]
    };
    let (x0, z0) = (chunk.0 * 16, chunk.1 * 16);
    SpawnStructure {
        structure: Arc::from(def.id.as_str()),
        bbox: corners(&start.bbox),
        pieces: start
            .pieces
            .iter()
            .filter(|p| p.bbox.intersects_xz(x0, z0, x0 + 15, z0 + 15))
            .map(|p| corners(&p.bbox))
            .collect(),
    }
}

pub trait StartStore {
    fn view(&self, chunk: (i32, i32)) -> Option<&[Start]>;
    fn place(
        &mut self,
        source: (i32, i32),
        structure: usize,
        f: &mut dyn FnMut(&mut Start) -> Result<(), String>,
    ) -> Result<(), String>;
}

/// An area's own starts by chunk (parity and benchmarks).
impl StartStore for HashMap<(i32, i32), Vec<Start>> {
    fn view(&self, chunk: (i32, i32)) -> Option<&[Start]> {
        self.get(&chunk).map(|v| v.as_slice())
    }

    fn place(
        &mut self,
        source: (i32, i32),
        structure: usize,
        f: &mut dyn FnMut(&mut Start) -> Result<(), String>,
    ) -> Result<(), String> {
        match self
            .get_mut(&source)
            .and_then(|list| list.iter_mut().find(|s| s.structure == structure))
        {
            Some(start) => f(start),
            None => Ok(()),
        }
    }
}

/// A dimension's start table around one decoration.
struct TableStarts<'a> {
    view: HashMap<(i32, i32), Vec<Start>>,
    around: &'a Around,
}

impl StartStore for TableStarts<'_> {
    fn view(&self, chunk: (i32, i32)) -> Option<&[Start]> {
        self.view.get(&chunk).map(|v| v.as_slice())
    }

    fn place(
        &mut self,
        source: (i32, i32),
        structure: usize,
        f: &mut dyn FnMut(&mut Start) -> Result<(), String>,
    ) -> Result<(), String> {
        self.around.with_start(source, structure, f)
    }
}

/// Single biome lookups: a multi-noise preset sampled at one quart (climate
/// point samples, fresh lookup history), or the End's biome source.
enum PointBiomes {
    /// A fixed biome source (VMC-028b).
    Fixed(u16),
    MultiNoise {
        samplers: Vec<Arc<Sampler>>,
        list: Arc<ParameterList>,
        ids: Vec<u16>,
    },
    End {
        erosion: Arc<Sampler>,
        ids: [u16; 5],
    },
}

impl PointBiomes {
    fn biome(&self, qx: i32, qy: i32, qz: i32) -> u16 {
        let mut ctx = Context::uncached();
        let (bx, by, bz) = (qx << 2, qy << 2, qz << 2);
        match self {
            PointBiomes::Fixed(biome) => *biome,
            PointBiomes::MultiNoise {
                samplers,
                list,
                ids,
            } => {
                let target: [i64; 6] =
                    std::array::from_fn(|i| quantize(samplers[i].value(&mut ctx, bx, by, bz)));
                ids[list.find(&target, &mut None) as usize]
            }
            PointBiomes::End { erosion, ids } => {
                let (cx, cz) = ((bx >> 4) as i64, (bz >> 4) as i64);
                if cx * cx + cz * cz <= 4096 {
                    return ids[0];
                }
                let wx = ((bx >> 4) * 2 + 1) * 8;
                let wz = ((bz >> 4) * 2 + 1) * 8;
                let height = erosion.value(&mut ctx, wx, by, wz) as f64;
                if height > 0.25 {
                    ids[1]
                } else if height >= -0.0625 {
                    ids[2]
                } else if height < -0.21875 {
                    ids[3]
                } else {
                    ids[4]
                }
            }
        }
    }
}

/// `NoiseBasedChunkGenerator.applyCarvingMask`: carved positions become what
/// the aquifer leaves at zero density; dirt uncovered below grass or mycelium
/// gets the rule's top material.
fn apply_carving_mask(
    env: &mut Worldgen,
    ctx: &mut Context,
    input: &SurfaceInput,
    chunk: &mut ChunkBlocks,
    aquifer: &mut Aquifer,
    mask: &CarvingMask,
) -> Result<(), String> {
    const FLUID: u8 = 2;
    const UNCARVABLE: u8 = 8;
    const GRASS_OR_MYCELIUM: u8 = 16;
    const DIRT: u8 = 32;
    let (min_x, min_z) = (chunk.chunk_x * 16, chunk.chunk_z * 16);
    for (x, z, bottom, top) in mask.segments() {
        let mut has_grass = false;
        let (wx, wz) = (min_x + x, min_z + z);
        for wy in (bottom..=top).rev() {
            let old = chunk.state(x, wy, z);
            if chunk.flag(old, UNCARVABLE) {
                continue;
            }
            if chunk.flag(old, GRASS_OR_MYCELIUM) {
                has_grass = true;
            }
            let Some(state) = aquifer.compute_substance(ctx, wx, wy, wz, 0.0) else {
                continue;
            };
            chunk.put(x, wy, z, state);
            let fluid = chunk.flag(Some(state), FLUID);
            if aquifer.should_schedule_fluid_update() && fluid {
                chunk.mark_fluid_update(x, wy, z);
            }
            if has_grass && chunk.flag(chunk.state(x, wy - 1, z), DIRT) {
                if let Some(material) =
                    surface::top_material(env, ctx, input, chunk, (wx, wy - 1, wz), fluid)?
                {
                    chunk.put(x, wy - 1, z, material);
                    if chunk.flag(Some(material), FLUID) {
                        chunk.mark_fluid_update(x, wy - 1, z);
                    }
                }
            }
        }
    }
    Ok(())
}

fn constant(function: &Df) -> Option<f32> {
    match function {
        Df::Constant(v) => Some(v.0),
        _ => None,
    }
}

/// A chunk's beardifier from the starts that reference it, per structure in
/// structure order and per structure in the chunk's reference order (vanilla
/// lists a chunk's structures in a hash map's order, which only changes how
/// overlapping structures' beards round); none without terrain-adapting
/// pieces near the chunk.
pub fn beardifier(
    registry: &StructureRegistry,
    starts: &HashMap<(i32, i32), Vec<Start>>,
    references: &[(usize, (i32, i32))],
    chunk: (i32, i32),
) -> Option<Arc<Beardifier>> {
    let visits = visit_order(references);
    let mut structures: Vec<usize> = visits.keys().copied().collect();
    structures.sort_unstable();
    let chunk_starts = structures.iter().flat_map(|structure| {
        visits[structure].iter().filter_map(move |source| {
            starts
                .get(source)
                .and_then(|list| list.iter().find(|s| s.structure == *structure))
        })
    });
    let beard = Beardifier::for_chunk(registry, chunk_starts, chunk);
    (!beard.is_empty()).then(|| Arc::new(beard))
}

/// The placed features that template pools' feature elements name, sorted.
fn pool_features(pools: &Json) -> Result<Vec<String>, String> {
    fn walk(element: &Json, out: &mut Vec<String>) -> Result<(), String> {
        match element.field("element_type")?.as_str()? {
            "minecraft:feature_pool_element" => {
                out.push(element.field("feature")?.as_str()?.to_string())
            }
            "minecraft:list_pool_element" => {
                for e in element.field("elements")?.as_array()? {
                    walk(e, out)?;
                }
            }
            _ => {}
        }
        Ok(())
    }
    let mut out = Vec::new();
    for (_, pool) in pools.entries()? {
        for entry in pool.field("elements")?.as_array()? {
            walk(entry.field("element")?, &mut out)?;
        }
    }
    out.sort();
    out.dedup();
    Ok(out)
}
