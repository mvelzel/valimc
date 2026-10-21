//! Oracle parity and benchmark entry points (scripts/check_*.exs, bench/),
//! built only with the `parity` feature (dev, test and bench builds).

use crate::codec::{imported_column, SectionSpec};
use crate::facts::{FLAGS, LIGHT};
use crate::region::{error, with_owned, with_store, Region};
use crate::worldgen::{WorldgenRegistry, WorldgenState};
use crate::{atoms, bytes, done, reply};
use rustler::{Atom, Binary, Env, NewBinary, NifResult, ResourceArc};

/// Light of chunks given as column images over the chunk rectangle starting at
/// (`min_cx`, `min_cz`), lit as a live region lights generated chunks: one at a
/// time in the given order, each with its light alone, then across its faces;
/// absent chunks are unknown. Returns, per given chunk, 24 sections of sky then
/// block nibble arrays (vanilla layout).
#[rustler::nif(schedule = "DirtyCpu")]
fn light_columns<'a>(
    env: Env<'a>,
    images: Vec<(i32, i32, Binary)>,
    min_cx: i32,
    min_cz: i32,
    chunks_x: usize,
    chunks_z: usize,
) -> Result<Vec<(i32, i32, Binary<'a>)>, Atom> {
    use valimc_core::column::{Column, SECTIONS};
    use valimc_core::light_grid::{light_alone, Blocks, Kind, LightGrid};
    let facts = LIGHT.get().ok_or(atoms::light_facts_missing())?;
    if chunks_x > 128 || chunks_z > 128 {
        return Err(atoms::out_of_region());
    }
    let mut columns: Vec<Option<Column>> = (0..chunks_x * chunks_z).map(|_| None).collect();
    let mut order = Vec::new();
    for (cx, cz, image) in &images {
        let column = Column::from_image(image.as_slice()).ok_or(atoms::invalid_layers())?;
        let (ax, az) = (cx - min_cx, cz - min_cz);
        if ax < 0 || az < 0 || ax as usize >= chunks_x || az as usize >= chunks_z {
            return Err(atoms::out_of_region());
        }
        columns[ax as usize * chunks_z + az as usize] = Some(column);
        order.push((*cx, *cz, ax as usize, az as usize));
    }
    let blocks = Blocks {
        nx: chunks_x,
        nz: chunks_z,
        chunks: columns
            .iter()
            .map(|c| c.as_ref().map(|c| &c.sections[..]))
            .collect(),
        sky: true,
    };
    let mut grid = LightGrid::new(chunks_x, chunks_z);
    for &(_, _, ax, az) in &order {
        let sections = blocks.chunks[ax * chunks_z + az].unwrap();
        let alone = light_alone(sections, facts, true);
        grid.install(&blocks, facts, vec![((ax, az), Some(alone))]);
    }
    Ok(order
        .into_iter()
        .map(|(cx, cz, ax, az)| {
            let (sky, block) = (
                grid.layers(Kind::Sky, ax, az).unwrap(),
                grid.layers(Kind::Block, ax, az).unwrap(),
            );
            let mut out = Vec::with_capacity(SECTIONS * 4096);
            for s in 0..SECTIONS {
                out.extend(sky[s].nibbles());
                out.extend(block[s].nibbles());
            }
            (cx, cz, bytes(env, out))
        })
        .collect())
}

/// Run a random-source operation trace (`valimc_core::worldgen::trace`).
#[rustler::nif]
fn worldgen_random_trace(
    kind: String,
    seed: i64,
    ops: Vec<String>,
) -> NifResult<(Atom, Vec<String>)> {
    reply(valimc_core::worldgen::trace::run(&kind, seed, &ops))
}

type NoiseSamples = (Vec<u32>, Vec<u32>, Vec<Vec<u32>>);

/// Sample a noise for parity checks (`valimc_core::worldgen::trace::noise`):
/// float bits of 3D points, 2D points and volumes.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_noise_samples(
    random: (String, i64, String),
    noise: String,
    params: Vec<f64>,
    points: Vec<(f64, f64, f64)>,
    volumes: Vec<(Vec<i32>, f64, f64)>,
) -> NifResult<(Atom, NoiseSamples)> {
    reply((|| {
        let volumes = volumes
            .into_iter()
            .map(|(v, xz, y)| {
                Ok((
                    <[i32; 9]>::try_from(v).map_err(|_| "volume needs 9 integers")?,
                    xz,
                    y,
                ))
            })
            .collect::<Result<Vec<_>, String>>()?;
        let (kind, seed, source) = random;
        let samples = valimc_core::worldgen::trace::noise(
            (&kind, seed, &source),
            &noise,
            &params,
            &points,
            &volumes,
        )?;
        Ok((samples.points, samples.points_2d, samples.volumes))
    })())
}

/// Sample a density function for parity checks
/// (`valimc_core::worldgen::trace::density`).
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_density_samples(
    state: ResourceArc<WorldgenState>,
    function: String,
    cached: bool,
    ops: Vec<Vec<i32>>,
) -> NifResult<(Atom, Vec<Vec<u32>>)> {
    reply((|| {
        let mut state = state.lease()?;
        valimc_core::worldgen::trace::density(&mut state, &function, cached, &ops)
    })())
}

/// Biome names, then per chunk its biome and climate target binaries.
type ChunkBiomeBinaries<'a> = (Vec<String>, Vec<(Binary<'a>, Binary<'a>)>);

/// Multi-noise biomes of chunks in order (lookup history carries from one
/// chunk to the next, starting empty): the preset's biome names, and per chunk
/// its biome indices (one byte per quart, sections from the bottom, index
/// order y, z, x) and its climate targets (six big-endian i64 per lookup, in
/// lookup order).
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_chunk_biomes<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    preset: String,
    chunks: Vec<(i32, i32)>,
) -> NifResult<(Atom, ChunkBiomeBinaries<'a>)> {
    reply((|| {
        let mut state = state.lease()?;
        let list = state.biome_parameters(&preset)?;
        let mut last = None;
        let mut out = Vec::with_capacity(chunks.len());
        for (x, z) in chunks {
            let filled = state.fill_biomes(&list, x, z, &mut last)?;
            let mut biomes = NewBinary::new(env, filled.biomes.len());
            for (b, &v) in biomes.as_mut_slice().iter_mut().zip(&filled.biomes) {
                *b = u8::try_from(v).map_err(|_| "more than 256 biomes")?;
            }
            let mut targets = NewBinary::new(env, filled.targets.len() * 48);
            for (chunk, target) in targets.as_mut_slice().chunks_mut(48).zip(&filled.targets) {
                for (bytes, value) in chunk.chunks_mut(8).zip(target) {
                    bytes.copy_from_slice(&value.to_be_bytes());
                }
            }
            out.push((biomes.into(), targets.into()));
        }
        Ok((list.biomes.clone(), out))
    })())
}

/// The biomes at the minimal climate distance from a target: the answers a
/// lookup can give, depending on lookup history.
#[rustler::nif]
fn worldgen_closest_biomes(
    state: ResourceArc<WorldgenState>,
    preset: String,
    target: Vec<i64>,
) -> NifResult<(Atom, Vec<String>)> {
    reply((|| {
        let state = state.lease()?;
        let list = state.biome_parameters(&preset)?;
        let target: [i64; 6] = target.try_into().map_err(|_| "a target has six values")?;
        Ok(list
            .closest_biomes(&target)
            .into_iter()
            .map(|b| list.biomes[b as usize].clone())
            .collect())
    })())
}

/// A chunk's state ids and fluid update positions.
type FilledBinary<'a> = (Binary<'a>, Vec<(i32, i32, i32)>);

/// Noise terrain of chunks (`Worldgen::fill_terrain`): per chunk its state ids
/// (big-endian u16, Y fastest from the bottom, then X, then Z) and the fluid
/// positions marked for updates.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_fill_terrain<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    chunks: Vec<(i32, i32)>,
) -> NifResult<(Atom, Vec<FilledBinary<'a>>)> {
    reply((|| {
        let mut state = state.lease()?;
        let mut out = Vec::with_capacity(chunks.len());
        for (x, z) in chunks {
            let filled = state.fill_terrain(x, z)?;
            let mut blocks = NewBinary::new(env, filled.blocks.len() * 2);
            for (bytes, id) in blocks.as_mut_slice().chunks_mut(2).zip(&filled.blocks) {
                bytes.copy_from_slice(&id.to_be_bytes());
            }
            out.push((blocks.into(), filled.fluid_updates));
        }
        Ok(out)
    })())
}

/// Terrain of chunks with their material rule applied and, with `carve`,
/// carved (`Worldgen::build_terrain`), biomes from `biome_source`: per chunk
/// its state ids (as for `worldgen_fill_terrain`) and fluid update positions.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_build_terrain<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    carve: bool,
    chunks: Vec<(i32, i32)>,
) -> NifResult<(Atom, Vec<FilledBinary<'a>>)> {
    reply((|| {
        let mut state = state.lease()?;
        let mut out = Vec::with_capacity(chunks.len());
        for (x, z) in chunks {
            let filled = state.build_terrain(x, z, &biome_source, carve)?;
            let mut blocks = NewBinary::new(env, filled.blocks.len() * 2);
            for (bytes, id) in blocks.as_mut_slice().chunks_mut(2).zip(&filled.blocks) {
                bytes.copy_from_slice(&id.to_be_bytes());
            }
            out.push((blocks.into(), filled.fluid_updates));
        }
        Ok(out)
    })())
}

/// A scheduled tick: position, block id or fluid name, delay and priority.
type BlockTick = ((i32, i32, i32), u16, i32, i32);
type FluidTick = ((i32, i32, i32), String, i32, i32);

/// One decorated chunk for `check_decoration.exs`.
/// A created block entity for NBT parity: position, state, type, the NBT a
/// template gave (or ""), loot table (or "") and seed.
type BlockEntityNbt = ((i32, i32, i32), u16, String, String, String, i64);

#[derive(rustler::NifMap)]
struct DecoratedChunk<'a> {
    x: i32,
    z: i32,
    blocks: Binary<'a>,
    marks: Vec<(i32, i32, i32)>,
    block_ticks: Vec<BlockTick>,
    fluid_ticks: Vec<FluidTick>,
    block_entities: Vec<(i32, i32, i32)>,
    /// Created block entities: "x,y,z,type,loot table,seed,spawned entity,
    /// bees,gateway exit" (the exit as "x;y;z;exact").
    block_entity_data: Vec<String>,
    /// Entities features added: "type,x,y,z,yaw".
    entities: Vec<String>,
    /// Created block entities for NBT parity (VMC-025f): position, state,
    /// type, the NBT a template gave (or ""), loot table (or "") and seed.
    block_entity_nbt: Vec<BlockEntityNbt>,
}

/// Decoration parity (VMC-025): the 5 × 5 chunks around `centre` with their
/// terrain, the chunks in `order` decorated with the placed features in
/// `features` ((step, global index) pairs), and every chunk's blocks (big
/// endian), post-processing marks, scheduled ticks and block entities.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_decorate<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    centre: (i32, i32),
    order: Vec<(i32, i32)>,
    features: Vec<(usize, usize)>,
) -> NifResult<(Atom, Vec<DecoratedChunk<'a>>)> {
    reply((|| {
        let mut state = state.lease()?;
        let included: std::collections::HashSet<(usize, usize)> = features.into_iter().collect();
        let area = state.decorate_area(
            &biome_source,
            (centre.0 - 2, centre.1 - 2),
            5,
            &order,
            Some(&included),
        )?;
        Ok(area
            .held()
            .map(|chunk| decorated_chunk(env, chunk))
            .collect())
    })())
}

/// Structure placement parity (VMC-025f): the 5 × 5 chunks around `centre`
/// with their terrain, the chunks in `order` decorated with every placed
/// feature and the starts of `structures` (identifiers) placed in their
/// Decorated chunks and each start as placement left it.
type DecoratedStarts<'a> = (Vec<DecoratedChunk<'a>>, Vec<String>);

/// steps; also each start as placement left it (canonical SNBT).
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_decorate_structures<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    centre: (i32, i32),
    order: Vec<(i32, i32)>,
    structures: Vec<String>,
) -> NifResult<(Atom, DecoratedStarts<'a>)> {
    reply((|| {
        let mut state = state.lease()?;
        let registry = state.structure_env(&biome_source)?.registry.clone();
        let included = structures
            .iter()
            .map(|id| {
                registry
                    .structures
                    .iter()
                    .position(|s| &s.id == id)
                    .ok_or_else(|| format!("unknown structure {id}"))
            })
            .collect::<Result<std::collections::HashSet<_>, _>>()?;
        let (area, starts) = state.decorate_area_structures(
            &biome_source,
            (centre.0 - 2, centre.1 - 2),
            5,
            &order,
            Some(&included),
        )?;
        Ok((
            area.held()
                .map(|chunk| decorated_chunk(env, chunk))
                .collect(),
            starts.iter().map(|s| s.save(&registry).snbt()).collect(),
        ))
    })())
}

/// A chunk's blocks (big endian), post-processing marks, scheduled ticks and
/// block entities, as `check_decoration.exs` compares them.
fn decorated_chunk<'a>(
    env: rustler::Env<'a>,
    chunk: &valimc_core::worldgen::region::ProtoChunk,
) -> DecoratedChunk<'a> {
    use valimc_core::worldgen::blocks::FLUID_NAMES;
    // As vanilla reads them (air-only sections as air; air is state 0).
    let observed = chunk.observed_blocks(0);
    let mut blocks = NewBinary::new(env, observed.len() * 2);
    for (bytes, id) in blocks.as_mut_slice().chunks_mut(2).zip(&observed) {
        bytes.copy_from_slice(&id.to_be_bytes());
    }
    let p = |p: &[i32; 3]| (p[0], p[1], p[2]);
    DecoratedChunk {
        x: chunk.x,
        z: chunk.z,
        blocks: blocks.into(),
        marks: chunk.marks.iter().map(p).collect(),
        block_ticks: chunk
            .block_ticks
            .iter()
            .map(|(pos, b)| (p(pos), *b, 0, 0))
            .collect(),
        fluid_ticks: chunk
            .fluid_ticks
            .iter()
            .map(|(pos, f)| (p(pos), FLUID_NAMES[*f as usize].to_string(), 0, 0))
            .collect(),
        block_entities: chunk.block_entities.iter().map(p).collect(),
        block_entity_data: chunk
            .block_entity_data
            .iter()
            .map(|(pos, data)| {
                let bees: Vec<String> = data.bees.iter().map(|t| t.to_string()).collect();
                format!(
                    "{},{},{},{},{},{},{},{},{}",
                    pos[0],
                    pos[1],
                    pos[2],
                    data.kind,
                    data.loot_table.as_deref().unwrap_or("-"),
                    data.loot_seed,
                    data.spawner_entity.as_deref().unwrap_or("-"),
                    if bees.is_empty() {
                        "-".to_string()
                    } else {
                        bees.join("/")
                    },
                    match data.exit {
                        Some((e, exact)) => format!("{};{};{};{exact}", e[0], e[1], e[2]),
                        None => "-".to_string(),
                    }
                )
            })
            .collect(),
        entities: chunk
            .entities
            .iter()
            .map(|e| {
                // Shortest round-trip decimals, as Java's `toString` writes them.
                format!(
                    "{},{:?},{:?},{:?},{:?}",
                    e.kind, e.pos[0], e.pos[1], e.pos[2], e.yaw
                )
            })
            .collect(),
        block_entity_nbt: chunk
            .block_entity_data
            .iter()
            .map(|(pos, data)| {
                (
                    (pos[0], pos[1], pos[2]),
                    chunk.get(pos[0], pos[1], pos[2]).unwrap_or(0),
                    data.kind.to_string(),
                    data.nbt.as_deref().unwrap_or("").to_string(),
                    data.loot_table.clone().unwrap_or_default(),
                    data.loot_seed,
                )
            })
            .collect(),
    }
}

/// A shape update case: state, direction (`Direction` order) and the
/// neighbours as (dx, dy, dz, state).
type ShapeCase = (u16, usize, Vec<(i32, i32, i32, u16)>);
/// Its outcome: the new state and the scheduled ticks (dx, dy, dz, fluid?, id).
type ShapeOutcome = (u16, Vec<(i32, i32, i32, bool, u16)>);

/// Shape update parity (VMC-026a): `Decoration::shape_cases` through the
/// overworld's decoration (the updates read only the cells around).
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_shape_cases(
    registry: ResourceArc<WorldgenRegistry>,
    cases: Vec<ShapeCase>,
) -> NifResult<(Atom, Vec<ShapeOutcome>)> {
    reply((|| {
        let decoration = registry
            .registry
            .decorations
            .get("minecraft:overworld")
            .ok_or("no decoration facts")?;
        let cases: Vec<_> = cases
            .into_iter()
            .map(|(state, d, cells)| {
                let cells = cells
                    .into_iter()
                    .map(|(x, y, z, s)| ([x, y, z], s))
                    .collect();
                (state, d, cells)
            })
            .collect();
        Ok(decoration
            .shape_cases(&cases)?
            .into_iter()
            .map(|(state, ticks)| {
                let ticks = ticks
                    .into_iter()
                    .map(|(o, fluid, id)| (o[0], o[1], o[2], fluid, id))
                    .collect();
                (state, ticks)
            })
            .collect())
    })())
}

/// Decoration benchmark (VMC-025): the `size` × `size` area from `origin`,
/// the chunks in `order` decorated with `features`; nanoseconds of decoration
/// (terrain excluded).
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_decoration_time(
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    origin: (i32, i32),
    size: i32,
    order: Vec<(i32, i32)>,
    features: Vec<(usize, usize)>,
) -> NifResult<(Atom, u64)> {
    reply((|| {
        let mut state = state.lease()?;
        let included: std::collections::HashSet<(usize, usize)> = features.into_iter().collect();
        let (_, elapsed) =
            state.decorate_area_timed(&biome_source, origin, size, &order, Some(&included))?;
        Ok(elapsed.as_nanos() as u64)
    })())
}

/// Structure generation for parity checks (VMC-025e): the structure sets
/// that can occur for `biome_source`, and every concentric ring set's
/// positions.
type RingPositions = Vec<(String, Vec<(i32, i32)>)>;

#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_structure_state(
    state: ResourceArc<WorldgenState>,
    biome_source: String,
) -> NifResult<(Atom, (Vec<String>, RingPositions))> {
    reply((|| {
        let env = {
            let mut state = state.lease()?;
            state.structure_env(&biome_source)?
        };
        let sets = &env.registry.sets;
        let possible = env.possible.iter().map(|&s| sets[s].id.clone()).collect();
        let rings = env
            .possible
            .iter()
            .filter_map(|&s| {
                env.ring_positions(s)
                    .map(|positions| (sets[s].id.clone(), positions.to_vec()))
            })
            .collect();
        Ok((possible, rings))
    })())
}

/// A structure start: its chunk, structure and canonical SNBT.
type StartRow = (i32, i32, String, String);
/// Starts, and the sets skipped.
type StartRows = (Vec<StartRow>, Vec<String>);

/// `createStructures` in fresh chunks (VMC-025e): every start, and the sets
/// skipped because ValiMC does not generate one of their structure types yet.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_structure_starts(
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    chunks: Vec<(i32, i32)>,
) -> NifResult<(Atom, StartRows)> {
    reply((|| {
        let env = {
            let mut state = state.lease()?;
            state.structure_env(&biome_source)?
        };
        let registry = &env.registry;
        let mut rows = Vec::new();
        let mut skipped = std::collections::BTreeSet::new();
        for (x, z) in chunks {
            let (starts, skips) = env.create_structures(x, z)?;
            skipped.extend(skips.into_iter().map(|s| registry.sets[s].id.clone()));
            for start in starts {
                rows.push((
                    x,
                    z,
                    registry.structures[start.structure].id.clone(),
                    start.save(registry).snbt(),
                ));
            }
        }
        Ok((rows, skipped.into_iter().collect()))
    })())
}

/// Per structure set, its placement chunks in a window.
type WindowPlacements = Vec<(String, Vec<(i32, i32)>)>;
/// A chunk's references to one structure: chunk, structure, source chunks.
type ReferenceRow = (i32, i32, String, Vec<(i32, i32)>);

/// Placement and references over a `size` × `size` window from `origin`
/// (VMC-025e): each possible set's placement chunks, and for the chunks at
/// least 8 from the edge, their references (`createReferences`) to the
/// window's starts.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_structure_window(
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    origin: (i32, i32),
    size: i32,
) -> NifResult<(Atom, (WindowPlacements, Vec<ReferenceRow>))> {
    reply((|| {
        let env = {
            let mut state = state.lease()?;
            state.structure_env(&biome_source)?
        };
        let registry = &env.registry;
        let mut placements = Vec::new();
        for &set in &env.possible {
            let mut hits = Vec::new();
            for dz in 0..size {
                for dx in 0..size {
                    let (x, z) = (origin.0 + dx, origin.1 + dz);
                    if env.is_structure_chunk(set, x, z) {
                        hits.push((x, z));
                    }
                }
            }
            placements.push((registry.sets[set].id.clone(), hits));
        }
        let mut starts = std::collections::HashMap::new();
        for dz in 0..size {
            for dx in 0..size {
                let (x, z) = (origin.0 + dx, origin.1 + dz);
                starts.insert((x, z), env.create_structures(x, z)?.0);
            }
        }
        let starts_at = |x: i32, z: i32| starts.get(&(x, z)).map(Vec::as_slice);
        let mut references = Vec::new();
        for dz in 8..size - 8 {
            for dx in 8..size - 8 {
                let (x, z) = (origin.0 + dx, origin.1 + dz);
                let mut by_structure: std::collections::BTreeMap<usize, Vec<(i32, i32)>> =
                    std::collections::BTreeMap::new();
                for (structure, source) in env.references(x, z, &starts_at)? {
                    by_structure.entry(structure).or_default().push(source);
                }
                for (structure, mut sources) in by_structure {
                    sources.sort_unstable();
                    sources.dedup();
                    references.push((x, z, registry.structures[structure].id.clone(), sources));
                }
            }
        }
        Ok((placements, references))
    })())
}

/// Encoded proto chunks as `worldgen_decorate` reports chunks (parity).
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_proto_inspect<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    chunks: Vec<Binary>,
) -> NifResult<(Atom, Vec<DecoratedChunk<'a>>)> {
    reply((|| {
        let state = state.lease()?;
        let mut out = Vec::with_capacity(chunks.len());
        for bytes in &chunks {
            let chunk =
                valimc_core::worldgen::proto::decode(bytes.as_slice(), state.block_table()?)?;
            out.push(decorated_chunk(env, &chunk));
        }
        Ok(out)
    })())
}

/// This thread's CPU time in nanoseconds (`clock_gettime` with the thread
/// CPU clock), so benchmarks on a shared host count only their own work.
fn thread_cpu_ns() -> u64 {
    #[repr(C)]
    struct Timespec {
        tv_sec: i64,
        tv_nsec: i64,
    }
    extern "C" {
        fn clock_gettime(clock: i32, time: *mut Timespec) -> i32;
    }
    #[cfg(target_os = "macos")]
    const THREAD_CPUTIME: i32 = 16;
    #[cfg(not(target_os = "macos"))]
    const THREAD_CPUTIME: i32 = 3;
    let mut time = Timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: clock_gettime writes one timespec through the pointer it gets.
    if unsafe { clock_gettime(THREAD_CPUTIME, &mut time) } == 0 {
        time.tv_sec as u64 * 1_000_000_000 + time.tv_nsec as u64
    } else {
        0
    }
}

/// Structure start benchmark (VMC-025e): the wall and thread CPU
/// nanoseconds `createStructures` takes over the `size` × `size` chunks from
/// `origin`, and the starts made.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_structure_time(
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    origin: (i32, i32),
    size: i32,
) -> NifResult<(Atom, (u64, u64, usize))> {
    reply((|| {
        let env = {
            let mut state = state.lease()?;
            state.structure_env(&biome_source)?
        };
        let mut elapsed = std::time::Duration::ZERO;
        let mut cpu = 0;
        let mut starts = 0;
        for dz in 0..size {
            for dx in 0..size {
                let (begin, begin_cpu) = (std::time::Instant::now(), thread_cpu_ns());
                let (made, _) = env.create_structures(origin.0 + dx, origin.1 + dz)?;
                cpu += thread_cpu_ns() - begin_cpu;
                elapsed += begin.elapsed();
                starts += made.len();
            }
        }
        Ok((elapsed.as_nanos() as u64, cpu, starts))
    })())
}

/// Replace a chunk's column with 24 imported sections, bottom to top
/// (`check_chunk_sections.exs`).
#[rustler::nif]
fn put_column(
    env: Env,
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
    sections: Vec<SectionSpec>,
) -> NifResult<Atom> {
    done((|| {
        let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
        let column = imported_column(&sections)?;
        with_owned(env, &region, |store| {
            store.put_column((cx, cz), column, flags).map_err(error)
        })
    })())
}

/// The region's section memory (`bench/section_storage.exs`).
#[rustler::nif]
fn heap_bytes(region: ResourceArc<Region>) -> Result<usize, Atom> {
    with_store(&region, |store| Ok(store.heap_bytes()))
}
