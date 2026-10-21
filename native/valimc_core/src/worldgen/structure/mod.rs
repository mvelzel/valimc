//! Structure placement and starts (VMC-025e), from the decompiled
//! `ChunkGeneratorStructureState`, `StructurePlacement` types,
//! `ChunkGenerator.createStructures` / `createReferences` and `Structure`:
//!
//! - Structure sets whose structures can occur in the biome source, tried in
//!   identifier order; random spread grids (salted, linear or triangular,
//!   with frequency reduction and exclusion zones) and concentric rings
//!   (positions computed as vanilla computes them, biome search included).
//! - Per chunk, each set's structures are tried (several by weighted draws
//!   from the chunk's large feature seed) until one gives a valid start: the
//!   structure's generation point (from base heights of the noise column,
//!   without carvers or features) must lie in one of its biomes, and its
//!   pieces must not be empty.
//! - References: a chunk refers to every start within 8 chunks whose
//!   bounding box covers it horizontally.
//!
//! Biome lookups go through one cached climate context per chunk, as
//! vanilla's do, each from a fresh lookup history.

pub mod piece;
pub mod placement;
pub mod scattered;

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

use super::blocks::Heightmap;
use super::climate::{quantize, ParameterList};
use super::json::Json;
use super::random::{Positional, Random};
use super::sampler::{Context, Sampler};
use super::terrain::{Aquifer, AquiferSamplers, TerrainBlocks};
use super::volume::Volume;
use piece::{encapsulating, BoundingBox, Nbt, Piece};
use placement::{java_round, Placement};

/// `TerrainAdjustment`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TerrainAdjustment {
    None,
    Bury,
    BeardThin,
    BeardBox,
    Encapsulate,
}

/// A structure's type and the configuration its generation reads.
#[derive(Clone, Debug)]
pub enum StructureKind {
    DesertPyramid,
    JungleTemple,
    SwampHut,
    BuriedTreasure,
    /// A type this slice does not generate yet.
    Unsupported(String),
}

#[derive(Clone, Debug)]
pub struct StructureDef {
    pub id: String,
    /// Allowed biomes by registry id.
    pub biomes: BiomeSet,
    pub terrain_adaptation: TerrainAdjustment,
    pub kind: StructureKind,
}

#[derive(Clone, Debug)]
pub struct StructureSetDef {
    pub id: String,
    pub placement: Placement,
    /// Structures (by index) and weights.
    pub structures: Vec<(usize, i32)>,
}

/// A set of biomes by registry id.
#[derive(Clone, Debug, Default)]
pub struct BiomeSet(Vec<u64>);

impl BiomeSet {
    pub fn from_ids(ids: impl IntoIterator<Item = u16>) -> BiomeSet {
        let mut words = Vec::new();
        for b in ids {
            let word = b as usize / 64;
            if words.len() <= word {
                words.resize(word + 1, 0);
            }
            words[word] |= 1 << (b % 64);
        }
        BiomeSet(words)
    }

    pub fn contains(&self, biome: u16) -> bool {
        self.0
            .get(biome as usize / 64)
            .is_some_and(|w| w & (1 << (biome % 64)) != 0)
    }
}

/// The `worldgen/structure` and `worldgen/structure_set` registries.
#[derive(Clone, Debug, Default)]
pub struct StructureRegistry {
    pub structures: Vec<StructureDef>,
    /// In identifier order, as a server lists them.
    pub sets: Vec<StructureSetDef>,
}

impl StructureRegistry {
    /// Parses `structures.json` and `structure_sets.json`; `biome` resolves a
    /// biome identifier to its registry id.
    pub fn parse(
        structures: &Json,
        sets: &Json,
        biome: &dyn Fn(&str) -> Result<u16, String>,
    ) -> Result<StructureRegistry, String> {
        let mut registry = StructureRegistry::default();
        let mut structure_index = HashMap::new();
        for (id, json) in structures.entries()? {
            let def =
                parse_structure(id, json, biome).map_err(|e| format!("structure {id}: {e}"))?;
            structure_index.insert(id.clone(), registry.structures.len());
            registry.structures.push(def);
        }
        let mut set_ids: Vec<&String> = sets.entries()?.iter().map(|(id, _)| id).collect();
        set_ids.sort();
        let set_index = |id: &str| -> Result<usize, String> {
            set_ids
                .binary_search_by(|probe| probe.as_str().cmp(id))
                .map_err(|_| format!("unknown structure set {id}"))
        };
        for id in &set_ids {
            let json = sets.field(id)?;
            let placement = Placement::parse(json.field("placement")?, &set_index, biome)
                .map_err(|e| format!("structure set {id}: {e}"))?;
            let structures = json
                .field("structures")?
                .as_array()?
                .iter()
                .map(|entry| {
                    let name = entry.field("structure")?.as_str()?;
                    let index = *structure_index
                        .get(name)
                        .ok_or_else(|| format!("unknown structure {name}"))?;
                    Ok((index, entry.field("weight")?.as_i32()?))
                })
                .collect::<Result<Vec<_>, String>>()?;
            registry.sets.push(StructureSetDef {
                id: id.to_string(),
                placement,
                structures,
            });
        }
        Ok(registry)
    }

    pub fn set_index(&self, id: &str) -> Option<usize> {
        self.sets.iter().position(|s| s.id == id)
    }
}

fn parse_structure(
    id: &str,
    json: &Json,
    biome: &dyn Fn(&str) -> Result<u16, String>,
) -> Result<StructureDef, String> {
    let biomes = json
        .field("biomes")?
        .as_array()?
        .iter()
        .map(|b| biome(b.as_str()?))
        .collect::<Result<Vec<_>, _>>()?;
    let terrain_adaptation = match json.get("terrain_adaptation").map(Json::as_str) {
        None => TerrainAdjustment::None,
        Some(name) => match name? {
            "none" => TerrainAdjustment::None,
            "bury" => TerrainAdjustment::Bury,
            "beard_thin" => TerrainAdjustment::BeardThin,
            "beard_box" => TerrainAdjustment::BeardBox,
            "encapsulate" => TerrainAdjustment::Encapsulate,
            other => return Err(format!("unknown terrain adaptation {other}")),
        },
    };
    let kind = match json.field("type")?.as_str()? {
        "minecraft:desert_pyramid" => StructureKind::DesertPyramid,
        "minecraft:jungle_temple" => StructureKind::JungleTemple,
        "minecraft:swamp_hut" => StructureKind::SwampHut,
        "minecraft:buried_treasure" => StructureKind::BuriedTreasure,
        other => StructureKind::Unsupported(other.to_string()),
    };
    Ok(StructureDef {
        id: id.to_string(),
        biomes: BiomeSet::from_ids(biomes),
        terrain_adaptation,
        kind,
    })
}

/// A reference: a structure (by index) and the chunk of its start.
pub type Reference = (usize, (i32, i32));

/// A structure start: the structure (by index), its chunk, references and
/// pieces.
#[derive(Clone, Debug, PartialEq)]
pub struct Start {
    pub structure: usize,
    pub chunk: (i32, i32),
    pub references: i32,
    pub pieces: Vec<Piece>,
    /// `StructureStart.getBoundingBox`: the pieces' box, grown by 12 when
    /// the structure adapts terrain.
    pub bbox: BoundingBox,
}

impl Start {
    /// `StructureStart.createTag`.
    pub fn save(&self, registry: &StructureRegistry) -> Nbt {
        Nbt::Compound(vec![
            (
                "id".into(),
                Nbt::string(&registry.structures[self.structure].id),
            ),
            ("ChunkX".into(), Nbt::Int(self.chunk.0)),
            ("ChunkZ".into(), Nbt::Int(self.chunk.1)),
            ("references".into(), Nbt::Int(self.references)),
            (
                "Children".into(),
                Nbt::List(self.pieces.iter().map(Piece::save).collect()),
            ),
        ])
    }
}

/// Climate biome lookups for a multi-noise biome source.
#[derive(Clone, Debug)]
pub struct ClimateBiomes {
    pub samplers: Vec<Arc<Sampler>>,
    pub list: Arc<ParameterList>,
    /// Registry ids of the list's biomes.
    pub ids: Vec<u16>,
}

impl ClimateBiomes {
    /// The biome at a quart through `ctx` (`createResolver`), from a fresh
    /// lookup history.
    pub fn point(&self, ctx: &mut Context, qx: i32, qy: i32, qz: i32) -> u16 {
        let (bx, by, bz) = (qx << 2, qy << 2, qz << 2);
        let target: [i64; 6] =
            std::array::from_fn(|i| quantize(self.samplers[i].value(ctx, bx, by, bz)));
        self.ids[self.list.find(&target, &mut None) as usize]
    }

    /// The biomes of a quart column from `min_qy` (`createResolverForChunk`
    /// over a 1 × `count` × 1 quart volume): climate sampled over the volume
    /// through `ctx`, then one lookup per quart.
    pub fn column(
        &self,
        ctx: &mut Context,
        qx: i32,
        qz: i32,
        min_qy: i32,
        count: i32,
    ) -> Result<Vec<u16>, String> {
        let volume = Volume::new([1, count, 1], [qx << 2, min_qy << 2, qz << 2], [4, 4, 4])?;
        let mut climate = Vec::with_capacity(6);
        for sampler in &self.samplers {
            let mut values = vec![0.0f32; volume.len()];
            sampler.fill(ctx, &mut values, &volume);
            climate.push(values);
        }
        Ok((0..volume.len())
            .map(|i| {
                let target: [i64; 6] = std::array::from_fn(|c| quantize(climate[c][i]));
                self.ids[self.list.find(&target, &mut None) as usize]
            })
            .collect())
    }
}

/// Base heights of the noise column (`NoiseBasedChunkGenerator.
/// iterateNoiseColumn`): final density and the aquifer over one column
/// through a fresh noise chunk, without structures.
#[derive(Clone, Debug)]
pub struct Heights {
    pub final_density: Arc<Sampler>,
    pub aquifer: Option<(AquiferSamplers, Positional)>,
    pub blocks: TerrainBlocks,
    pub min_y: i32,
    pub height: i32,
    pub sea_level: i32,
    /// Per state: bit 0 air, bit 1 contains a fluid.
    pub flags: Arc<Vec<u8>>,
}

impl Heights {
    /// The column's states from the bottom, or with `until` the column from
    /// the top down to the first state it accepts (`None` when none does).
    fn iterate(
        &self,
        x: i32,
        z: i32,
        until: Option<&dyn Fn(u16) -> bool>,
    ) -> Result<(Vec<u16>, Option<i32>), String> {
        let volume = Volume::new([1, self.height, 1], [x, self.min_y, z], [1, 1, 1])?;
        let mut ctx = Context::cached();
        let mut aquifer = Aquifer::new(
            &mut ctx,
            self.aquifer.as_ref().map(|(s, p)| (s, *p)),
            &volume,
            self.sea_level,
            self.blocks,
        );
        let mut density = vec![0.0f32; volume.len()];
        self.final_density.fill(&mut ctx, &mut density, &volume);
        let mut states = vec![self.blocks.air; volume.len()];
        for y in (0..self.height).rev() {
            let block_y = self.min_y + y;
            let state = aquifer
                .compute_substance(&mut ctx, x, block_y, z, density[y as usize] as f64)
                .unwrap_or(self.blocks.default_block);
            states[y as usize] = state;
            if let Some(test) = until {
                if test(state) {
                    return Ok((states, Some(block_y + 1)));
                }
            }
        }
        Ok((states, None))
    }

    /// `getBaseHeight`: one above the highest state the heightmap counts.
    pub fn base_height(&self, x: i32, z: i32, heightmap: Heightmap) -> Result<i32, String> {
        let flags = &self.flags;
        let test: &dyn Fn(u16) -> bool = match heightmap {
            Heightmap::WorldSurfaceWg | Heightmap::WorldSurface => {
                &|s: u16| flags[s as usize] & 1 == 0
            }
            Heightmap::OceanFloorWg
            | Heightmap::OceanFloor
            | Heightmap::MotionBlocking
            | Heightmap::MotionBlockingNoLeaves => &|s: u16| flags[s as usize] & 3 == 0,
        };
        Ok(self.iterate(x, z, Some(test))?.1.unwrap_or(self.min_y))
    }

    /// `getBaseColumn`: the column's states from the bottom.
    pub fn base_column(&self, x: i32, z: i32) -> Result<Vec<u16>, String> {
        Ok(self.iterate(x, z, None)?.0)
    }
}

/// One seed's structure generation for a biome source
/// (`ChunkGeneratorStructureState` with the generator's heights).
pub struct StructureEnv {
    pub registry: Arc<StructureRegistry>,
    pub seed: i64,
    pub biomes: ClimateBiomes,
    pub heights: Heights,
    /// Structure sets whose structures can occur, in identifier order.
    pub possible: Vec<usize>,
    rings: Vec<OnceLock<Vec<(i32, i32)>>>,
}

impl StructureEnv {
    pub fn new(
        registry: Arc<StructureRegistry>,
        seed: i64,
        biomes: ClimateBiomes,
        heights: Heights,
    ) -> StructureEnv {
        let possible = (0..registry.sets.len())
            .filter(|&s| {
                registry.sets[s].structures.iter().any(|&(structure, _)| {
                    biomes
                        .ids
                        .iter()
                        .any(|&b| registry.structures[structure].biomes.contains(b))
                })
            })
            .collect();
        let rings = (0..registry.sets.len()).map(|_| OnceLock::new()).collect();
        StructureEnv {
            registry,
            seed,
            biomes,
            heights,
            possible,
            rings,
        }
    }

    /// `ChunkGeneratorStructureState.getRingPositionsFor`: `None` for sets
    /// that are not concentric rings or cannot occur.
    pub fn ring_positions(&self, set: usize) -> Option<&[(i32, i32)]> {
        let Placement::ConcentricRings {
            distance,
            spread,
            count,
            preferred,
            ..
        } = &self.registry.sets[set].placement
        else {
            return None;
        };
        if !self.possible.contains(&set) {
            return None;
        }
        Some(
            self.rings[set].get_or_init(|| {
                self.generate_ring_positions(*distance, *spread, *count, preferred)
            }),
        )
    }

    /// `generateRingPositions`, with the level seed as the rings' seed.
    fn generate_ring_positions(
        &self,
        distance: i32,
        spread: i32,
        count: i32,
        preferred: &[u16],
    ) -> Vec<(i32, i32)> {
        let preferred = BiomeSet::from_ids(preferred.iter().copied());
        let mut random = Random::legacy(self.seed);
        let mut angle = random.next_double() * std::f64::consts::PI * 2.0;
        let (mut position_in_circle, mut circle, mut spread) = (0, 0, spread);
        let mut out = Vec::with_capacity(count as usize);
        for i in 0..count {
            let dist = (4 * distance + distance * circle * 6) as f64
                + (random.next_double() - 0.5) * (distance as f64 * 2.5);
            let initial_x = java_round(angle.cos() * dist) as i32;
            let initial_z = java_round(angle.sin() * dist) as i32;
            let mut search = random.fork();
            let found = self.find_biome_horizontal(
                (initial_x << 4) + 8,
                0,
                (initial_z << 4) + 8,
                112,
                &|b| preferred.contains(b),
                &mut search,
            );
            out.push(match found {
                Some((x, _, z)) => (x >> 4, z >> 4),
                None => (initial_x, initial_z),
            });
            angle += (std::f64::consts::PI * 2.0) / spread as f64;
            position_in_circle += 1;
            if position_in_circle == spread {
                circle += 1;
                position_in_circle = 0;
                spread += 2 * spread / (circle + 1);
                spread = spread.min(count - i);
                angle += random.next_double() * std::f64::consts::PI * 2.0;
            }
        }
        out
    }

    /// `BiomeSource.findBiomeHorizontal` without searching for the closest:
    /// every quart within the radius at one height, a reservoir draw among
    /// the allowed ones; lookups through a fresh caching resolver.
    fn find_biome_horizontal(
        &self,
        x: i32,
        y: i32,
        z: i32,
        radius: i32,
        allowed: &dyn Fn(u16) -> bool,
        random: &mut Random,
    ) -> Option<(i32, i32, i32)> {
        let (cx, cz, r, qy) = (x >> 2, z >> 2, radius >> 2, y >> 2);
        let mut ctx = Context::cached();
        let mut result = None;
        let mut found = 0;
        for dz in -r..=r {
            for dx in -r..=r {
                let (qx, qz) = (cx + dx, cz + dz);
                if allowed(self.biomes.point(&mut ctx, qx, qy, qz)) {
                    if result.is_none() || random.next_int_bounded(found + 1) == 0 {
                        result = Some((qx << 2, y, qz << 2));
                    }
                    found += 1;
                }
            }
        }
        result
    }

    /// `StructurePlacement.isStructureChunk` for a set.
    pub fn is_structure_chunk(&self, set: usize, x: i32, z: i32) -> bool {
        let placement = &self.registry.sets[set].placement;
        let placed = match placement {
            Placement::RandomSpread { .. } => {
                placement.potential_chunk(self.seed, x, z) == Some((x, z))
            }
            Placement::ConcentricRings { .. } => self
                .ring_positions(set)
                .is_some_and(|positions| positions.contains(&(x, z))),
        };
        let common = placement.common();
        placed
            && common.frequency_allows(self.seed, x, z)
            && common.exclusion.is_none_or(|(other, range)| {
                !((x - range)..=(x + range)).any(|tx| {
                    ((z - range)..=(z + range)).any(|tz| self.is_structure_chunk(other, tx, tz))
                })
            })
    }

    /// `ChunkGenerator.createStructures` for a fresh chunk: the starts it
    /// makes, and the sets skipped because one of their structures has a
    /// type ValiMC does not generate yet.
    pub fn create_structures(&self, x: i32, z: i32) -> Result<(Vec<Start>, Vec<usize>), String> {
        let mut ctx = Context::cached();
        let mut starts: Vec<Start> = Vec::new();
        let mut skipped = Vec::new();
        for &set_index in &self.possible {
            let set = &self.registry.sets[set_index];
            if set.structures.iter().any(|&(s, _)| {
                matches!(
                    self.registry.structures[s].kind,
                    StructureKind::Unsupported(_)
                )
            }) {
                skipped.push(set_index);
                continue;
            }
            if set
                .structures
                .iter()
                .any(|&(s, _)| starts.iter().any(|start| start.structure == s))
            {
                continue;
            }
            if !self.is_structure_chunk(set_index, x, z) {
                continue;
            }
            if let [(structure, _)] = set.structures[..] {
                if let Some(start) = self.try_generate(&mut ctx, structure, x, z)? {
                    starts.push(start);
                }
                continue;
            }
            let mut options = set.structures.clone();
            let mut random = Random::legacy(0);
            super::carver::set_large_feature_seed(&mut random, self.seed, x, z);
            let mut total: i32 = options.iter().map(|&(_, w)| w).sum();
            while !options.is_empty() {
                let mut choice = random.next_int_bounded(total);
                let mut index = 0;
                for &(_, weight) in &options {
                    choice -= weight;
                    if choice < 0 {
                        break;
                    }
                    index += 1;
                }
                let (structure, weight) = options[index];
                if let Some(start) = self.try_generate(&mut ctx, structure, x, z)? {
                    starts.push(start);
                    break;
                }
                options.remove(index);
                total -= weight;
            }
        }
        Ok((starts, skipped))
    }

    /// `tryGenerateStructure` / `Structure.generate` in a fresh chunk.
    fn try_generate(
        &self,
        ctx: &mut Context,
        structure: usize,
        x: i32,
        z: i32,
    ) -> Result<Option<Start>, String> {
        let def = &self.registry.structures[structure];
        let mut random = Random::legacy(0);
        super::carver::set_large_feature_seed(&mut random, self.seed, x, z);
        let mut gc = GenContext {
            env: self,
            ctx,
            random,
            chunk: (x, z),
            valid: &def.biomes,
        };
        let pieces = match &def.kind {
            StructureKind::DesertPyramid => scattered::single_piece(&mut gc, def, 21, 21)?,
            StructureKind::JungleTemple => scattered::single_piece(&mut gc, def, 12, 15)?,
            StructureKind::SwampHut => scattered::swamp_hut(&mut gc)?,
            StructureKind::BuriedTreasure => scattered::buried_treasure(&mut gc)?,
            StructureKind::Unsupported(kind) => {
                return Err(format!("structure type {kind} is not generated yet"))
            }
        };
        let Some(pieces) = pieces.filter(|p| !p.is_empty()) else {
            return Ok(None);
        };
        let mut bbox = encapsulating(pieces.iter().map(|p| &p.bbox)).expect("pieces");
        if def.terrain_adaptation != TerrainAdjustment::None {
            bbox = bbox.inflated(12, 12, 12);
        }
        Ok(Some(Start {
            structure,
            chunk: (x, z),
            references: 0,
            pieces,
            bbox,
        }))
    }

    /// `ChunkGenerator.createReferences`: the starts within 8 chunks (from
    /// `starts_at`) whose bounding boxes cover the chunk horizontally, as
    /// (structure, source chunk).
    pub fn references<'a>(
        &self,
        x: i32,
        z: i32,
        starts_at: &dyn Fn(i32, i32) -> Option<&'a [Start]>,
    ) -> Result<Vec<Reference>, String> {
        let (min_x, min_z) = (x * 16, z * 16);
        let mut out = Vec::new();
        for sx in x - 8..=x + 8 {
            for sz in z - 8..=z + 8 {
                let starts =
                    starts_at(sx, sz).ok_or_else(|| format!("no starts for chunk {sx}, {sz}"))?;
                for start in starts {
                    if start
                        .bbox
                        .intersects_xz(min_x, min_z, min_x + 15, min_z + 15)
                    {
                        out.push((start.structure, (sx, sz)));
                    }
                }
            }
        }
        Ok(out)
    }
}

/// `Structure.GenerationContext`: one structure's attempt in a chunk.
pub struct GenContext<'a> {
    pub env: &'a StructureEnv,
    pub ctx: &'a mut Context,
    /// The chunk's large feature random (legacy).
    pub random: Random,
    pub chunk: (i32, i32),
    pub valid: &'a BiomeSet,
}

impl GenContext<'_> {
    pub fn min_block_x(&self) -> i32 {
        self.chunk.0 << 4
    }

    pub fn min_block_z(&self) -> i32 {
        self.chunk.1 << 4
    }

    pub fn sea_level(&self) -> i32 {
        self.env.heights.sea_level
    }

    pub fn first_occupied_height(
        &self,
        x: i32,
        z: i32,
        heightmap: Heightmap,
    ) -> Result<i32, String> {
        Ok(self.env.heights.base_height(x, z, heightmap)? - 1)
    }

    fn corner_heights(
        &self,
        min_x: i32,
        size_x: i32,
        min_z: i32,
        size_z: i32,
    ) -> Result<[i32; 4], String> {
        let h = |x, z| self.first_occupied_height(x, z, Heightmap::WorldSurfaceWg);
        Ok([
            h(min_x, min_z)?,
            h(min_x, min_z + size_z)?,
            h(min_x + size_x, min_z)?,
            h(min_x + size_x, min_z + size_z)?,
        ])
    }

    /// `Structure.getLowestY` over a box from a corner.
    pub fn lowest_y(
        &self,
        min_x: i32,
        min_z: i32,
        size_x: i32,
        size_z: i32,
    ) -> Result<i32, String> {
        let c = self.corner_heights(min_x, size_x, min_z, size_z)?;
        Ok(c[0].min(c[1]).min(c[2].min(c[3])))
    }

    /// `Structure.getMeanFirstOccupiedHeight`.
    pub fn mean_first_occupied_height(
        &self,
        min_x: i32,
        size_x: i32,
        min_z: i32,
        size_z: i32,
    ) -> Result<i32, String> {
        let c = self.corner_heights(min_x, size_x, min_z, size_z)?;
        Ok((c[0] + c[1] + c[2] + c[3]) / 4)
    }

    /// `isValidBiome`: the biome at the start position is allowed.
    pub fn is_valid_biome(&mut self, (x, y, z): (i32, i32, i32)) -> bool {
        let biome = self.env.biomes.point(self.ctx, x >> 2, y >> 2, z >> 2);
        self.valid.contains(biome)
    }

    /// `couldStructureExistInColumn`.
    pub fn could_exist_in_column(
        &mut self,
        x: i32,
        z: i32,
        min_y: i32,
        max_y: i32,
    ) -> Result<bool, String> {
        let (qx, qz, min_qy, max_qy) = (x >> 2, z >> 2, min_y >> 2, max_y >> 2);
        let column = self
            .env
            .biomes
            .column(self.ctx, qx, qz, min_qy, max_qy - min_qy + 1)?;
        Ok(column.into_iter().any(|b| self.valid.contains(b)))
    }

    /// `couldValidBiomeExistInTerrainColumn`, over the chunk's height.
    pub fn could_exist_in_terrain_column(&mut self, x: i32, z: i32) -> Result<bool, String> {
        let h = &self.env.heights;
        let (min_y, max_y) = (h.min_y - 1, h.min_y + h.height - 1);
        self.could_exist_in_column(x, z, min_y, max_y)
    }

    /// `couldValidBiomeExistOnTopOfChunkCenter`.
    pub fn could_exist_on_top_of_chunk_center(&mut self) -> Result<bool, String> {
        let (x, z) = (self.min_block_x() + 8, self.min_block_z() + 8);
        self.could_exist_in_terrain_column(x, z)
    }

    /// `onTopOfChunkCenterWithoutBiomeCheck`'s position.
    pub fn top_of_chunk_center(&self, heightmap: Heightmap) -> Result<(i32, i32, i32), String> {
        let (x, z) = (self.min_block_x() + 8, self.min_block_z() + 8);
        Ok((x, self.first_occupied_height(x, z, heightmap)?, z))
    }
}
