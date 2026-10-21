//! World generation for the live server.

use rustler::{Binary, NewBinary, ResourceArc, Term};
use std::sync::Mutex;

/// Worldgen registries parsed from the generated facts.
pub struct WorldgenRegistry {
    pub(crate) registry: std::sync::Arc<valimc_core::worldgen::compiler::Registry>,
}

#[rustler::resource_impl]
impl rustler::Resource for WorldgenRegistry {}

/// Noises and compiled samplers for one seed and noise settings. Compiling is
/// lazy and each state keeps caches, so a call leases a state of its own from
/// a pool (VMC-025d): generations of one seed run in parallel, one state per
/// concurrent call.
pub struct WorldgenState {
    pub(crate) registry: std::sync::Arc<valimc_core::worldgen::compiler::Registry>,
    seed: i64,
    settings: String,
    pool: Mutex<Vec<valimc_core::worldgen::compiler::Worldgen>>,
    /// Chunk biomes every state of the pool shares (VMC-025d4).
    biomes: valimc_core::worldgen::compiler::SharedBiomes,
}

#[rustler::resource_impl]
impl rustler::Resource for WorldgenState {}

/// States kept for reuse; more concurrent calls build more and drop the rest.
const WORLDGEN_POOL: usize = 64;

/// A state leased from a pool, returned when dropped (not after a panic).
pub(crate) struct WorldgenLease<'a> {
    owner: &'a WorldgenState,
    state: Option<valimc_core::worldgen::compiler::Worldgen>,
}

impl WorldgenState {
    pub(crate) fn lease(&self) -> Result<WorldgenLease<'_>, String> {
        let pooled = self
            .pool
            .lock()
            .map_err(|_| "worldgen state poisoned")?
            .pop();
        let state = match pooled {
            Some(state) => state,
            None => {
                let mut state = valimc_core::worldgen::compiler::Worldgen::new(
                    self.registry.clone(),
                    self.seed,
                    &self.settings,
                )?;
                state.share_chunk_biomes(self.biomes.clone());
                state
            }
        };
        Ok(WorldgenLease {
            owner: self,
            state: Some(state),
        })
    }
}

impl std::ops::Deref for WorldgenLease<'_> {
    type Target = valimc_core::worldgen::compiler::Worldgen;
    fn deref(&self) -> &Self::Target {
        self.state.as_ref().expect("leased")
    }
}

impl std::ops::DerefMut for WorldgenLease<'_> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.state.as_mut().expect("leased")
    }
}

impl Drop for WorldgenLease<'_> {
    fn drop(&mut self) {
        if std::thread::panicking() {
            return;
        }
        if let (Some(state), Ok(mut pool)) = (self.state.take(), self.owner.pool.lock()) {
            if pool.len() < WORLDGEN_POOL {
                pool.push(state);
            }
        }
    }
}

pub(crate) fn json_of(term: Term) -> Result<valimc_core::worldgen::json::Json, String> {
    use rustler::TermType;
    use valimc_core::worldgen::json::Json;
    Ok(match term.get_type() {
        TermType::Float => Json::Number(term.decode::<f64>().map_err(|_| "bad float")?),
        TermType::Integer => {
            Json::Number(term.decode::<i64>().map_err(|_| "integer out of range")? as f64)
        }
        TermType::Binary => {
            Json::String(term.decode::<String>().map_err(|_| "string is not UTF-8")?)
        }
        TermType::Atom => match term.atom_to_string().map_err(|_| "bad atom")?.as_str() {
            "true" => Json::Bool(true),
            "false" => Json::Bool(false),
            "nil" => Json::Null,
            other => return Err(format!("unexpected atom {other}")),
        },
        TermType::List => Json::Array(
            term.decode::<Vec<Term>>()
                .map_err(|_| "bad list")?
                .into_iter()
                .map(json_of)
                .collect::<Result<_, _>>()?,
        ),
        TermType::Map => {
            let mut fields = Vec::new();
            for (k, v) in rustler::types::map::MapIterator::new(term).ok_or("bad map")? {
                fields.push((
                    k.decode::<String>()
                        .map_err(|_| "map keys must be strings")?,
                    json_of(v)?,
                ));
            }
            fields.sort_by(|a, b| a.0.cmp(&b.0));
            Json::Object(fields)
        }
        other => return Err(format!("unexpected term type {other:?}")),
    })
}

/// Parse worldgen facts: a map from fact name (`noises`,
/// `density_functions`, `noise_settings`, `biome_parameters`,
/// `material_rules`, `material_conditions`, `biomes`, `blocks`) to its decoded
/// contents, with block states as global state ids.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_registry(facts: Term) -> Result<ResourceArc<WorldgenRegistry>, String> {
    let json = json_of(facts)?;
    let facts = valimc_core::worldgen::compiler::Facts::from_object(&json)?;
    let registry = valimc_core::worldgen::compiler::Registry::parse(&facts)?;
    Ok(ResourceArc::new(WorldgenRegistry {
        registry: std::sync::Arc::new(registry),
    }))
}

/// Worldgen state for a seed and noise settings.
#[rustler::nif]
fn worldgen_new(
    registry: ResourceArc<WorldgenRegistry>,
    seed: i64,
    settings: String,
) -> Result<ResourceArc<WorldgenState>, String> {
    let mut state =
        valimc_core::worldgen::compiler::Worldgen::new(registry.registry.clone(), seed, &settings)?;
    let biomes = valimc_core::worldgen::compiler::SharedBiomes::default();
    state.share_chunk_biomes(biomes.clone());
    Ok(ResourceArc::new(WorldgenState {
        registry: registry.registry.clone(),
        seed,
        settings,
        pool: Mutex::new(vec![state]),
        biomes,
    }))
}

/// A generated chunk: its column image and per column its highest non-air
/// block (`z * 16 + x`).
type GeneratedColumn<'a> = (i32, i32, Binary<'a>, Vec<i32>);

/// The shared spawn's origin column (`Worldgen::spawn_origin`, VMC-027d), or
/// nil without a spawn target.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_spawn_origin(state: ResourceArc<WorldgenState>) -> Result<Option<(i32, i32)>, String> {
    let mut state = state.lease()?;
    state.spawn_origin()
}

/// Generated chunks as region-log column images (`Worldgen::generate_column`),
/// biomes as protocol ids (`protocol_biomes`, by biome registry id).
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_columns<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    protocol_biomes: Vec<u16>,
    chunks: Vec<(i32, i32)>,
) -> Result<Vec<GeneratedColumn<'a>>, String> {
    let mut state = state.lease()?;
    let mut out = Vec::with_capacity(chunks.len());
    for (x, z) in chunks {
        let (column, heights) = state.generate_column(x, z, &biome_source, &protocol_biomes)?;
        let image = column.to_image();
        let mut bytes = NewBinary::new(env, image.len());
        bytes.as_mut_slice().copy_from_slice(&image);
        out.push((x, z, bytes.into(), heights.to_vec()));
    }
    Ok(out)
}

/// An encoded proto chunk with its position (VMC-025d).
type ProtoBinary<'a> = (i32, i32, Binary<'a>);

fn proto_binary<'a>(
    env: rustler::Env<'a>,
    chunk: &valimc_core::worldgen::region::ProtoChunk,
) -> ProtoBinary<'a> {
    let bytes = valimc_core::worldgen::proto::encode(chunk);
    let mut out = NewBinary::new(env, bytes.len());
    out.as_mut_slice().copy_from_slice(&bytes);
    (chunk.x, chunk.z, out.into())
}

/// Chunks at status `terrain` as encoded proto chunks (VMC-025d), biomes
/// from `biome_source`.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_proto_terrain<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    chunks: Vec<(i32, i32)>,
) -> Result<Vec<ProtoBinary<'a>>, String> {
    proto_terrain(env, state, &biome_source, chunks, false)
}

/// `worldgen_proto_terrain` with structures (VMC-025f5): each chunk's beards
/// from the starts that reference it.
#[rustler::nif(schedule = "DirtyCpu", name = "worldgen_proto_terrain")]
fn worldgen_proto_terrain_structures<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    chunks: Vec<(i32, i32)>,
    structures: bool,
) -> Result<Vec<ProtoBinary<'a>>, String> {
    proto_terrain(env, state, &biome_source, chunks, structures)
}

fn proto_terrain<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    biome_source: &str,
    chunks: Vec<(i32, i32)>,
    structures: bool,
) -> Result<Vec<ProtoBinary<'a>>, String> {
    let mut state = state.lease()?;
    let mut out = Vec::with_capacity(chunks.len());
    for (x, z) in chunks {
        let chunk = state.proto_terrain_live(x, z, biome_source, structures)?;
        out.push(proto_binary(env, &chunk));
    }
    Ok(out)
}

/// Decorate the chunks in `order` (VMC-025d) over the encoded proto chunks
/// `chunks` (each decorated chunk's 3 × 3 among them) with every placed
/// feature; the chunks decoration wrote into, re-encoded, and the count of
/// reads of chunks outside `chunks` (which see empty chunks).
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_proto_decorate<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    chunks: Vec<Binary>,
    order: Vec<(i32, i32)>,
) -> Result<(Vec<ProtoBinary<'a>>, u32), String> {
    decorate_protos(env, state, "minecraft:overworld", chunks, order, false)
}

/// `worldgen_proto_decorate` with a biome source's decoration: a multi-noise
/// preset, the End, or `fixed:BIOME` (VMC-028b).
#[rustler::nif(schedule = "DirtyCpu", name = "worldgen_proto_decorate")]
fn worldgen_proto_decorate_in<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    chunks: Vec<Binary>,
    order: Vec<(i32, i32)>,
) -> Result<(Vec<ProtoBinary<'a>>, u32), String> {
    decorate_protos(env, state, &biome_source, chunks, order, false)
}

/// `worldgen_proto_decorate` with structures (VMC-025f5): each step places
/// the structures whose starts reference the chunk before its features.
#[rustler::nif(schedule = "DirtyCpu", name = "worldgen_proto_decorate")]
fn worldgen_proto_decorate_structures<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    chunks: Vec<Binary>,
    order: Vec<(i32, i32)>,
    structures: bool,
) -> Result<(Vec<ProtoBinary<'a>>, u32), String> {
    decorate_protos(env, state, &biome_source, chunks, order, structures)
}

fn decorate_protos<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    biome_source: &str,
    chunks: Vec<Binary>,
    order: Vec<(i32, i32)>,
    structures: bool,
) -> Result<(Vec<ProtoBinary<'a>>, u32), String> {
    let mut state = state.lease()?;
    let mut decoded = Vec::with_capacity(chunks.len());
    for bytes in &chunks {
        decoded.push(valimc_core::worldgen::proto::decode(
            bytes.as_slice(),
            state.block_table()?,
        )?);
    }
    let mut area = valimc_core::worldgen::region::Area::of(decoded)?;
    let lenient_reads =
        state.decorate_held_live(biome_source, &mut area, &order, true, structures)?;
    Ok((
        area.held()
            .filter(|c| c.touched)
            .map(|c| proto_binary(env, c))
            .collect(),
        lenient_reads,
    ))
}

/// A block entity of a full chunk: created (with what decoration wrote into
/// it) or pending (`kind` nil: the block's default block entity).
#[derive(rustler::NifMap)]
struct FullBlockEntity {
    position: (i32, i32, i32),
    state: u16,
    kind: Option<String>,
    loot_table: Option<String>,
    loot_seed: i64,
    spawner_entity: Option<String>,
    bees: Vec<i32>,
    /// An end gateway's exit and exact teleport (VMC-026b).
    exit: Option<((i32, i32, i32), bool)>,
    /// A structure template's NBT for it, as SNBT (VMC-025f5).
    nbt: Option<String>,
}

/// A decorated chunk made full (VMC-025d): its column image (protocol biome
/// ids), first free Y above the highest motion-blocking non-leaf block per
/// column (z * 16 + x), block entities, block ticks (position and the state
/// there, kept only where the block still matches), fluid ticks and
/// post-processing marks.
#[derive(rustler::NifMap)]
struct FullChunk<'a> {
    x: i32,
    z: i32,
    image: Binary<'a>,
    heights: Vec<i32>,
    block_entities: Vec<FullBlockEntity>,
    block_ticks: Vec<((i32, i32, i32), u16)>,
    fluid_ticks: Vec<((i32, i32, i32), String)>,
    marks: Vec<(i32, i32, i32)>,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_proto_full<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    chunks: Vec<Binary>,
    protocol_biomes: Vec<u16>,
) -> Result<Vec<FullChunk<'a>>, String> {
    use valimc_core::worldgen::blocks::{Heightmap, BLOCK_ENTITY, FLUID_NAMES};
    let state = state.lease()?;
    let table = state.block_table()?;
    let mut out = Vec::with_capacity(chunks.len());
    for bytes in &chunks {
        let chunk = valimc_core::worldgen::proto::decode(bytes.as_slice(), table)?;
        let (column, _) = state.final_column(&chunk, &protocol_biomes)?;
        let image = column.to_image();
        let mut binary = NewBinary::new(env, image.len());
        binary.as_mut_slice().copy_from_slice(&image);
        let at = |p: &[i32; 3]| chunk.get(p[0], p[1], p[2]).unwrap_or(0);
        let t = |p: &[i32; 3]| (p[0], p[1], p[2]);
        let block_entities = chunk
            .block_entities
            .iter()
            .filter(|p| table.flag(at(p), BLOCK_ENTITY))
            .map(|p| {
                let data = chunk.block_entity_data.get(p);
                FullBlockEntity {
                    position: t(p),
                    state: at(p),
                    kind: data.map(|d| d.kind.to_string()),
                    loot_table: data.and_then(|d| d.loot_table.clone()),
                    loot_seed: data.map_or(0, |d| d.loot_seed),
                    spawner_entity: data.and_then(|d| d.spawner_entity.clone()),
                    bees: data.map_or_else(Vec::new, |d| d.bees.clone()),
                    exit: data.and_then(|d| d.exit.map(|(e, exact)| ((e[0], e[1], e[2]), exact))),
                    nbt: data.and_then(|d| d.nbt.as_deref().map(str::to_string)),
                }
            })
            .collect();
        out.push(FullChunk {
            x: chunk.x,
            z: chunk.z,
            image: binary.into(),
            heights: (0..256)
                .map(|c| chunk.height(Heightmap::MotionBlockingNoLeaves, c & 15, c >> 4))
                .collect(),
            block_entities,
            block_ticks: chunk
                .block_ticks
                .iter()
                .filter(|(p, block)| table.block_of(at(p)) == *block)
                .map(|(p, _)| (t(p), at(p)))
                .collect(),
            fluid_ticks: chunk
                .fluid_ticks
                .iter()
                .map(|(p, f)| (t(p), FLUID_NAMES[*f as usize].to_string()))
                .collect(),
            marks: chunk.marks.iter().map(t).collect(),
        });
    }
    Ok(out)
}

/// `/locate structure` (VMC-053o): the nearest start of `structures` (in
/// holder set order) from block `pos`, as its locate position and structure,
/// searching random spread sets up to `radius` grid rings. It can take
/// seconds, as vanilla's search does.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_structure_locate(
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    structures: Vec<String>,
    pos: (i32, i32, i32),
    radius: i32,
) -> Result<Option<(i32, i32, i32, String)>, String> {
    let env = {
        let mut state = state.lease()?;
        state.structure_env(&biome_source)?
    };
    let registry = &env.registry;
    let wanted = structures
        .iter()
        .map(|id| {
            registry
                .structures
                .iter()
                .position(|s| &s.id == id)
                .ok_or_else(|| format!("unknown structure {id}"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(env
        .find_nearest_structure(&wanted, pos, radius)?
        .map(|((x, y, z), s)| (x, y, z, registry.structures[s].id.clone())))
}

/// `/place` (VMC-053): a placement as `(kind, names, max depth, integrity,
/// strict)`: `feature` [id], `template` [id, rotation, mirror], `structure`
/// [id], `jigsaw` [pool, target].
type PlaceSpec = (String, Vec<String>, i32, f64, bool);

fn place_spec(spec: &PlaceSpec) -> Result<valimc_core::worldgen::compiler::Placement, String> {
    use valimc_core::worldgen::compiler::Placement;
    use valimc_core::worldgen::template::{Mirror, Rotation};
    let (kind, names, max_depth, integrity, strict) = spec;
    let name = |i: usize| -> Result<String, String> {
        names
            .get(i)
            .cloned()
            .ok_or_else(|| format!("{kind} needs {} names", i + 1))
    };
    Ok(match kind.as_str() {
        "feature" => Placement::Feature(name(0)?),
        "structure" => Placement::Structure(name(0)?),
        "jigsaw" => Placement::Jigsaw {
            pool: name(0)?,
            target: name(1)?,
            max_depth: *max_depth,
        },
        "template" => Placement::Template {
            id: name(0)?,
            rotation: match name(1)?.as_str() {
                "none" => Rotation::None,
                "clockwise_90" => Rotation::Clockwise90,
                "180" => Rotation::Clockwise180,
                "counterclockwise_90" => Rotation::Counterclockwise90,
                other => return Err(format!("unknown rotation {other}")),
            },
            mirror: match name(2)?.as_str() {
                "none" => Mirror::None,
                "left_right" => Mirror::LeftRight,
                "front_back" => Mirror::FrontBack,
                other => return Err(format!("unknown mirror {other}")),
            },
            integrity: *integrity as f32,
            strict: *strict,
        },
        other => Err(format!("unknown placement {other}"))?,
    })
}

type ChunkRange = ((i32, i32), (i32, i32));

/// `/place`'s plan (VMC-053): `chunks` with the chunks vanilla checks are
/// loaded and every chunk the placement uses, or `invalid` (no such
/// template) or `failed` (no valid start, no jigsaw pieces).
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_place_plan(
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    spec: PlaceSpec,
    pos: (i32, i32, i32),
) -> Result<(String, ChunkRange, ChunkRange), String> {
    use valimc_core::worldgen::compiler::Plan;
    let placement = place_spec(&spec)?;
    let mut state = state.lease()?;
    let none = ((0, 0), (0, 0));
    Ok(
        match state.place_plan(&biome_source, &placement, [pos.0, pos.1, pos.2])? {
            Plan::Chunks { checked, area } => ("chunks".into(), checked, area),
            Plan::Invalid => ("invalid".into(), none, none),
            Plan::Failed => ("failed".into(), none, none),
        },
    )
}

/// A `/place` result: changed blocks, block entities to write, and the
/// entities placement would have added.
type PlacedResult = (Vec<((i32, i32, i32), u16)>, Vec<FullBlockEntity>, usize);

/// `/place` (VMC-053) over the plan's chunks (`x`, `z`, column image or nil
/// for the flat `base` profile) with the level random `seed`; nil when the
/// placement placed nothing.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_place(
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    spec: PlaceSpec,
    pos: (i32, i32, i32),
    chunks: Vec<(i32, i32, Option<Binary>)>,
    base: Vec<u16>,
    seed: i64,
) -> Result<Option<PlacedResult>, String> {
    let placement = place_spec(&spec)?;
    let mut state = state.lease()?;
    let mut protos = Vec::with_capacity(chunks.len());
    for (x, z, image) in &chunks {
        protos.push(state.place_chunk(
            &biome_source,
            (*x, *z),
            image.as_ref().map(|b| b.as_slice()),
            &base,
        )?);
    }
    let Some(placed) = state.place(
        &biome_source,
        &placement,
        [pos.0, pos.1, pos.2],
        protos,
        seed,
    )?
    else {
        return Ok(None);
    };
    let t = |p: [i32; 3]| (p[0], p[1], p[2]);
    let block_entities = placed
        .block_entities
        .into_iter()
        .map(|(p, state, data)| FullBlockEntity {
            position: t(p),
            state,
            kind: data.as_ref().map(|d| d.kind.to_string()),
            loot_table: data.as_ref().and_then(|d| d.loot_table.clone()),
            loot_seed: data.as_ref().map_or(0, |d| d.loot_seed),
            spawner_entity: data.as_ref().and_then(|d| d.spawner_entity.clone()),
            bees: data.as_ref().map_or_else(Vec::new, |d| d.bees.clone()),
            exit: data
                .as_ref()
                .and_then(|d| d.exit.map(|(e, exact)| ((e[0], e[1], e[2]), exact))),
            nbt: data
                .as_ref()
                .and_then(|d| d.nbt.as_deref().map(str::to_string)),
        })
        .collect();
    Ok(Some((
        placed.blocks.into_iter().map(|(p, s)| (t(p), s)).collect(),
        block_entities,
        placed.entities,
    )))
}
