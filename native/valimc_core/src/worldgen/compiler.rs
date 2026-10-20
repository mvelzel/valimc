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

use std::collections::HashMap;
use std::sync::Arc;

use super::climate::{quantize, ParameterList};
use super::density::{
    Axis, Binary, Df, Env, ShiftKind, Simple, Spline, Tiling, ALL_AXES, AXIS_X, AXIS_Y, AXIS_Z,
};
use super::interval::{Interval, NAI};
use super::json::Json;
use super::noise::{BlendedParameters, NormalNoise, Simplex, Stack};
use super::random::{Positional, Random};
use super::sampler::{Context, Field, GradientKind, Sampler, SplineNode};
use super::terrain::{self, AquiferSamplers, FilledChunk, TerrainBlocks};
use super::volume::Volume;

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
}

/// The worldgen registries ValiMC reads from generated facts.
#[derive(Clone, Debug, Default)]
pub struct Registry {
    pub noises: HashMap<String, NormalNoise>,
    pub functions: HashMap<String, Df>,
    pub settings: HashMap<String, Settings>,
    /// Multi-noise biome parameter presets.
    pub biome_parameters: HashMap<String, Arc<ParameterList>>,
    /// Global state ids of air, water and lava.
    pub fluids: [u16; 3],
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
    /// Parses `noises.json`, `density_functions.json`, `noise_settings.json`
    /// (with default blocks and fluids as global state ids) and
    /// `biome_parameters.json`, with the state ids of `air`, `water` and
    /// `lava` in `blocks`.
    pub fn parse(
        noises: &Json,
        functions: &Json,
        settings: &Json,
        biome_parameters: &Json,
        blocks: &Json,
    ) -> Result<Registry, String> {
        let mut registry = Registry::default();
        let state = |json: &Json| -> Result<u16, String> {
            u16::try_from(json.as_i32()?).map_err(|_| "state id out of range".to_string())
        };
        registry.fluids = [
            state(blocks.field("air")?)?,
            state(blocks.field("water")?)?,
            state(blocks.field("lava")?)?,
        ];
        for (id, rows) in biome_parameters.entries()? {
            let list =
                ParameterList::parse(rows).map_err(|e| format!("biome parameters {id}: {e}"))?;
            registry.biome_parameters.insert(id.clone(), Arc::new(list));
        }
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
        let volume = Volume::new(
            [16, self.settings.height, 16],
            [
                chunk_x.wrapping_mul(16),
                self.settings.min_y,
                chunk_z.wrapping_mul(16),
            ],
            [1, 1, 1],
        )?;
        let [air, water, lava] = self.registry.fluids;
        let blocks = TerrainBlocks {
            air,
            water,
            lava,
            default_block: self.settings.default_block,
            default_fluid: self.settings.default_fluid,
        };
        let aquifer = if self.settings.aquifers.is_empty() {
            None
        } else {
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
            Some((samplers, positional))
        };
        let final_density = self.named("router:final_density")?;
        let final_density = self.sampler(&final_density)?;
        Ok(terrain::fill(
            &final_density,
            aquifer.as_ref().map(|(s, p)| (s, *p)),
            &volume,
            self.settings.sea_level,
            blocks,
        ))
    }

    pub fn biome_parameters(&self, preset: &str) -> Result<Arc<ParameterList>, String> {
        self.registry
            .biome_parameters
            .get(preset)
            .cloned()
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

fn constant(function: &Df) -> Option<f32> {
    match function {
        Df::Constant(v) => Some(v.0),
        _ => None,
    }
}
