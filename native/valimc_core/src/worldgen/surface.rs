//! Material rules (VMC-024b): vanilla 26.3's `MaterialSystem.buildSurface`,
//! which replaces a filled chunk's stone with surface materials, bedrock and
//! ore veins by the noise settings' material rule, and extends eroded badlands
//! pillars and frozen-ocean icebergs.
//!
//! Rules read their context lazily as vanilla's `MaterialRuleContext` does:
//! noises once per column or block, biomes through vanilla's fuzzy biome zoom,
//! and densities through the noise chunk's cached sampling context, after the
//! ore-vein volumes vanilla samples when it compiles the rule.

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

use super::java::floor_f32;
use super::json::Json;
use super::noise::{Simplex, Stack};
use super::random::{sha256, Positional, Random};
use super::sampler::{Context, Sampler};
use super::volume::Volume;

/// `DimensionType.WAY_BELOW_MIN_Y`.
const WAY_BELOW_MIN_Y: i32 = -32512;

// ---------------------------------------------------------------- biomes

/// A biome's climate, as surfaces read it.
#[derive(Clone, Copy, Debug)]
pub struct BiomeClimate {
    pub temperature: f32,
    /// `temperature_modifier: frozen`.
    pub frozen: bool,
}

/// The biome registry: names and climates, indexed in registry order.
#[derive(Clone, Debug, Default)]
pub struct Biomes {
    pub names: Vec<String>,
    pub climate: Vec<BiomeClimate>,
    index: HashMap<String, u16>,
}

impl Biomes {
    pub fn parse(json: &Json) -> Result<Biomes, String> {
        let mut biomes = Biomes::default();
        for (name, entry) in json.entries()? {
            let frozen = match entry.get("temperature_modifier") {
                None => false,
                Some(m) => match m.as_str()? {
                    "none" => false,
                    "frozen" => true,
                    other => return Err(format!("unknown temperature modifier {other}")),
                },
            };
            biomes.index.insert(name.clone(), biomes.names.len() as u16);
            biomes.names.push(name.clone());
            biomes.climate.push(BiomeClimate {
                temperature: entry.field("temperature")?.as_f64()? as f32,
                frozen,
            });
        }
        Ok(biomes)
    }

    pub fn id(&self, name: &str) -> Result<u16, String> {
        self.index
            .get(name)
            .copied()
            .ok_or_else(|| format!("unknown biome {name}"))
    }
}

/// Vanilla's global temperature noises (`Biome.TEMPERATURE_NOISE`,
/// `FROZEN_TEMPERATURE_NOISE` and `BIOME_INFO_NOISE`).
struct TemperatureNoises {
    temperature: Simplex,
    frozen: [(Simplex, f64, f32); 3],
    info: Simplex,
}

fn temperature_noises() -> &'static TemperatureNoises {
    static NOISES: OnceLock<TemperatureNoises> = OnceLock::new();
    NOISES.get_or_init(|| {
        let mut frozen_random = Random::legacy(3456);
        let a = Simplex::new(&mut frozen_random, true);
        let b = Simplex::new(&mut frozen_random, true);
        let c = Simplex::new(&mut frozen_random, true);
        TemperatureNoises {
            temperature: Simplex::new(&mut Random::legacy(1234), true),
            frozen: [
                (a, 1.0, 0.14285715),
                (b, 0.5, 0.2857143),
                (c, 0.25, 0.5714286),
            ],
            info: Simplex::new(&mut Random::legacy(2345), true),
        }
    })
}

/// `Biome.BIOME_INFO_NOISE.get(x, z)`.
pub fn biome_info_noise(x: f64, z: f64) -> f32 {
    temperature_noises().info.get_2d(x, z)
}

/// `Biome.getTemperature`: the frozen modifier, then cooling above the snow
/// line.
pub fn temperature(climate: &BiomeClimate, x: i32, y: i32, z: i32, sea_level: i32) -> f32 {
    let noises = temperature_noises();
    let mut adjusted = climate.temperature;
    if climate.frozen {
        let mut large = 0.0f32;
        for (noise, frequency, amplitude) in &noises.frozen {
            large +=
                amplitude * noise.get_2d(x as f64 * 0.05 * frequency, z as f64 * 0.05 * frequency);
        }
        let large = (large * 7.0) as f64;
        let edge = noises.info.get_2d(x as f64 * 0.2, z as f64 * 0.2) as f64;
        if large + edge < 0.3 && (noises.info.get_2d(x as f64 * 0.09, z as f64 * 0.09) as f64) < 0.8
        {
            adjusted = 0.2;
        }
    }
    let snow_level = sea_level + 17;
    if y > snow_level {
        let v = noises
            .temperature
            .get_2d((x as f32 / 8.0) as f64, (z as f32 / 8.0) as f64)
            * 8.0;
        adjusted - (v + y as f32 - snow_level as f32) * 0.05 / 40.0
    } else {
        adjusted
    }
}

/// `BiomeManager.obfuscateSeed`: the first eight bytes of the SHA-256 of the
/// seed, both little-endian.
pub fn biome_zoom_seed(seed: i64) -> i64 {
    let digest = sha256(&seed.to_le_bytes());
    i64::from_le_bytes(digest[..8].try_into().expect("eight bytes"))
}

fn lcg(value: i64, c: i64) -> i64 {
    value
        .wrapping_mul(
            value
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407),
        )
        .wrapping_add(c)
}

fn fiddle(value: i64) -> f64 {
    ((value >> 24).rem_euclid(1024) as f64 / 1024.0 - 0.5) * 0.9
}

/// A quart corner's fiddle offsets (x, y, z) for `zoom`.
fn corner_fiddles(seed: i64, cx: i32, cy: i32, cz: i32) -> [f64; 3] {
    let mut r = seed;
    for c in [cx, cy, cz, cx, cy, cz] {
        r = lcg(r, c as i64);
    }
    let fx = fiddle(r);
    r = lcg(r, seed);
    let fy = fiddle(r);
    r = lcg(r, seed);
    [fx, fy, fiddle(r)]
}

/// `zoom` for the blocks of one chunk column, each quart corner's fiddles
/// computed once instead of once per block (the same arithmetic, so the same
/// results); positions outside the column fall back to `zoom`.
pub struct ChunkZoom {
    seed: i64,
    min: (i32, i32, i32),
    size: (i32, i32, i32),
    corners: std::cell::RefCell<Vec<[f64; 3]>>,
}

impl ChunkZoom {
    pub fn new(seed: i64, chunk_x: i32, chunk_z: i32, min_y: i32, height: i32) -> Self {
        let corner = |block: i32| (block - 2) >> 2;
        let min = (corner(chunk_x * 16), corner(min_y), corner(chunk_z * 16));
        let size = (
            corner(chunk_x * 16 + 15) - min.0 + 2,
            corner(min_y + height - 1) - min.1 + 2,
            corner(chunk_z * 16 + 15) - min.2 + 2,
        );
        let cells = (size.0 * size.1 * size.2) as usize;
        Self {
            seed,
            min,
            size,
            corners: std::cell::RefCell::new(vec![[f64::NAN; 3]; cells]),
        }
    }

    pub fn zoom(&self, x: i32, y: i32, z: i32) -> (i32, i32, i32) {
        let (ax, ay, az) = (x - 2, y - 2, z - 2);
        let (px, py, pz) = (ax >> 2, ay >> 2, az >> 2);
        let (ox, oy, oz) = (px - self.min.0, py - self.min.1, pz - self.min.2);
        if ox < 0
            || oy < 0
            || oz < 0
            || ox + 1 >= self.size.0
            || oy + 1 >= self.size.1
            || oz + 1 >= self.size.2
        {
            return zoom(self.seed, x, y, z);
        }
        let (fx, fy, fz) = (
            (ax & 3) as f64 / 4.0,
            (ay & 3) as f64 / 4.0,
            (az & 3) as f64 / 4.0,
        );
        let mut corners = self.corners.borrow_mut();
        let mut best = 0;
        let mut best_distance = f64::INFINITY;
        for i in 0..8 {
            let (xe, ye, ze) = (i & 4 == 0, i & 2 == 0, i & 1 == 0);
            let (cx, cy, cz) = (ox + !xe as i32, oy + !ye as i32, oz + !ze as i32);
            let slot = ((cx * self.size.1 + cy) * self.size.2 + cz) as usize;
            if corners[slot][0].is_nan() {
                corners[slot] =
                    corner_fiddles(self.seed, cx + self.min.0, cy + self.min.1, cz + self.min.2);
            }
            let [fx2, fy2, fz2] = corners[slot];
            let (dx, dy, dz) = (
                if xe { fx } else { fx - 1.0 },
                if ye { fy } else { fy - 1.0 },
                if ze { fz } else { fz - 1.0 },
            );
            let sq = |v: f64| v * v;
            let distance = sq(dz + fz2) + sq(dy + fy2) + sq(dx + fx2);
            if best_distance > distance {
                best = i;
                best_distance = distance;
            }
        }
        (
            px + (best & 4 != 0) as i32,
            py + (best & 2 != 0) as i32,
            pz + (best & 1 != 0) as i32,
        )
    }
}

/// `BiomeManager.getBiome`: the quart whose fiddled corner is closest to a
/// block.
pub fn zoom(seed: i64, x: i32, y: i32, z: i32) -> (i32, i32, i32) {
    let (ax, ay, az) = (x - 2, y - 2, z - 2);
    let (px, py, pz) = (ax >> 2, ay >> 2, az >> 2);
    let (fx, fy, fz) = (
        (ax & 3) as f64 / 4.0,
        (ay & 3) as f64 / 4.0,
        (az & 3) as f64 / 4.0,
    );
    let mut best = 0;
    let mut best_distance = f64::INFINITY;
    for i in 0..8 {
        let (xe, ye, ze) = (i & 4 == 0, i & 2 == 0, i & 1 == 0);
        let (cx, cy, cz) = (px + !xe as i32, py + !ye as i32, pz + !ze as i32);
        let (dx, dy, dz) = (
            if xe { fx } else { fx - 1.0 },
            if ye { fy } else { fy - 1.0 },
            if ze { fz } else { fz - 1.0 },
        );
        let [fx2, fy2, fz2] = corner_fiddles(seed, cx, cy, cz);
        let sq = |v: f64| v * v;
        let distance = sq(dz + fz2) + sq(dy + fy2) + sq(dx + fx2);
        if best_distance > distance {
            best = i;
            best_distance = distance;
        }
    }
    (
        px + (best & 4 != 0) as i32,
        py + (best & 2 != 0) as i32,
        pz + (best & 1 != 0) as i32,
    )
}

// ---------------------------------------------------------------- data

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Anchor {
    Absolute(i32),
    AboveBottom(i32),
    BelowTop(i32),
    SeaLevel(i32),
}

impl Anchor {
    pub(crate) fn parse_json(json: &Json) -> Result<Anchor, String> {
        Anchor::parse(json)
    }

    fn parse(json: &Json) -> Result<Anchor, String> {
        let [(key, value)] = json.entries()? else {
            return Err("a vertical anchor has one field".into());
        };
        let n = value.as_i32()?;
        match key.as_str() {
            "absolute" => Ok(Anchor::Absolute(n)),
            "above_bottom" => Ok(Anchor::AboveBottom(n)),
            "below_top" => Ok(Anchor::BelowTop(n)),
            "relative_to_sea_level" => Ok(Anchor::SeaLevel(n)),
            other => Err(format!("unknown vertical anchor {other}")),
        }
    }

    /// `VerticalAnchor.resolveY` against a generation context.
    pub fn resolve(self, min_y: i32, depth: i32, sea_level: i32) -> i32 {
        match self {
            Anchor::Absolute(y) => y,
            Anchor::AboveBottom(n) => min_y + n,
            Anchor::BelowTop(n) => depth - 1 + min_y - n,
            Anchor::SeaLevel(n) => sea_level + n,
        }
    }
}

#[derive(Clone, Debug)]
pub enum Condition {
    Biome(Vec<u16>),
    Noise {
        noise: String,
        min: f64,
        max: f64,
        three_d: bool,
    },
    VerticalGradient {
        random: String,
        true_below: Anchor,
        false_above: Anchor,
    },
    Y {
        anchor: Anchor,
        multiplier: i32,
        add_stone_depth: bool,
    },
    Water {
        offset: i32,
        multiplier: i32,
        add_stone_depth: bool,
    },
    Temperature,
    Steep,
    Not(Box<Condition>),
    Hole,
    AbovePreliminarySurface,
    StoneDepth {
        offset: i32,
        add_surface_depth: bool,
        secondary_range: i32,
        ceiling: bool,
    },
    Ref(String),
}

#[derive(Clone, Debug)]
pub enum Rule {
    Block(u16),
    Bandlands,
    Sequence(Vec<Rule>),
    Condition(Condition, Box<Rule>),
    OreVein {
        ore: u16,
        raw_ore: u16,
        filler: u16,
        raw_ore_chance: f32,
        density: super::density::Df,
        richness: super::density::Df,
        gap: super::density::Df,
    },
    Ref(String),
}

fn kind(json: &Json) -> Result<String, String> {
    let t = json.field("type")?.as_str()?;
    Ok(t.strip_prefix("minecraft:").unwrap_or(t).to_string())
}

fn state(json: &Json, key: &str) -> Result<u16, String> {
    u16::try_from(json.field(key)?.as_i32()?).map_err(|_| format!("bad state id in {key}"))
}

impl Condition {
    pub fn parse(json: &Json, biomes: &Biomes) -> Result<Condition, String> {
        if let Json::String(id) = json {
            return Ok(Condition::Ref(super::density::identifier(id)));
        }
        let int = |key: &str| json.field(key)?.as_i32();
        let flag = |key: &str| json.field(key)?.as_bool();
        Ok(match kind(json)?.as_str() {
            "biome" => {
                // A holder set: one identifier or a list of them.
                let field = json.field("biome_is")?;
                let names = match field {
                    Json::String(_) => std::slice::from_ref(field),
                    other => other.as_array()?,
                };
                Condition::Biome(
                    names
                        .iter()
                        .map(|b| biomes.id(&super::density::identifier(b.as_str()?)))
                        .collect::<Result<_, _>>()?,
                )
            }
            "noise_threshold" => Condition::Noise {
                noise: super::density::identifier(json.field("noise")?.as_str()?),
                min: json.field("min_threshold")?.as_f64()?,
                max: json.field("max_threshold")?.as_f64()?,
                three_d: json.get("is_3d").map_or(Ok(false), Json::as_bool)?,
            },
            "vertical_gradient" => Condition::VerticalGradient {
                random: super::density::identifier(json.field("random_name")?.as_str()?),
                true_below: Anchor::parse(json.field("true_at_and_below")?)?,
                false_above: Anchor::parse(json.field("false_at_and_above")?)?,
            },
            "y_above" => Condition::Y {
                anchor: Anchor::parse(json.field("anchor")?)?,
                multiplier: int("surface_depth_multiplier")?,
                add_stone_depth: flag("add_stone_depth")?,
            },
            "water" => Condition::Water {
                offset: int("offset")?,
                multiplier: int("surface_depth_multiplier")?,
                add_stone_depth: flag("add_stone_depth")?,
            },
            "temperature" => Condition::Temperature,
            "steep" => Condition::Steep,
            "not" => Condition::Not(Box::new(Condition::parse(json.field("invert")?, biomes)?)),
            "hole" => Condition::Hole,
            "above_preliminary_surface" => Condition::AbovePreliminarySurface,
            "stone_depth" => Condition::StoneDepth {
                offset: int("offset")?,
                add_surface_depth: flag("add_surface_depth")?,
                secondary_range: int("secondary_depth_range")?,
                ceiling: match json.field("surface_type")?.as_str()? {
                    "floor" => false,
                    "ceiling" => true,
                    other => return Err(format!("unknown surface type {other}")),
                },
            },
            other => return Err(format!("unknown material condition {other}")),
        })
    }
}

impl Rule {
    pub fn parse(json: &Json, biomes: &Biomes) -> Result<Rule, String> {
        if let Json::String(id) = json {
            return Ok(Rule::Ref(super::density::identifier(id)));
        }
        Ok(match kind(json)?.as_str() {
            "block" => Rule::Block(state(json, "result_state")?),
            "bandlands" => Rule::Bandlands,
            "sequence" => Rule::Sequence(
                json.field("sequence")?
                    .as_array()?
                    .iter()
                    .map(|r| Rule::parse(r, biomes))
                    .collect::<Result<_, _>>()?,
            ),
            "condition" => Rule::Condition(
                Condition::parse(json.field("if_true")?, biomes)?,
                Box::new(Rule::parse(json.field("then_run")?, biomes)?),
            ),
            "ore_vein" => Rule::OreVein {
                ore: state(json, "ore_block")?,
                raw_ore: state(json, "raw_ore_block")?,
                filler: state(json, "filler_block")?,
                raw_ore_chance: json.field("raw_ore_chance")?.as_f64()? as f32,
                density: super::density::Df::parse(json.field("density")?)?,
                richness: super::density::Df::parse(json.field("richness")?)?,
                gap: super::density::Df::parse(json.field("filler_gap")?)?,
            },
            other => return Err(format!("unknown material rule {other}")),
        })
    }
}

/// Material rules and conditions by identifier.
#[derive(Clone, Debug, Default)]
pub struct MaterialRegistry {
    pub rules: HashMap<String, Rule>,
    pub conditions: HashMap<String, Condition>,
}

impl MaterialRegistry {
    pub fn parse(
        rules: &Json,
        conditions: &Json,
        biomes: &Biomes,
    ) -> Result<MaterialRegistry, String> {
        let mut registry = MaterialRegistry::default();
        for (id, json) in rules.entries()? {
            registry.rules.insert(
                id.clone(),
                Rule::parse(json, biomes).map_err(|e| format!("material rule {id}: {e}"))?,
            );
        }
        for (id, json) in conditions.entries()? {
            let condition = Condition::parse(json, biomes)
                .map_err(|e| format!("material condition {id}: {e}"))?;
            registry.conditions.insert(id.clone(), condition);
        }
        Ok(registry)
    }
}

// ---------------------------------------------------------------- compiled

/// Densities a rule reads, prefilled over the chunk where vanilla prefills.
struct Densities {
    sampler: Arc<Sampler>,
    prefilled: Option<Vec<f32>>,
}

/// Biome registry ids as a bitset.
struct BiomeSet(Vec<u64>);

impl BiomeSet {
    fn new(ids: &[u16]) -> Self {
        let mut words = vec![0u64; ids.iter().map(|&b| b as usize / 64 + 1).max().unwrap_or(0)];
        for &b in ids {
            words[b as usize / 64] |= 1 << (b % 64);
        }
        Self(words)
    }

    fn contains(&self, biome: u16) -> bool {
        self.0
            .get(biome as usize / 64)
            .is_some_and(|word| word & (1 << (biome % 64)) != 0)
    }
}

enum CompiledCondition {
    Biome(BiomeSet),
    Noise {
        slot: usize,
        min: f64,
        max: f64,
        three_d: bool,
    },
    VerticalGradient {
        true_below: i32,
        false_above: i32,
        random: Positional,
    },
    Y {
        y: i32,
        multiplier: i32,
        add_stone_depth: bool,
    },
    Water {
        offset: i32,
        multiplier: i32,
        add_stone_depth: bool,
    },
    Temperature,
    Steep,
    Not(Box<CompiledCondition>),
    Hole,
    AbovePreliminarySurface,
    StoneDepth {
        offset: i32,
        add_surface_depth: bool,
        secondary_range: i32,
        ceiling: bool,
    },
}

enum CompiledRule {
    Block(u16),
    Bandlands,
    Sequence(Vec<CompiledRule>),
    Condition(CompiledCondition, Box<CompiledRule>),
    OreVein {
        ore: u16,
        raw_ore: u16,
        filler: u16,
        raw_ore_chance: f32,
        density: Densities,
        richness: Densities,
        gap: Densities,
        random: Positional,
    },
}

/// What compiling and applying rules needs from the worldgen state.
pub trait SurfaceEnv {
    fn sampler(&mut self, function: &super::density::Df) -> Result<Arc<Sampler>, String>;
    fn noise(&mut self, id: &str) -> Result<Arc<Stack>, String>;
    fn random_factory(&mut self, name: &str) -> Positional;
}

/// The chunk-level surface inputs.
pub struct SurfaceInput<'a> {
    pub materials: &'a MaterialRegistry,
    pub biomes: &'a Biomes,
    pub system: &'a MaterialSystem,
    pub rule: &'a Rule,
    /// Biome registry index at a block (vanilla's `BiomeManager.getBiome`).
    pub biome_at: &'a dyn Fn(i32, i32, i32) -> u16,
    /// Per state: bit 0 air, bit 1 contains a fluid, bit 2 a water block.
    pub flags: &'a [u8],
    pub min_y: i32,
    pub height: i32,
    pub sea_level: i32,
}

struct Compiler<'a, 'b> {
    input: &'a SurfaceInput<'b>,
    noise_slots: Vec<String>,
    expected: Volume,
}

impl Compiler<'_, '_> {
    fn condition(
        &mut self,
        env: &mut dyn SurfaceEnv,
        condition: &Condition,
    ) -> Result<CompiledCondition, String> {
        let i = self.input;
        Ok(match condition {
            Condition::Ref(id) => {
                let target = i
                    .materials
                    .conditions
                    .get(id)
                    .ok_or_else(|| format!("unknown material condition {id}"))?;
                self.condition(env, target)?
            }
            Condition::Biome(set) => CompiledCondition::Biome(BiomeSet::new(set)),
            Condition::Noise {
                noise,
                min,
                max,
                three_d,
            } => {
                env.noise(noise)?;
                self.noise_slots.push(noise.clone());
                let slot = self.noise_slots.len() - 1;
                CompiledCondition::Noise {
                    slot,
                    min: *min,
                    max: *max,
                    three_d: *three_d,
                }
            }
            Condition::VerticalGradient {
                random,
                true_below,
                false_above,
            } => CompiledCondition::VerticalGradient {
                true_below: true_below.resolve(i.min_y, i.height, i.sea_level),
                false_above: false_above.resolve(i.min_y, i.height, i.sea_level),
                random: env.random_factory(random),
            },
            Condition::Y {
                anchor,
                multiplier,
                add_stone_depth,
            } => CompiledCondition::Y {
                y: anchor.resolve(i.min_y, i.height, i.sea_level),
                multiplier: *multiplier,
                add_stone_depth: *add_stone_depth,
            },
            Condition::Water {
                offset,
                multiplier,
                add_stone_depth,
            } => CompiledCondition::Water {
                offset: *offset,
                multiplier: *multiplier,
                add_stone_depth: *add_stone_depth,
            },
            Condition::Temperature => CompiledCondition::Temperature,
            Condition::Steep => CompiledCondition::Steep,
            Condition::Not(inner) => CompiledCondition::Not(Box::new(self.condition(env, inner)?)),
            Condition::Hole => CompiledCondition::Hole,
            Condition::AbovePreliminarySurface => CompiledCondition::AbovePreliminarySurface,
            Condition::StoneDepth {
                offset,
                add_surface_depth,
                secondary_range,
                ceiling,
            } => CompiledCondition::StoneDepth {
                offset: *offset,
                add_surface_depth: *add_surface_depth,
                secondary_range: *secondary_range,
                ceiling: *ceiling,
            },
        })
    }

    fn densities(
        &mut self,
        env: &mut dyn SurfaceEnv,
        ctx: &mut Context,
        function: &super::density::Df,
        prefill: bool,
    ) -> Result<Densities, String> {
        let sampler = env.sampler(function)?;
        let prefilled = if prefill {
            let mut buffer = vec![0.0f32; self.expected.len()];
            sampler.fill(ctx, &mut buffer, &self.expected);
            Some(buffer)
        } else {
            None
        };
        Ok(Densities { sampler, prefilled })
    }

    fn rule(
        &mut self,
        env: &mut dyn SurfaceEnv,
        ctx: &mut Context,
        rule: &Rule,
    ) -> Result<CompiledRule, String> {
        Ok(match rule {
            Rule::Ref(id) => {
                let materials = self.input.materials;
                let target = materials
                    .rules
                    .get(id)
                    .ok_or_else(|| format!("unknown material rule {id}"))?;
                self.rule(env, ctx, target)?
            }
            Rule::Block(s) => CompiledRule::Block(*s),
            Rule::Bandlands => CompiledRule::Bandlands,
            Rule::Sequence(rules) if rules.len() == 1 => self.rule(env, ctx, &rules[0])?,
            Rule::Sequence(rules) => CompiledRule::Sequence(
                rules
                    .iter()
                    .map(|r| self.rule(env, ctx, r))
                    .collect::<Result<_, _>>()?,
            ),
            Rule::Condition(condition, then) => {
                let condition = self.condition(env, condition)?;
                CompiledRule::Condition(condition, Box::new(self.rule(env, ctx, then)?))
            }
            Rule::OreVein {
                ore,
                raw_ore,
                filler,
                raw_ore_chance,
                density,
                richness,
                gap,
            } => {
                let density = self.densities(env, ctx, density, true)?;
                let richness = self.densities(env, ctx, richness, true)?;
                let gap = self.densities(env, ctx, gap, false)?;
                CompiledRule::OreVein {
                    ore: *ore,
                    raw_ore: *raw_ore,
                    filler: *filler,
                    raw_ore_chance: *raw_ore_chance,
                    density,
                    richness,
                    gap,
                    random: env.random_factory("minecraft:ore"),
                }
            }
        })
    }
}

// ---------------------------------------------------------------- system

/// Vanilla's `MaterialSystem` for one seed: surface noises, clay bands and
/// the preliminary surface function.
pub struct MaterialSystem {
    pub default_block: u16,
    pub sea_level: i32,
    pub clay_bands: Vec<u16>,
    pub noise_random: Positional,
    pub preliminary_surface: Arc<Sampler>,
    pub clay_bands_offset: Arc<Stack>,
    pub surface: Arc<Stack>,
    pub surface_secondary: Arc<Stack>,
    pub badlands_pillar: Arc<Stack>,
    pub badlands_pillar_roof: Arc<Stack>,
    pub badlands_surface: Arc<Stack>,
    pub iceberg_pillar: Arc<Stack>,
    pub iceberg_pillar_roof: Arc<Stack>,
    pub iceberg_surface: Arc<Stack>,
    pub snow_block: u16,
    pub packed_ice: u16,
}

/// Terracotta states for clay bands: plain, orange, yellow, brown, red, white,
/// light gray.
pub type Terracotta = [u16; 7];

/// `MaterialSystem.generateBands`.
pub fn clay_bands(random: &mut Random, t: Terracotta) -> Vec<u16> {
    let [plain, orange, yellow, brown, red, white, light_gray] = t;
    let mut bands = vec![plain; 192];
    let len = bands.len() as i32;
    let mut i = 0i32;
    while i < len {
        i += random.next_int_bounded(5) + 1;
        if i < len {
            bands[i as usize] = orange;
        }
        i += 1;
    }
    let make = |random: &mut Random, bands: &mut Vec<u16>, base: i32, state: u16| {
        let count = random.next_int_bounded(15 - 6 + 1) + 6;
        for _ in 0..count {
            let width = base + random.next_int_bounded(3);
            let start = random.next_int_bounded(len);
            let mut p = 0;
            while start + p < len && p < width {
                bands[(start + p) as usize] = state;
                p += 1;
            }
        }
    };
    make(random, &mut bands, 1, yellow);
    make(random, &mut bands, 2, brown);
    make(random, &mut bands, 1, red);
    let white_count = random.next_int_bounded(15 - 9 + 1) + 9;
    let (mut n, mut start) = (0, 0i32);
    while n < white_count && start < len {
        bands[start as usize] = white;
        if start - 1 > 0 && random.next_bool() {
            bands[(start - 1) as usize] = light_gray;
        }
        if start + 1 < len && random.next_bool() {
            bands[(start + 1) as usize] = light_gray;
        }
        n += 1;
        start += random.next_int_bounded(16) + 4;
    }
    bands
}

/// Java's `Math.min(double, double)`.
fn dmin(a: f64, b: f64) -> f64 {
    if a.is_nan() {
        a
    } else if a == 0.0 && b == 0.0 && b.is_sign_negative() {
        b
    } else if a <= b {
        a
    } else {
        b
    }
}

/// Java's `Math.round(float)`.
fn java_round(a: f32) -> i32 {
    let bits = a.to_bits() as i32;
    let biased_exp = (bits & 0x7F80_0000) >> 23;
    let shift = (24 - 2 + 127) - biased_exp;
    if shift & -32 == 0 {
        let mut r = (bits & 0x007F_FFFF) | 0x0080_0000;
        if bits < 0 {
            r = -r;
        }
        ((r >> shift) + 1) >> 1
    } else {
        a as i32
    }
}

impl MaterialSystem {
    fn surface_depth(&self, x: i32, z: i32) -> i32 {
        let noise = self.surface.get(x as f64, 0.0, z as f64) as f64;
        (noise * 2.75 + 3.0 + self.noise_random.at(x, 0, z).next_double() * 0.25) as i32
    }

    fn surface_secondary(&self, x: i32, z: i32) -> f64 {
        self.surface_secondary.get(x as f64, 0.0, z as f64) as f64
    }

    fn band(&self, x: i32, y: i32, z: i32) -> u16 {
        let offset = java_round(self.clay_bands_offset.get(x as f64, 0.0, z as f64) * 4.0);
        let len = self.clay_bands.len() as i32;
        self.clay_bands[(y + offset + len).rem_euclid(len) as usize]
    }
}

// ---------------------------------------------------------------- context

struct RuleContext<'a> {
    input: &'a SurfaceInput<'a>,
    expected: Volume,
    block_x: i32,
    block_z: i32,
    gradient_x: i32,
    gradient_z: i32,
    surface_depth: i32,
    surface_secondary: Option<f64>,
    min_surface_level: Option<i32>,
    preliminary: Option<Vec<f32>>,
    noise_2d: Vec<Option<f64>>,
    noise_3d: Vec<Option<f64>>,
    noise_stacks: Vec<Arc<Stack>>,
    biome: Option<u16>,
    block_y: i32,
    water_height: i32,
    stone_depth_below: i32,
    stone_depth_above: i32,
}

impl RuleContext<'_> {
    fn update_xz(&mut self, x: i32, z: i32, gradient_x: i32, gradient_z: i32) {
        self.block_x = x;
        self.block_z = z;
        self.gradient_x = gradient_x;
        self.gradient_z = gradient_z;
        self.surface_depth = self.input.system.surface_depth(x, z);
        self.surface_secondary = None;
        self.min_surface_level = None;
        self.noise_2d.iter_mut().for_each(|n| *n = None);
        self.noise_3d.iter_mut().for_each(|n| *n = None);
        self.biome = None;
    }

    fn update_y(&mut self, stone_above: i32, stone_below: i32, water_height: i32, y: i32) {
        self.biome = None;
        self.block_y = y;
        self.water_height = water_height;
        self.stone_depth_below = stone_below;
        self.stone_depth_above = stone_above;
        self.noise_3d.iter_mut().for_each(|n| *n = None);
    }

    fn biome(&mut self) -> u16 {
        *self
            .biome
            .get_or_insert_with(|| (self.input.biome_at)(self.block_x, self.block_y, self.block_z))
    }

    fn surface_secondary(&mut self) -> f64 {
        let (x, z) = (self.block_x, self.block_z);
        *self
            .surface_secondary
            .get_or_insert_with(|| self.input.system.surface_secondary(x, z))
    }

    fn min_surface_level(&mut self, ctx: &mut Context) -> i32 {
        if let Some(level) = self.min_surface_level {
            return level;
        }
        let volume = Volume {
            size: [self.expected.size[0], 1, self.expected.size[2]],
            min: [self.expected.min[0], 0, self.expected.min[2]],
            step: [1, 1, 1],
        };
        let level = match volume.index_of_block(self.block_x, 0, self.block_z) {
            Some(index) => {
                if self.preliminary.is_none() {
                    let mut buffer = vec![0.0f32; volume.len()];
                    self.input
                        .system
                        .preliminary_surface
                        .fill(ctx, &mut buffer, &volume);
                    self.preliminary = Some(buffer);
                }
                self.preliminary.as_ref().expect("prefilled")[index]
            }
            None => self
                .input
                .system
                .preliminary_surface
                .value(ctx, self.block_x, 0, self.block_z),
        };
        let level = floor_f32(level) + self.surface_depth - 8;
        self.min_surface_level = Some(level);
        level
    }

    fn noise(&mut self, slot: usize, three_d: bool) -> f64 {
        let (x, y, z) = (self.block_x, self.block_y, self.block_z);
        let stack = &self.noise_stacks[slot];
        let cache = if three_d {
            &mut self.noise_3d[slot]
        } else {
            &mut self.noise_2d[slot]
        };
        *cache.get_or_insert_with(|| {
            if three_d {
                stack.get(x as f64, y as f64, z as f64) as f64
            } else {
                stack.get(x as f64, 0.0, z as f64) as f64
            }
        })
    }

    fn densities(&self, ctx: &mut Context, d: &Densities) -> f32 {
        let (x, y, z) = (self.block_x, self.block_y, self.block_z);
        match (&d.prefilled, self.expected.index_of_block(x, y, z)) {
            (Some(buffer), Some(index)) => buffer[index],
            _ => d.sampler.value(ctx, x, y, z),
        }
    }

    fn test(&mut self, ctx: &mut Context, condition: &CompiledCondition) -> bool {
        match condition {
            CompiledCondition::Biome(set) => {
                let biome = self.biome();
                set.contains(biome)
            }
            CompiledCondition::Noise {
                slot,
                min,
                max,
                three_d,
            } => {
                let value = self.noise(*slot, *three_d);
                value >= *min && value <= *max
            }
            CompiledCondition::VerticalGradient {
                true_below,
                false_above,
                random,
            } => {
                let y = self.block_y;
                if y <= *true_below {
                    return true;
                }
                if y >= *false_above {
                    return false;
                }
                let t =
                    (y as f64 - *true_below as f64) / (*false_above as f64 - *true_below as f64);
                let probability = 1.0 + t * (0.0 - 1.0);
                (random.at(self.block_x, y, self.block_z).next_float() as f64) < probability
            }
            CompiledCondition::Y {
                y,
                multiplier,
                add_stone_depth,
            } => {
                let stone = if *add_stone_depth {
                    self.stone_depth_above
                } else {
                    0
                };
                self.block_y + stone >= y + self.surface_depth * multiplier
            }
            CompiledCondition::Water {
                offset,
                multiplier,
                add_stone_depth,
            } => {
                let stone = if *add_stone_depth {
                    self.stone_depth_above
                } else {
                    0
                };
                self.water_height == i32::MIN
                    || self.block_y + stone
                        >= self.water_height + offset + self.surface_depth * multiplier
            }
            CompiledCondition::Temperature => {
                let biome = self.biome() as usize;
                let i = self.input;
                temperature(
                    &i.biomes.climate[biome],
                    self.block_x,
                    self.block_y,
                    self.block_z,
                    i.sea_level,
                ) < 0.15
            }
            CompiledCondition::Steep => self.gradient_x <= -4 || self.gradient_z >= 4,
            CompiledCondition::Not(inner) => !self.test(ctx, inner),
            CompiledCondition::Hole => self.surface_depth <= 0,
            CompiledCondition::AbovePreliminarySurface => {
                self.block_y >= self.min_surface_level(ctx)
            }
            CompiledCondition::StoneDepth {
                offset,
                add_surface_depth,
                secondary_range,
                ceiling,
            } => {
                let stone = if *ceiling {
                    self.stone_depth_below
                } else {
                    self.stone_depth_above
                };
                let surface = if *add_surface_depth {
                    self.surface_depth
                } else {
                    0
                };
                let secondary = if *secondary_range == 0 {
                    0
                } else {
                    let v = self.surface_secondary();
                    let t = (v - -1.0) / (1.0 - -1.0);
                    (0.0 + t * (*secondary_range as f64 - 0.0)) as i32
                };
                stone <= 1 + offset + surface + secondary
            }
        }
    }

    fn apply(&mut self, ctx: &mut Context, rule: &CompiledRule) -> Option<u16> {
        match rule {
            CompiledRule::Block(s) => Some(*s),
            CompiledRule::Bandlands => Some(self.input.system.band(
                self.block_x,
                self.block_y,
                self.block_z,
            )),
            CompiledRule::Sequence(rules) => rules.iter().find_map(|r| self.apply(ctx, r)),
            CompiledRule::Condition(condition, then) => {
                if self.test(ctx, condition) {
                    self.apply(ctx, then)
                } else {
                    None
                }
            }
            CompiledRule::OreVein {
                ore,
                raw_ore,
                filler,
                raw_ore_chance,
                density,
                richness,
                gap,
                random,
            } => {
                let d = self.densities(ctx, density);
                if d <= 0.0 {
                    return None;
                }
                let mut r = random.at(self.block_x, self.block_y, self.block_z);
                if r.next_float() > d {
                    return None;
                }
                let rich = self.densities(ctx, richness);
                if r.next_float() < rich && self.densities(ctx, gap) < 0.0 {
                    Some(if r.next_float() < *raw_ore_chance {
                        *raw_ore
                    } else {
                        *ore
                    })
                } else {
                    Some(*filler)
                }
            }
        }
    }
}

// ---------------------------------------------------------------- chunk

/// A chunk's blocks during terrain generation, with its worldgen surface
/// heightmap and fluid post-processing marks.
pub struct ChunkBlocks<'a> {
    pub blocks: &'a mut [u16],
    pub min_y: i32,
    pub height: i32,
    pub chunk_x: i32,
    pub chunk_z: i32,
    pub flags: &'a [u8],
    /// `WORLD_SURFACE_WG`: the first air above the highest non-air block.
    pub surface: [i32; 256],
    pub fluid_updates: &'a mut Vec<(i32, i32, i32)>,
}

impl ChunkBlocks<'_> {
    fn index(&self, x: i32, y: i32, z: i32) -> Option<usize> {
        let ry = y - self.min_y;
        (0..self.height)
            .contains(&ry)
            .then(|| (ry + (x + z * 16) * self.height) as usize)
    }

    /// Outside the chunk's height, vanilla reads void air.
    fn get(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        self.index(x, y, z).map(|i| self.blocks[i])
    }

    fn is_air(&self, state: Option<u16>) -> bool {
        state.is_none_or(|s| self.flags[s as usize] & 1 != 0)
    }

    fn has_fluid(&self, state: Option<u16>) -> bool {
        state.is_some_and(|s| self.flags[s as usize] & 2 != 0)
    }

    fn is_water(&self, state: Option<u16>) -> bool {
        state.is_some_and(|s| self.flags[s as usize] & 4 != 0)
    }

    /// `WORLD_SURFACE_WG.getFirstAvailable - 1` (`ChunkAccess.getHeight`).
    fn height_at(&self, x: i32, z: i32) -> i32 {
        self.surface[(x + z * 16) as usize] - 1
    }

    /// `ProtoChunk.setBlockState` through a column: updates the surface
    /// heightmap and marks fluids for post-processing.
    fn set(&mut self, x: i32, y: i32, z: i32, state: u16) {
        if self.put(x, y, z, state) && self.flags[state as usize] & 2 != 0 {
            self.fluid_updates
                .push((self.chunk_x * 16 + x, y, self.chunk_z * 16 + z));
        }
    }

    /// `ProtoChunk.setBlockState` alone: the block and the surface heightmap.
    /// False outside the chunk's height.
    pub(crate) fn put(&mut self, x: i32, y: i32, z: i32, state: u16) -> bool {
        let Some(index) = self.index(x, y, z) else {
            return false;
        };
        self.blocks[index] = state;
        let column = (x + z * 16) as usize;
        let first = self.surface[column];
        if y > first - 2 {
            if self.flags[state as usize] & 1 == 0 {
                if y >= first {
                    self.surface[column] = y + 1;
                }
            } else if first - 1 == y {
                let mut height = self.min_y;
                for below in (self.min_y..y).rev() {
                    if !self.is_air(self.get(x, below, z)) {
                        height = below + 1;
                        break;
                    }
                }
                self.surface[column] = height;
            }
        }
        true
    }

    pub(crate) fn mark_fluid_update(&mut self, x: i32, y: i32, z: i32) {
        self.fluid_updates
            .push((self.chunk_x * 16 + x, y, self.chunk_z * 16 + z));
    }

    pub(crate) fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        self.get(x, y, z)
    }

    pub(crate) fn flag(&self, state: Option<u16>, bit: u8) -> bool {
        state.is_some_and(|s| self.flags[s as usize] & bit != 0)
    }
}

/// `MaterialSystem.buildSurface` on a filled chunk, through the noise chunk's
/// sampling context.
pub fn build_surface(
    env: &mut dyn SurfaceEnv,
    ctx: &mut Context,
    input: &SurfaceInput,
    chunk: &mut ChunkBlocks,
    frozen_oceans: [u16; 2],
    eroded_badlands: u16,
) -> Result<(), String> {
    let system = input.system;
    let (min_x, min_z) = (chunk.chunk_x * 16, chunk.chunk_z * 16);
    let max_y = chunk.min_y + chunk.height - 1;
    let highest_section = (0..chunk.height / 16).rev().find(|&s| {
        (0..16).any(|z| {
            (0..16)
                .any(|x| (0..16).any(|y| !chunk.is_air(chunk.get(x, chunk.min_y + s * 16 + y, z))))
        })
    });
    let section_y = match highest_section {
        Some(s) => (chunk.min_y >> 4) + s,
        None => (chunk.min_y >> 4) - 1,
    };
    let max_block_y = section_y * 16 + 15;
    let expected = Volume {
        size: [16, (max_block_y - chunk.min_y + 1).max(1), 16],
        min: [min_x, chunk.min_y, min_z],
        step: [1, 1, 1],
    };
    let mut compiler = Compiler {
        input,
        noise_slots: Vec::new(),
        expected,
    };
    let rule = compiler.rule(env, ctx, input.rule)?;
    let noise_stacks = compiler
        .noise_slots
        .iter()
        .map(|n| env.noise(n))
        .collect::<Result<Vec<_>, _>>()?;
    let slots = noise_stacks.len();
    let mut rc = RuleContext {
        input,
        expected,
        block_x: 0,
        block_z: 0,
        gradient_x: 0,
        gradient_z: 0,
        surface_depth: 0,
        surface_secondary: None,
        min_surface_level: None,
        preliminary: None,
        noise_2d: vec![None; slots],
        noise_3d: vec![None; slots],
        noise_stacks,
        biome: None,
        block_y: 0,
        water_height: 0,
        stone_depth_below: 0,
        stone_depth_above: 0,
    };
    for x in 0..16 {
        for z in 0..16 {
            let (bx, bz) = (min_x + x, min_z + z);
            let starting_height = chunk.height_at(x, z) + 1;
            let surface_biome = (input.biome_at)(bx, starting_height, bz);
            if surface_biome == eroded_badlands {
                eroded_badlands_extension(system, chunk, x, z, bx, bz, starting_height);
            }
            let height = chunk.height_at(x, z) + 1;
            let gradient_x =
                chunk.height_at((x + 1).min(15), z) - chunk.height_at((x - 1).max(0), z);
            let gradient_z =
                chunk.height_at(x, (z + 1).min(15)) - chunk.height_at(x, (z - 1).max(0));
            rc.update_xz(bx, bz, gradient_x, gradient_z);
            let mut stone_above = 0;
            let mut water_height = i32::MIN;
            let mut next_ceiling = i32::MAX;
            let end_y = chunk.min_y;
            let mut y = height;
            while y >= end_y {
                let old = chunk.get(x, y, z);
                if chunk.is_air(old) {
                    stone_above = 0;
                    water_height = i32::MIN;
                } else if chunk.has_fluid(old) {
                    if water_height == i32::MIN {
                        water_height = y + 1;
                    }
                } else {
                    if next_ceiling >= y {
                        next_ceiling = WAY_BELOW_MIN_Y;
                        let mut look = y - 1;
                        while look >= end_y - 1 {
                            let s = chunk.get(x, look, z);
                            if chunk.is_air(s) || chunk.has_fluid(s) {
                                next_ceiling = look + 1;
                                break;
                            }
                            look -= 1;
                        }
                    }
                    stone_above += 1;
                    let stone_below = y - next_ceiling + 1;
                    rc.update_y(stone_above, stone_below, water_height, y);
                    if y >= chunk.min_y && y <= max_y {
                        if let Some(state) = rc.apply(ctx, &rule) {
                            chunk.set(x, y, z, state);
                        }
                    }
                }
                y -= 1;
            }
            if frozen_oceans.contains(&surface_biome) {
                let min_surface = rc.min_surface_level(ctx);
                frozen_ocean_extension(
                    system,
                    input,
                    chunk,
                    surface_biome,
                    min_surface,
                    (x, z, bx, bz),
                    starting_height,
                );
            }
        }
    }
    Ok(())
}

/// `MaterialSystem.topMaterial`: the material the rule places at one block
/// (a carver uncovering dirt below grass), from a context over that block
/// alone.
pub fn top_material(
    env: &mut dyn SurfaceEnv,
    ctx: &mut Context,
    input: &SurfaceInput,
    chunk: &ChunkBlocks,
    (x, y, z): (i32, i32, i32),
    under_fluid: bool,
) -> Result<Option<u16>, String> {
    let expected = Volume {
        size: [1, 1, 1],
        min: [x, y, z],
        step: [1, 1, 1],
    };
    let mut compiler = Compiler {
        input,
        noise_slots: Vec::new(),
        expected,
    };
    let rule = compiler.rule(env, ctx, input.rule)?;
    let noise_stacks = compiler
        .noise_slots
        .iter()
        .map(|n| env.noise(n))
        .collect::<Result<Vec<_>, _>>()?;
    let slots = noise_stacks.len();
    let mut rc = RuleContext {
        input,
        expected,
        block_x: 0,
        block_z: 0,
        gradient_x: 0,
        gradient_z: 0,
        surface_depth: 0,
        surface_secondary: None,
        min_surface_level: None,
        preliminary: None,
        noise_2d: vec![None; slots],
        noise_3d: vec![None; slots],
        noise_stacks,
        biome: None,
        block_y: 0,
        water_height: 0,
        stone_depth_below: 0,
        stone_depth_above: 0,
    };
    let (lx, lz) = (x & 15, z & 15);
    let gradient_x = chunk.height_at((lx + 1).min(15), lz) - chunk.height_at((lx - 1).max(0), lz);
    let gradient_z = chunk.height_at(lx, (lz + 1).min(15)) - chunk.height_at(lx, (lz - 1).max(0));
    rc.update_xz(x, z, gradient_x, gradient_z);
    rc.update_y(1, 1, if under_fluid { y + 1 } else { i32::MIN }, y);
    Ok(rc.apply(ctx, &rule))
}

fn eroded_badlands_extension(
    system: &MaterialSystem,
    chunk: &mut ChunkBlocks,
    x: i32,
    z: i32,
    bx: i32,
    bz: i32,
    height: i32,
) {
    let surface = (system.badlands_surface.get(bx as f64, 0.0, bz as f64) as f64 * 8.25).abs();
    let pillar = (system
        .badlands_pillar
        .get(bx as f64 * 0.2, 0.0, bz as f64 * 0.2)
        * 15.0) as f64;
    let buffer = dmin(surface, pillar);
    if buffer <= 0.0 {
        return;
    }
    let floor = (system
        .badlands_pillar_roof
        .get(bx as f64 * 0.75, 0.0, bz as f64 * 0.75) as f64
        * 1.5)
        .abs();
    let top = 64.0 + dmin(buffer * buffer * 2.5, (floor * 50.0).ceil() + 24.0);
    let start = top.floor() as i32;
    if height > start {
        return;
    }
    let mut y = start;
    while y >= chunk.min_y {
        let old = chunk.get(x, y, z);
        if old == Some(system.default_block) {
            break;
        }
        if chunk.is_water(old) {
            return;
        }
        y -= 1;
    }
    let mut y = start;
    while y >= chunk.min_y && chunk.is_air(chunk.get(x, y, z)) {
        chunk.set(x, y, z, system.default_block);
        y -= 1;
    }
}

#[allow(clippy::too_many_arguments)]
fn frozen_ocean_extension(
    system: &MaterialSystem,
    input: &SurfaceInput,
    chunk: &mut ChunkBlocks,
    biome: u16,
    min_surface: i32,
    (x, z, bx, bz): (i32, i32, i32, i32),
    height: i32,
) {
    let sea = system.sea_level;
    let surface = (system.iceberg_surface.get(bx as f64, 0.0, bz as f64) as f64 * 8.25).abs();
    let pillar = (system
        .iceberg_pillar
        .get(bx as f64 * 1.28, 0.0, bz as f64 * 1.28)
        * 15.0) as f64;
    let iceberg = dmin(surface, pillar);
    if iceberg <= 1.8 {
        return;
    }
    let roof = (system
        .iceberg_pillar_roof
        .get(bx as f64 * 1.17, 0.0, bz as f64 * 1.17) as f64
        * 1.5)
        .abs();
    let mut top = dmin(iceberg * iceberg * 1.2, (roof * 40.0).ceil() + 14.0);
    if temperature(&input.biomes.climate[biome as usize], bx, sea, bz, sea) > 0.1 {
        top -= 2.0;
    }
    if top <= 2.0 {
        return;
    }
    let bottom = sea as f64 - top - 7.0;
    top += sea as f64;
    let mut random = system.noise_random.at(bx, 0, bz);
    let max_snow_depth = 2 + random.next_int_bounded(4);
    let min_snow_height = sea + 18 + random.next_int_bounded(10);
    let mut snow_depth = 0;
    let (top_i, bottom_i) = (top as i32, bottom as i32);
    let mut y = height.max(top_i + 1);
    while y >= min_surface {
        let current = chunk.get(x, y, z);
        let place = (chunk.is_air(current) && y < top_i && random.next_double() > 0.01)
            || (chunk.is_water(current) && y > bottom_i && y < sea && random.next_double() > 0.15);
        if place {
            if snow_depth <= max_snow_depth && y > min_snow_height {
                chunk.set(x, y, z, system.snow_block);
                snow_depth += 1;
            } else {
                chunk.set(x, y, z, system.packed_ice);
            }
        }
        y -= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn java_round_matches_java() {
        assert_eq!(java_round(0.5), 1);
        assert_eq!(java_round(-0.5), 0);
        assert_eq!(java_round(0.49999997), 0);
        assert_eq!(java_round(-1.5), -1);
        assert_eq!(java_round(2.4), 2);
        assert_eq!(java_round(f32::NAN), 0);
        assert_eq!(java_round(1.0e10), i32::MAX);
    }

    #[test]
    fn chunk_zoom_equals_zoom() {
        let seed = biome_zoom_seed(20261020);
        for (cx, cz) in [(0, 0), (-3, 7), (1875, -1875)] {
            let cached = ChunkZoom::new(seed, cx, cz, -64, 384);
            for x in cx * 16 - 3..cx * 16 + 19 {
                for z in cz * 16 - 3..cz * 16 + 19 {
                    for y in (-70..330).step_by(3) {
                        assert_eq!(cached.zoom(x, y, z), zoom(seed, x, y, z), "{x} {y} {z}");
                    }
                }
            }
        }
    }

    #[test]
    fn zoom_stays_near_the_block() {
        let seed = biome_zoom_seed(20261020);
        for (x, y, z) in [(0, 0, 0), (-17, 70, 33), (1000, -64, -1000)] {
            let (qx, qy, qz) = zoom(seed, x, y, z);
            assert!(
                (qx - (x >> 2)).abs() <= 1
                    && (qy - (y >> 2)).abs() <= 1
                    && (qz - (z >> 2)).abs() <= 1
            );
        }
    }
}
