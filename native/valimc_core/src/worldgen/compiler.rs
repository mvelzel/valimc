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

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

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
use super::region::{Area, ProtoChunk, Region};
use super::sampler::{Context, Field, GradientKind, Sampler, SplineNode};
use super::surface::{
    self, Biomes, ChunkBlocks, MaterialRegistry, MaterialSystem, Rule, SurfaceEnv, SurfaceInput,
    Terracotta,
};
use super::terrain::{self, Aquifer, AquiferSamplers, FilledChunk, TerrainBlocks};
use super::volume::Volume;
use crate::column::{
    Column, HEIGHT as COLUMN_HEIGHT, MIN_Y as COLUMN_MIN_Y, SECTIONS as COLUMN_SECTIONS,
};
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
    /// Decoration (VMC-025), when present: features, placed features, state
    /// providers, the feature order, survival facts, the block registry and
    /// per-state block facts.
    pub decoration: Option<DecorationJson<'a>>,
}

pub struct DecorationJson<'a> {
    pub features: &'a Json,
    pub placed_features: &'a Json,
    pub block_state_providers: &'a Json,
    pub feature_order: &'a Json,
    pub support: &'a Json,
    pub shapes: Option<&'a Json>,
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
            decoration: match json.get("features") {
                None => None,
                Some(features) => Some(DecorationJson {
                    features,
                    placed_features: json.field("placed_features")?,
                    block_state_providers: json.field("block_state_providers")?,
                    feature_order: json.field("feature_order")?,
                    support: json.field("support")?,
                    shapes: json.get("shapes"),
                    block_registry: json.field("block_registry")?,
                    block_facts: json.field("block_facts")?,
                }),
            },
        })
    }
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
    /// The overworld's decoration (VMC-025), when its facts were given.
    pub decoration: Option<Arc<Decoration>>,
}

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
    /// rules are global state ids.
    pub fn parse(facts: &Facts) -> Result<Registry, String> {
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
        if let Some(json) = &facts.decoration {
            let table = Arc::new(BlockTable::parse(json.block_registry, json.block_facts)?);
            let (_, source) = registry
                .biome_parameters
                .get("minecraft:overworld")
                .ok_or("no overworld biome parameters")?;
            let mut source_biomes = source.clone();
            source_biomes.sort_unstable();
            source_biomes.dedup();
            let biomes = registry.biomes.clone();
            let decoration = Decoration::parse(
                table,
                DecorationFacts {
                    features: json.features,
                    placed_features: json.placed_features,
                    block_state_providers: json.block_state_providers,
                    order: json.feature_order.field("minecraft:overworld")?,
                    biomes: facts.biomes,
                    support: json.support,
                    shapes: json.shapes,
                    biome_ids: &|name| biomes.id(name),
                    biome_count: biomes.names.len(),
                    source_biomes: &source_biomes,
                    climates: biomes.climate.clone(),
                },
                GenContext {
                    min_y: -64,
                    height: 384,
                    sea_level: 63,
                },
            )
            .map_err(|e| format!("decoration: {e}"))?;
            registry.decoration = Some(Arc::new(decoration));
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
            };
            registry.settings.insert(id.clone(), parsed);
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

/// Noises and compiled samplers for one seed and noise settings.
pub struct Worldgen {
    registry: Arc<Registry>,
    settings: Settings,
    seed: i64,
    positional: Positional,
    noises: HashMap<String, Arc<Stack>>,
    prepared: Vec<Prepared>,
    prepared_keys: HashMap<Df, usize>,
    samplers: HashMap<Df, Arc<Sampler>>,
    material_system: Option<Arc<MaterialSystem>>,
    /// Chunk biomes and carver biomes by biome source and chunk: both pure, so
    /// neighbouring chunks share them (bounded).
    chunk_biomes: HashMap<(String, i32, i32), Arc<Vec<u16>>>,
    carver_biomes: HashMap<(String, i32, i32), u16>,
}

const BIOME_CACHE_LIMIT: usize = 4096;
const CARVER_BIOME_CACHE_LIMIT: usize = 65536;

impl SurfaceEnv for Worldgen {
    fn sampler(&mut self, function: &Df) -> Result<Arc<Sampler>, String> {
        Worldgen::sampler(self, function)
    }

    fn noise(&mut self, id: &str) -> Result<Arc<Stack>, String> {
        Worldgen::noise(self, id)
    }

    fn random_factory(&mut self, name: &str) -> Positional {
        self.positional.from_hash_of(name).fork_positional()
    }
}

const TEMPERATURE_NETHER: &str = "minecraft:nether/temperature";
const VEGETATION_NETHER: &str = "minecraft:nether/vegetation";
const TERRAIN_SEED: &str = "minecraft:terrain";
const AQUIFER_SEED: &str = "minecraft:aquifer";

impl Env for Worldgen {
    fn function(&self, id: &str) -> Result<&Df, String> {
        self.registry
            .functions
            .get(id)
            .ok_or_else(|| format!("unknown density function {id}"))
    }

    fn noise_range(&self, id: &str) -> Result<f32, String> {
        Ok(self.normal_noise(id)?.range_bound())
    }

    fn prepared(&self, index: usize) -> (Interval, u8) {
        self.prepared
            .get(index)
            .map_or((NAI, 0), |p| (p.range, p.axes))
    }
}

impl Worldgen {
    pub fn new(registry: Arc<Registry>, seed: i64, settings: &str) -> Result<Worldgen, String> {
        let settings = registry
            .settings
            .get(settings)
            .ok_or_else(|| format!("unknown noise settings {settings}"))?
            .clone();
        let mut base = if settings.legacy_random_source {
            Random::legacy(seed)
        } else {
            Random::xoroshiro(seed)
        };
        Ok(Worldgen {
            positional: base.fork_positional(),
            registry,
            settings,
            seed,
            noises: HashMap::new(),
            prepared: Vec::new(),
            prepared_keys: HashMap::new(),
            samplers: HashMap::new(),
            material_system: None,
            chunk_biomes: HashMap::new(),
            carver_biomes: HashMap::new(),
        })
    }

    pub fn settings(&self) -> &Settings {
        &self.settings
    }

    fn normal_noise(&self, id: &str) -> Result<&NormalNoise, String> {
        self.registry
            .noises
            .get(id)
            .ok_or_else(|| format!("unknown noise {id}"))
    }

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
            let mut random = Random::legacy(self.seed.wrapping_add(offset));
            return Ok(Arc::new(
                self.normal_noise(id)?.create_legacy_nether(&mut random)?,
            ));
        }
        if let Some(noise) = self.noises.get(id) {
            return Ok(noise.clone());
        }
        let noise = Arc::new(
            self.normal_noise(id)?
                .create(&mut self.positional.from_hash_of(id)),
        );
        self.noises.insert(id.to_string(), noise.clone());
        Ok(noise)
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
        let (min_y, height) = (self.settings.min_y, self.settings.height);
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
        self.terrain(chunk_x, chunk_z, None, false)
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
        biome_source: &str,
        carve: bool,
    ) -> Result<FilledChunk, String> {
        self.terrain(chunk_x, chunk_z, Some(biome_source), carve)
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
        biome_source: Option<&str>,
        carve: bool,
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
        let (min_quart, quart_height) = (settings.min_y >> 2, settings.height >> 2);
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
            for dx in -8..=8 {
                for dz in -8..=8 {
                    let source = (chunk_x + dx, chunk_z + dz);
                    let key = (biome_source.to_string(), source.0, source.1);
                    let biome = match self.carver_biomes.get(&key) {
                        Some(&biome) => biome,
                        None => {
                            let biome = point_biomes.biome(source.0 * 4, 0, source.1 * 4);
                            if self.carver_biomes.len() >= CARVER_BIOME_CACHE_LIMIT {
                                self.carver_biomes.clear();
                            }
                            self.carver_biomes.insert(key, biome);
                            biome
                        }
                    };
                    for (index, carver) in registry.biome_carvers[biome as usize].iter().enumerate()
                    {
                        let carver = &registry.carvers[carver];
                        carver::set_large_feature_seed(
                            &mut random,
                            self.seed.wrapping_add(index as i64),
                            source.0,
                            source.1,
                        );
                        if carver.is_start(&mut random) {
                            carver.carve(
                                context,
                                &mut random,
                                (chunk_x, chunk_z),
                                source,
                                &mut mask,
                            );
                        }
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

    /// Single biome lookups for `biome_source` (vanilla's uncached biome
    /// resolver), each from a fresh lookup history.
    fn point_biomes(&mut self, biome_source: &str) -> Result<PointBiomes, String> {
        if biome_source == "minecraft:the_end" {
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
        let (list, ids) = self
            .registry
            .biome_parameters
            .get(biome_source)
            .cloned()
            .ok_or_else(|| format!("unknown biome source {biome_source}"))?;
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
        if let Some(system) = &self.material_system {
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
        self.material_system = Some(system.clone());
        Ok(system)
    }

    fn cached_chunk_biomes(
        &mut self,
        biome_source: &str,
        chunk_x: i32,
        chunk_z: i32,
    ) -> Result<Arc<Vec<u16>>, String> {
        let key = (biome_source.to_string(), chunk_x, chunk_z);
        if let Some(biomes) = self.chunk_biomes.get(&key) {
            return Ok(biomes.clone());
        }
        let biomes = Arc::new(self.chunk_biome_ids(biome_source, chunk_x, chunk_z)?);
        if self.chunk_biomes.len() >= BIOME_CACHE_LIMIT {
            self.chunk_biomes.clear();
        }
        self.chunk_biomes.insert(key, biomes.clone());
        Ok(biomes)
    }

    /// Decoration over an area (VMC-025): the `size` × `size` chunks from
    /// (`x`, `z`) get their terrain (as `build_terrain` with carvers, with
    /// its fluid post-processing marks) and chunk biomes, then each chunk in
    /// `order` is decorated through a region centred on it. `included`
    /// limits the placed features by (step, global index).
    pub fn decorate_area(
        &mut self,
        biome_source: &str,
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
        biome_source: &str,
        (x, z): (i32, i32),
        size: i32,
        order: &[(i32, i32)],
        included: Option<&HashSet<(usize, usize)>>,
    ) -> Result<(Area, std::time::Duration), String> {
        let decoration = self
            .registry
            .decoration
            .clone()
            .ok_or("no decoration facts")?;
        let mut chunks = Vec::with_capacity((size * size) as usize);
        for dz in 0..size {
            for dx in 0..size {
                let (cx, cz) = (x + dx, z + dz);
                let filled = self.build_terrain(cx, cz, biome_source, true)?;
                let biomes = self.cached_chunk_biomes(biome_source, cx, cz)?;
                let mut chunk = ProtoChunk::new(cx, cz, filled.blocks, biomes, &decoration.table);
                for (fx, fy, fz) in filled.fluid_updates {
                    chunk.mark([fx, fy, fz]);
                }
                chunks.push(chunk);
            }
        }
        let mut area = Area { x, z, size, chunks };
        let zoom_seed = surface::biome_zoom_seed(self.seed);
        let start = std::time::Instant::now();
        for &(cx, cz) in order {
            let mut region = Region::new(
                &mut area,
                &decoration.table,
                (cx, cz),
                self.seed,
                zoom_seed,
                self.settings.sea_level,
            )?;
            decoration
                .decorate(&mut region, included)
                .map_err(|e| format!("decorating {cx}, {cz}: {e}"))?;
        }
        Ok((area, start.elapsed()))
    }

    /// A generated chunk as a ValiMC column (VMC-024d): the carved terrain in
    /// 24 sections and its biomes as protocol biome ids (`protocol_biomes`,
    /// indexed by biome registry id), with each column's highest non-air block
    /// (`WORLD_SURFACE_WG - 1`, z * 16 + x order; below the world when none).
    pub fn generate_column(
        &mut self,
        chunk_x: i32,
        chunk_z: i32,
        biome_source: &str,
        protocol_biomes: &[u16],
    ) -> Result<(Column, [i32; 256]), String> {
        if self.settings.min_y != COLUMN_MIN_Y || self.settings.height != COLUMN_HEIGHT as i32 {
            return Err("columns hold the overworld's height only".into());
        }
        let filled = self.build_terrain(chunk_x, chunk_z, biome_source, true)?;
        let biomes = self.cached_chunk_biomes(biome_source, chunk_x, chunk_z)?;
        let height = COLUMN_HEIGHT;
        let at = |x: usize, y: usize, z: usize| filled.blocks[y + (x + z * 16) * height];
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
            let cells: Vec<u16> = biomes[s * 64..s * 64 + 64]
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
                if let Some(top) = (0..height)
                    .rev()
                    .find(|&y| flags[at(x, y, z) as usize] & 1 == 0)
                {
                    heights[z * 16 + x] = COLUMN_MIN_Y + top as i32;
                }
            }
        }
        Ok((
            Column {
                sections,
                biomes: Some(section_biomes),
            },
            heights,
        ))
    }

    /// A chunk's biomes as registry ids (sections from the bottom, each in
    /// index order y, z, x), with a fresh lookup history.
    pub fn chunk_biome_ids(
        &mut self,
        biome_source: &str,
        chunk_x: i32,
        chunk_z: i32,
    ) -> Result<Vec<u16>, String> {
        if biome_source == "minecraft:the_end" {
            return self.end_biomes(chunk_x, chunk_z);
        }
        let (list, ids) = self
            .registry
            .biome_parameters
            .get(biome_source)
            .cloned()
            .ok_or_else(|| format!("unknown biome source {biome_source}"))?;
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
        let sections = self.settings.height / 16;
        let min_quart = self.settings.min_y >> 2;
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
        if let Some(sampler) = self.samplers.get(function) {
            return Ok(sampler.clone());
        }
        let optimized = self.optimize(function)?;
        let sampler = Arc::new(self.compile(&optimized)?);
        self.samplers.insert(function.clone(), sampler.clone());
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
        if let Some(&id) = self.prepared_keys.get(input) {
            return Ok(id);
        }
        let id = self.prepared.len();
        self.prepared.push(Prepared {
            range: NAI,
            axes: 0,
            sampler: None,
        });
        let optimized = self.optimize(input)?;
        let sampler = self.compile(&optimized)?;
        self.prepared[id] = Prepared {
            range: optimized.range(self)?,
            axes: optimized.axes(self)?,
            sampler: Some(Arc::new(sampler)),
        };
        self.prepared_keys.insert(input.clone(), id);
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
                let mut random = Random::legacy(self.seed);
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
                input: self.prepared[*id]
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
                let mut random = if self.settings.legacy_random_source {
                    Random::legacy(self.seed)
                } else {
                    self.positional.from_hash_of(TERRAIN_SEED)
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

/// Single biome lookups: a multi-noise preset sampled at one quart (climate
/// point samples, fresh lookup history), or the End's biome source.
enum PointBiomes {
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
