//! `/place` (VMC-053): vanilla's `PlaceCommand` against chunks of the live
//! world. A placement is planned first (the chunks vanilla checks are loaded
//! and the chunks it writes), then run over proto chunks made from those
//! chunks' columns with a random the caller seeds, as vanilla uses the
//! level's random; the caller writes the blocks and block entities that
//! changed back through the region owners.

use std::collections::HashMap;
use std::sync::Arc;

use super::{BiomeSource, Worldgen};
use crate::column::{Column, HEIGHT as COLUMN_HEIGHT, MIN_Y as COLUMN_MIN_Y};
use crate::rules::growth::{draw, Generated, Grower};
use crate::worldgen::blocks::BLOCK_ENTITY;
use crate::worldgen::random::Random;
use crate::worldgen::region::{Area, BlockEntityData, ProtoChunk, Region};
use crate::worldgen::structure::jigsaw::JigsawConfig;
use crate::worldgen::structure::piece::BoundingBox;
use crate::worldgen::structure::place::{place_in_chunk, Ctx, Placer};
use crate::worldgen::structure::{jigsaw_place, Start};
use crate::worldgen::surface;
use crate::worldgen::template::{Mirror, PlaceSettings, Processor, Rotation};

/// What `/place` places.
#[derive(Clone, Debug)]
pub enum Placement {
    Feature(String),
    Template {
        id: String,
        rotation: Rotation,
        mirror: Mirror,
        integrity: f32,
        strict: bool,
    },
    Structure(String),
    Jigsaw {
        pool: String,
        target: String,
        max_depth: i32,
    },
    /// A sapling's tree (`TreeGrower.growTree`, VMC-039a) at the sapling's
    /// cell, from its grower.
    Sapling(Grower),
    /// Bone meal on the grass block at the cell (`GrassBlock
    /// .performBonemeal`, VMC-039b), each biome's bone meal features by name.
    Grass(Arc<HashMap<String, Vec<String>>>),
    /// A mushroom's huge mushroom feature at its cell (`MushroomBlock
    /// .growMushroom`, VMC-039b).
    Mushroom(String),
}

impl Placement {
    /// What the generator grows for `generated` at `pos` (VMC-039a,
    /// VMC-039b): the placement and the cell it is placed at.
    pub fn grown(generated: Generated, pos: [i32; 3]) -> (Placement, [i32; 3]) {
        match generated {
            Generated::Tree(grower) => (Placement::Sapling(grower.clone()), pos),
            Generated::Grass(features) => (Placement::Grass(features), pos),
            Generated::Mushroom(id) => (Placement::Mushroom(id.to_string()), pos),
            Generated::Above(id) => (
                Placement::Feature(id.to_string()),
                [pos[0], pos[1] + 1, pos[2]],
            ),
        }
    }
}

/// A planned placement: the chunks vanilla checks are loaded, and every
/// chunk it reads or writes (inclusive corners).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Plan {
    Chunks {
        checked: ((i32, i32), (i32, i32)),
        area: ((i32, i32), (i32, i32)),
    },
    /// A template that does not exist (`commands.place.template.invalid`).
    Invalid,
    /// A structure whose start is not valid here, or a jigsaw that builds
    /// nothing (`commands.place.structure.failed`, `…jigsaw.failed`).
    Failed,
    /// A placement spanning more chunks than ValiMC places at once.
    TooLarge,
}

/// What a placement changed: blocks, the block entities of changed or
/// written positions (with what placement wrote into them), and the entities
/// it added.
#[derive(Debug, Default)]
pub struct Placed {
    pub blocks: Vec<([i32; 3], u16)>,
    /// Each changed block's state before.
    pub replaced: Vec<u16>,
    pub block_entities: Vec<([i32; 3], u16, Option<BlockEntityData>)>,
    pub entities: Vec<super::super::region::Entity>,
}

/// The most chunks across a placement may span (a woodland mansion spans 6).
const MAX_SPAN: i32 = 16;

fn chunk_of(x: i32, z: i32) -> (i32, i32) {
    (x >> 4, z >> 4)
}

fn union(a: ((i32, i32), (i32, i32)), b: ((i32, i32), (i32, i32))) -> ((i32, i32), (i32, i32)) {
    (
        (a.0 .0.min(b.0 .0), a.0 .1.min(b.0 .1)),
        (a.1 .0.max(b.1 .0), a.1 .1.max(b.1 .1)),
    )
}

fn box_chunks(b: &BoundingBox) -> ((i32, i32), (i32, i32)) {
    (chunk_of(b.min_x, b.min_z), chunk_of(b.max_x, b.max_z))
}

/// `JigsawPlacement.generateJigsaw`'s pieces config: the named start jigsaw,
/// 128 blocks each way, no projection, no padding, waterlogging applied.
fn jigsaw_config(pool: &str, target: &str, max_depth: i32) -> Result<JigsawConfig, String> {
    use crate::worldgen::json::Json;
    let number = |n: i32| Json::Number(n as f64);
    JigsawConfig::parse(&Json::Object(vec![
        ("start_pool".into(), Json::String(pool.into())),
        ("start_jigsaw_name".into(), Json::String(target.into())),
        ("size".into(), number(max_depth)),
        (
            "start_height".into(),
            Json::Object(vec![("absolute".into(), number(0))]),
        ),
        ("use_expansion_hack".into(), Json::Bool(false)),
        ("max_distance_from_center".into(), number(128)),
    ]))
}

impl Worldgen {
    fn structure_index(&mut self, biome_source: &BiomeSource, id: &str) -> Result<usize, String> {
        let env = self.structure_env(biome_source)?;
        env.registry
            .structures
            .iter()
            .position(|s| s.id == id)
            .ok_or_else(|| format!("unknown structure {id}"))
    }

    /// Plans `placement` at block `pos`.
    pub fn place_plan(
        &mut self,
        biome_source: &BiomeSource,
        placement: &Placement,
        pos: [i32; 3],
    ) -> Result<Plan, String> {
        let here = chunk_of(pos[0], pos[2]);
        let plan = match placement {
            Placement::Feature(_)
            | Placement::Sapling(_)
            | Placement::Grass(_)
            | Placement::Mushroom(_) => {
                let around = ((here.0 - 1, here.1 - 1), (here.0 + 1, here.1 + 1));
                Plan::Chunks {
                    checked: around,
                    area: around,
                }
            }
            Placement::Template {
                id,
                rotation,
                mirror,
                ..
            } => {
                let decoration = self.decoration(biome_source)?;
                let templates = decoration.templates()?;
                if !templates.has(id) {
                    return Ok(Plan::Invalid);
                }
                let template = templates.template(id)?;
                let size = template.size;
                // Vanilla checks the unrotated size from the position.
                let checked = (here, chunk_of(pos[0] + size[0], pos[2] + size[2]));
                let settings = template_settings(*rotation, *mirror, 1.0, false, Vec::new());
                let b = template.bounding_box(&settings, pos);
                let written = (chunk_of(b.min[0], b.min[2]), chunk_of(b.max[0], b.max[2]));
                Plan::Chunks {
                    checked,
                    area: union(checked, written),
                }
            }
            Placement::Structure(id) => {
                let index = self.structure_index(biome_source, id)?;
                let env = self.structure_env(biome_source)?;
                match env.generate_anywhere(index, here.0, here.1)? {
                    None => Plan::Failed,
                    Some(start) => {
                        let range = box_chunks(&start.bbox);
                        Plan::Chunks {
                            checked: range,
                            area: range,
                        }
                    }
                }
            }
            Placement::Jigsaw {
                pool,
                target,
                max_depth,
            } => {
                let env = self.structure_env(biome_source)?;
                let config = jigsaw_config(pool, target, *max_depth)?;
                match env.jigsaw_anywhere(&config, pos)? {
                    Some(pieces) if !pieces.is_empty() => {
                        let range = pieces
                            .iter()
                            .map(|p| box_chunks(&p.bbox))
                            .fold((here, here), union);
                        Plan::Chunks {
                            checked: (here, here),
                            area: range,
                        }
                    }
                    _ => Plan::Failed,
                }
            }
        };
        if let Plan::Chunks { area, .. } = plan {
            if area.1 .0 - area.0 .0 >= MAX_SPAN || area.1 .1 - area.0 .1 >= MAX_SPAN {
                return Ok(Plan::TooLarge);
            }
        }
        Ok(plan)
    }

    /// A proto chunk of the live world from its column image (`None`: the
    /// flat base profile `base`, one state per level from the bottom).
    pub fn place_chunk(
        &mut self,
        biome_source: &BiomeSource,
        (x, z): (i32, i32),
        image: Option<&[u8]>,
        base: &[u16],
    ) -> Result<ProtoChunk, String> {
        let column = match image {
            Some(bytes) => Column::from_image(bytes).ok_or("an unreadable column image")?,
            None => {
                let layers: &[u16; COLUMN_HEIGHT] = base
                    .try_into()
                    .map_err(|_| "a base profile of 384 levels")?;
                Column::from_layers(layers)
            }
        };
        let decoration = self.decoration(biome_source)?;
        let (min_y, height) = decoration.dimension;
        let mut blocks = Vec::with_capacity(256 * height as usize);
        for column_index in 0..256 {
            let (bx, bz) = (column_index & 15, column_index >> 4);
            for y in min_y..min_y + height {
                let inside = (COLUMN_MIN_Y..COLUMN_MIN_Y + COLUMN_HEIGHT as i32).contains(&y);
                blocks.push(if inside {
                    column.get(bx, y, bz)
                } else {
                    self.registry.blocks.air
                });
            }
        }
        let biomes = self.cached_chunk_biomes(biome_source, x, z)?;
        Ok(ProtoChunk::new(
            x,
            z,
            (min_y, height),
            blocks,
            biomes,
            &decoration.table,
        ))
    }

    /// Runs a planned placement over `chunks` (the plan's area) with the
    /// level random `seed`: what it changed, or `None` when vanilla's call
    /// returns false (a feature or template that placed nothing).
    pub fn place(
        &mut self,
        biome_source: &BiomeSource,
        placement: &Placement,
        pos: [i32; 3],
        chunks: Vec<ProtoChunk>,
        seed: i64,
    ) -> Result<Option<Placed>, String> {
        let decoration = self.decoration(biome_source)?;
        let originals: HashMap<(i32, i32), Vec<u16>> = chunks
            .iter()
            .map(|c| ((c.x, c.z), c.blocks.clone()))
            .collect();
        let mut area = Area::of(chunks)?;
        let (x0, z0, size) = (area.x, area.z, area.size);
        let centre = (x0 + size / 2, z0 + size / 2);
        let zoom_seed = surface::biome_zoom_seed(self.seed);
        let mut random = Random::legacy(seed);
        let env = match placement {
            Placement::Structure(_) | Placement::Jigsaw { .. } => {
                Some(self.structure_env(biome_source)?)
            }
            _ => None,
        };
        let structure = match placement {
            Placement::Structure(id) => Some(self.structure_index(biome_source, id)?),
            _ => None,
        };
        let placed = {
            let mut region = Region::new(
                &mut area,
                &decoration.table,
                centre,
                self.seed,
                zoom_seed,
                self.settings.sea_level,
            )?;
            region.write_radius = size;
            region.lenient = true;
            let placed = match placement {
                Placement::Feature(id) => {
                    let feature = decoration
                        .features
                        .get(id)
                        .cloned()
                        .ok_or_else(|| format!("unknown feature {id}"))?;
                    feature.place(&decoration, &mut region, &mut random, pos)?
                }
                Placement::Sapling(grower) => {
                    grow_tree(&decoration, &mut region, &mut random, pos, grower)?
                }
                Placement::Grass(features) => {
                    let biomes = &self.registry.biomes.names;
                    grow_grass(&decoration, &mut region, &mut random, pos, features, biomes)?
                }
                Placement::Mushroom(id) => {
                    grow_mushroom(&decoration, &mut region, &mut random, pos, id)?
                }
                Placement::Template {
                    id,
                    rotation,
                    mirror,
                    integrity,
                    strict,
                } => {
                    let templates = decoration.templates()?;
                    let template = templates.template(id)?;
                    let processors = if *integrity < 1.0 {
                        vec![Processor::BlockRot {
                            rottable: None,
                            integrity: *integrity,
                        }]
                    } else {
                        Vec::new()
                    };
                    let settings =
                        template_settings(*rotation, *mirror, *integrity, *strict, processors);
                    let update = 2 | if *strict { 816 } else { 0 };
                    templates.place(
                        &decoration,
                        &mut region,
                        &template,
                        pos,
                        pos,
                        &settings,
                        &mut random,
                        update,
                    )?
                }
                Placement::Structure(_) => {
                    let env = env.as_ref().expect("structure env");
                    let index = structure.expect("structure index");
                    let here = chunk_of(pos[0], pos[2]);
                    let Some(mut start) = env.generate_anywhere(index, here.0, here.1)? else {
                        return Ok(None);
                    };
                    place_start(
                        &decoration,
                        self.seed,
                        &mut region,
                        &mut random,
                        &mut start,
                        env,
                    )?;
                    true
                }
                Placement::Jigsaw {
                    pool,
                    target,
                    max_depth,
                } => {
                    let env = env.as_ref().expect("structure env");
                    let config = jigsaw_config(pool, target, *max_depth)?;
                    let Some(mut pieces) = env.jigsaw_anywhere(&config, pos)? else {
                        return Ok(None);
                    };
                    let placer = Placer::new(&decoration, self.seed)?;
                    let everywhere = BoundingBox::new(
                        i32::MIN,
                        i32::MIN,
                        i32::MIN,
                        i32::MAX,
                        i32::MAX,
                        i32::MAX,
                    );
                    for piece in pieces.iter_mut() {
                        let mut c = Ctx {
                            placer: &placer,
                            region: &mut region,
                            random: &mut random,
                            chunk_box: everywhere,
                            chunk: chunk_of(pos[0], pos[2]),
                            reference: pos,
                        };
                        jigsaw_place::post_process(piece, &mut c)?;
                    }
                    true
                }
            };
            if let Some(fault) = region.fault.take() {
                return Err(fault);
            }
            placed
        };
        if !placed {
            return Ok(None);
        }
        let table = decoration.table.as_ref();
        let mut out = Placed::default();
        for chunk in area.held() {
            let before = &originals[&(chunk.x, chunk.z)];
            let rows = chunk.height as usize;
            for (i, (&old, &new)) in before.iter().zip(&chunk.blocks).enumerate() {
                if old != new {
                    let column = i / rows;
                    let p = [
                        chunk.x * 16 + (column & 15) as i32,
                        chunk.min_y + (i % rows) as i32,
                        chunk.z * 16 + (column >> 4) as i32,
                    ];
                    out.blocks.push((p, new));
                    out.replaced.push(old);
                }
            }
            for p in &chunk.block_entities {
                let state = chunk.get(p[0], p[1], p[2]).unwrap_or(0);
                let data = chunk.block_entity_data.get(p).cloned();
                let index = ((p[1] - chunk.min_y) + ((p[0] & 15) + (p[2] & 15) * 16) * chunk.height)
                    as usize;
                let changed = before.get(index) != Some(&state);
                if table.flag(state, BLOCK_ENTITY) && (changed || data.is_some()) {
                    out.block_entities.push((*p, state, data));
                }
            }
            out.entities.extend(chunk.entities.iter().cloned());
        }
        Ok(Some(out))
    }
}

/// `TreeGrower.growTree` at the sapling's cell `pos`: a mega tree over a
/// 2 × 2 of the sapling when the grower has one, else a tree (a flower tree
/// beside flowers); the saplings go first (their fluid stays) and come back
/// when the tree does not fit.
fn grow_tree(
    decoration: &crate::worldgen::feature::Decoration,
    region: &mut Region,
    random: &mut Random,
    pos: [i32; 3],
    grower: &Grower,
) -> Result<bool, String> {
    let table = decoration.table.clone();
    let sapling = region.get(pos);
    let block = table.block_of(sapling);
    if let Some(mega) = draw(&grower.mega, &mut |b| random.next_int_bounded(b)) {
        if let Some(feature) = decoration.features.get(mega).cloned() {
            // `findTwoByTwoSaplingPos`: dx 0 then -1, each with dz 0 then -1.
            let square = [(0, 0), (0, -1), (-1, 0), (-1, -1)]
                .into_iter()
                .find(|&(dx, dz)| {
                    [(0, 0), (1, 0), (0, 1), (1, 1)].iter().all(|&(x, z)| {
                        table.block_of(region.get([pos[0] + dx + x, pos[1], pos[2] + dz + z]))
                            == block
                    })
                });
            if let Some((dx, dz)) = square {
                let cells: Vec<([i32; 3], u16)> = [(0, 0), (1, 0), (0, 1), (1, 1)]
                    .iter()
                    .map(|&(x, z)| {
                        let p = [pos[0] + dx + x, pos[1], pos[2] + dz + z];
                        (p, region.get(p))
                    })
                    .collect();
                for &(p, state) in &cells {
                    region.set(p, table.remains[state as usize], 818);
                }
                if feature.place(
                    decoration,
                    region,
                    random,
                    [pos[0] + dx, pos[1], pos[2] + dz],
                )? {
                    return Ok(true);
                }
                for &(p, state) in &cells {
                    region.set(p, state, 260);
                }
                return Ok(false);
            }
        }
    }
    let flowers = table.tag("minecraft:flowers")?.clone();
    let mut has_flowers = false;
    for y in -1..=1 {
        for z in -2..=2 {
            for x in -2..=2 {
                let state = region.get([pos[0] + x, pos[1] + y, pos[2] + z]);
                has_flowers |= flowers.contains(table.block_of(state));
            }
        }
    }
    let list = if has_flowers && !grower.flowers.is_empty() {
        &grower.flowers
    } else {
        &grower.trees
    };
    let Some(key) = draw(list, &mut |b| random.next_int_bounded(b)) else {
        return Ok(false);
    };
    let Some(feature) = decoration.features.get(key).cloned() else {
        return Ok(false);
    };
    region.set(pos, table.remains[sapling as usize], 818);
    if feature.place(decoration, region, random, pos)? {
        return Ok(true);
    }
    region.set(pos, sapling, 260);
    Ok(false)
}

/// `GrassBlock.performBonemeal` on the grass block at `pos`: 128 tries,
/// the later ones wandering farther over grass blocks, each growing the
/// short grass it finds into tall grass now and then and placing on air the
/// grass feature, or by chance one of the biome's bone meal features.
/// Whether anything was tried (always).
fn grow_grass(
    d: &crate::worldgen::feature::Decoration,
    region: &mut Region,
    random: &mut Random,
    pos: [i32; 3],
    features: &HashMap<String, Vec<String>>,
    biomes: &[String],
) -> Result<bool, String> {
    let table = d.table.clone();
    let grass_block = table.block("grass_block")?;
    let short_grass = table.block("short_grass")?;
    let tall_grass = table.default_state("tall_grass")?;
    let grass = d
        .placed
        .get(crate::worldgen::feature::GRASS_BONEMEAL)
        .cloned();
    let inside = |y: i32| (COLUMN_MIN_Y..COLUMN_MIN_Y + COLUMN_HEIGHT as i32).contains(&y);
    let above = [pos[0], pos[1] + 1, pos[2]];
    'attempts: for attempt in 0..128 {
        let mut cell = above;
        for _ in 0..attempt / 16 {
            let dx = random.next_int_bounded(3) - 1;
            let dy = (random.next_int_bounded(3) - 1) * random.next_int_bounded(3) / 2;
            let dz = random.next_int_bounded(3) - 1;
            cell = [cell[0] + dx, cell[1] + dy, cell[2] + dz];
            // `stopBonemealSpread`.
            let below = region.get([cell[0], cell[1] - 1, cell[2]]);
            if table.block_of(below) != grass_block
                || table.flag(region.get(cell), crate::worldgen::blocks::FULL_COLLISION)
            {
                continue 'attempts;
            }
        }
        // `placeBonemealEffect`.
        let state = region.get(cell);
        let top = [cell[0], cell[1] + 1, cell[2]];
        if table.block_of(state) == short_grass
            && random.next_float() < 0.1
            && d.survives(region, tall_grass, cell)
            && table.is_air(region.get(top))
            && inside(top[1])
        {
            region.set(cell, tall_grass, 2);
            let upper = table
                .with(tall_grass, "half", "upper")
                .ok_or("no tall grass top")?;
            region.set(top, upper, 2);
        }
        if !table.is_air(state) || !inside(cell[1]) {
            continue;
        }
        if random.next_float() < 0.125 {
            let biome = region.biome(cell);
            let list = biomes
                .get(biome as usize)
                .and_then(|name| features.get(name))
                .map_or(&[][..], |l| &l[..]);
            if list.is_empty() {
                continue;
            }
            let id = &list[random.next_int_bounded(list.len() as i32) as usize];
            let feature = d
                .features
                .get(id)
                .cloned()
                .ok_or_else(|| format!("unknown feature {id}"))?;
            feature.place(d, region, random, cell)?;
        } else if let Some(grass) = &grass {
            grass.place(d, region, random, cell, false)?;
        }
    }
    Ok(true)
}

/// `MushroomBlock.growMushroom`: the mushroom goes (its fluid stays), the
/// huge mushroom grows at its cell, and the mushroom comes back when it does
/// not fit.
fn grow_mushroom(
    d: &crate::worldgen::feature::Decoration,
    region: &mut Region,
    random: &mut Random,
    pos: [i32; 3],
    id: &str,
) -> Result<bool, String> {
    let table = d.table.clone();
    let feature = d
        .features
        .get(id)
        .cloned()
        .ok_or_else(|| format!("unknown feature {id}"))?;
    let mushroom = region.get(pos);
    region.set(pos, table.remains[mushroom as usize], 3);
    if feature.place(d, region, random, pos)? {
        return Ok(true);
    }
    region.set(pos, mushroom, 3);
    Ok(false)
}

/// `StructureStart.placeInChunk` for each chunk of the start's box, with the
/// level's random and the chunk's full height, as `/place structure` does.
fn place_start(
    decoration: &crate::worldgen::feature::Decoration,
    seed: i64,
    region: &mut Region,
    random: &mut Random,
    start: &mut Start,
    env: &crate::worldgen::structure::StructureEnv,
) -> Result<(), String> {
    let placer = Placer::new(decoration, seed)?;
    let (min_y, height) = (region.min_y(), region.height());
    let ((x0, z0), (x1, z1)) = box_chunks(&start.bbox);
    for cz in z0..=z1 {
        for cx in x0..=x1 {
            let mut c = Ctx {
                placer: &placer,
                region: &mut *region,
                random: &mut *random,
                chunk_box: BoundingBox::new(
                    cx * 16,
                    min_y,
                    cz * 16,
                    cx * 16 + 15,
                    min_y + height,
                    cz * 16 + 15,
                ),
                chunk: (cx, cz),
                reference: [0; 3],
            };
            place_in_chunk(start, &mut c, &env.registry)?;
        }
    }
    Ok(())
}

/// `/place template`'s `StructurePlaceSettings`: mirror, rotation, the known
/// shape when strict; with integrity below 1, a block rot processor and the
/// seeded random shared.
fn template_settings(
    rotation: Rotation,
    mirror: Mirror,
    integrity: f32,
    strict: bool,
    processors: Vec<Processor>,
) -> PlaceSettings {
    let mut settings = PlaceSettings::piece(mirror, rotation, [0, 0, 0], processors);
    settings.shared_random = integrity < 1.0;
    settings.known_shape = strict;
    settings
}
