//! `/place` (VMC-053): vanilla's `PlaceCommand` against chunks of the live
//! world. A placement is planned first (the chunks vanilla checks are loaded
//! and the chunks it writes), then run over proto chunks made from those
//! chunks' columns with a random the caller seeds, as vanilla uses the
//! level's random; the caller writes the blocks and block entities that
//! changed back through the region owners.

use std::collections::HashMap;

use super::Worldgen;
use crate::column::{Column, HEIGHT as COLUMN_HEIGHT, MIN_Y as COLUMN_MIN_Y};
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
}

/// What a placement changed: blocks, the block entities of changed or
/// written positions (with what placement wrote into them), and how many
/// entities it would have added (ValiMC has no mobs yet).
#[derive(Debug, Default)]
pub struct Placed {
    pub blocks: Vec<([i32; 3], u16)>,
    pub block_entities: Vec<([i32; 3], u16, Option<BlockEntityData>)>,
    pub entities: usize,
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
    fn structure_index(&mut self, biome_source: &str, id: &str) -> Result<usize, String> {
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
        biome_source: &str,
        placement: &Placement,
        pos: [i32; 3],
    ) -> Result<Plan, String> {
        let here = chunk_of(pos[0], pos[2]);
        let plan = match placement {
            Placement::Feature(_) => {
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
                return Err("the placement spans too many chunks".into());
            }
        }
        Ok(plan)
    }

    /// A proto chunk of the live world from its column image (`None`: the
    /// flat base profile `base`, one state per level from the bottom).
    pub fn place_chunk(
        &mut self,
        biome_source: &str,
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
        biome_source: &str,
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
            out.entities += chunk.entities.len();
        }
        Ok(Some(out))
    }
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
