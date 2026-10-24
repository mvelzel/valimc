//! World generation for the live server. Every call but `worldgen_new` is a
//! `DirtyCpu` NIF that live callers make from `Valimc.Worldgen.Pool`.

use crate::{bytes, raise, reply};
use rustler::{Atom, Binary, Encoder, Env, NifResult, ResourceArc, Term};
use std::sync::Mutex;
use valimc_core::worldgen::compiler::BiomeSource;
use valimc_core::worldgen::region::{Area, ProtoChunk};
use valimc_core::worldgen::starts::StartTable;

mod atoms {
    rustler::atoms! { chunks, invalid, failed, too_large }
}

/// Worldgen registries parsed from the generated facts.
pub struct WorldgenRegistry {
    pub(crate) registry: std::sync::Arc<valimc_core::worldgen::compiler::Registry>,
}

#[rustler::resource_impl]
impl rustler::Resource for WorldgenRegistry {}

/// One seed's generation context (`SeedContext`, VMC-077n): compiled once
/// and shared through an `Arc` by every call, which takes a `Worldgen`
/// handle of its own. Nothing in it is mutable but bounded caches of pure
/// values, so any number of calls run at once and get the same chunks.
pub struct WorldgenState {
    pub(crate) ctx: std::sync::Arc<valimc_core::worldgen::compiler::SeedContext>,
}

#[rustler::resource_impl]
impl rustler::Resource for WorldgenState {}

impl WorldgenState {
    /// A call's handle on the context.
    pub(crate) fn lease(&self) -> Result<valimc_core::worldgen::compiler::Worldgen, String> {
        Ok(valimc_core::worldgen::compiler::Worldgen::of(&self.ctx))
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
/// contents, with block states as global state ids. Facts ValiMC cannot
/// generate (a data pack's) raise with the reason.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_registry(facts: Term) -> NifResult<(Atom, ResourceArc<WorldgenRegistry>)> {
    reply((|| {
        let json = json_of(facts)?;
        let facts = valimc_core::worldgen::compiler::Facts::from_object(&json)?;
        let states = crate::facts::STATES
            .get()
            .ok_or("block facts not installed")?;
        let registry = valimc_core::worldgen::compiler::Registry::parse(&facts, states)?;
        Ok(ResourceArc::new(WorldgenRegistry {
            registry: std::sync::Arc::new(registry),
        }))
    })())
}

/// The generation context of a seed and noise settings, compiled now (every
/// function of the noise router and aquifers, the material system), on a
/// dirty scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_new(
    registry: ResourceArc<WorldgenRegistry>,
    seed: i64,
    settings: String,
) -> NifResult<(Atom, ResourceArc<WorldgenState>)> {
    let ctx = valimc_core::worldgen::compiler::SeedContext::compile(
        registry.registry.clone(),
        seed,
        &settings,
    )
    .map_err(raise)?;
    reply(Ok(ResourceArc::new(WorldgenState { ctx })))
}

/// Approximate bytes a generation context holds beyond its registry
/// (compiled functions, noises and its bounded caches).
#[rustler::nif]
fn worldgen_memory(state: ResourceArc<WorldgenState>) -> usize {
    state.ctx.heap_bytes()
}

/// A generated chunk: its column image and per column its highest non-air
/// block (`z * 16 + x`).
type GeneratedColumn<'a> = (i32, i32, Binary<'a>, Vec<i32>);

/// The fight reads the same ten spike descriptions as terrain decoration.
/// Fixed-size seed shuffle; no world state or resource is accessed.
type EndSpike = (i32, i32, i32, i32, bool);

#[rustler::nif]
fn worldgen_end_spikes(seed: i64) -> (Atom, Vec<EndSpike>) {
    (
        crate::atoms::ok(),
        valimc_core::worldgen::end::spikes_for_seed(seed)
            .into_iter()
            .map(|s| (s.x, s.z, s.radius, s.height, s.guarded))
            .collect(),
    )
}

/// Ten immutable pillar blueprints, packed as signed XYZ32 + state16.
/// Fixed ten spikes, each below 16K writes; no world resource is mutated.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_end_pillars<'a>(
    env: Env<'a>,
    state: ResourceArc<WorldgenState>,
    seed: i64,
) -> NifResult<(Atom, Vec<Binary<'a>>)> {
    reply((|| {
        let d = state.lease()?.decoration(&BiomeSource::End)?;
        valimc_core::worldgen::end::spikes_for_seed(seed)
            .into_iter()
            .map(|spike| {
                let writes = valimc_core::worldgen::end::pillar_plan(&d, spike)?;
                let mut packed = Vec::with_capacity(writes.len() * 14);
                for (p, block) in writes {
                    for v in p {
                        packed.extend_from_slice(&v.to_be_bytes());
                    }
                    packed.extend_from_slice(&block.to_be_bytes());
                }
                Ok(bytes(env, packed))
            })
            .collect()
    })())
}

/// The shared spawn's origin column (`Worldgen::spawn_origin`, VMC-027d), or
/// nil without a spawn target.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_spawn_origin(
    state: ResourceArc<WorldgenState>,
) -> NifResult<(Atom, Option<(i32, i32)>)> {
    reply(state.lease().and_then(|mut state| state.spawn_origin()))
}

/// Generated chunks as region-log column images (`Worldgen::generate_column`),
/// biomes as protocol ids (`protocol_biomes`, by biome registry id).
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_columns<'a>(
    env: Env<'a>,
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    protocol_biomes: Vec<u16>,
    chunks: Vec<(i32, i32)>,
) -> NifResult<(Atom, Vec<GeneratedColumn<'a>>)> {
    reply((|| {
        let mut state = state.lease()?;
        let biome_source = BiomeSource::parse(&biome_source, state.registry())?;
        let mut out = Vec::with_capacity(chunks.len());
        for (x, z) in chunks {
            let (column, heights) = state.generate_column(x, z, &biome_source, &protocol_biomes)?;
            out.push((x, z, bytes(env, column.to_image()), heights.to_vec()));
        }
        Ok(out)
    })())
}

/// A chunk's proto state (VMC-077n): the generation scheduler owns it and
/// lends it to one job at a time, which locks it for its call. Empty only
/// while a decoration holds it.
pub struct ProtoCell {
    pub(crate) chunk: Mutex<Option<ProtoChunk>>,
}

#[rustler::resource_impl]
impl rustler::Resource for ProtoCell {}

impl ProtoCell {
    fn new(chunk: ProtoChunk) -> ResourceArc<ProtoCell> {
        ResourceArc::new(ProtoCell {
            chunk: Mutex::new(Some(chunk)),
        })
    }
}

/// A dimension's structure starts (`valimc_core::worldgen::starts`): the
/// generation scheduler's, passed into its terrain and decoration jobs.
pub struct Starts {
    table: StartTable,
}

#[rustler::resource_impl]
impl rustler::Resource for Starts {}

/// A new, empty start table.
#[rustler::nif]
fn gen_starts_new() -> ResourceArc<Starts> {
    ResourceArc::new(Starts {
        table: StartTable::new(),
    })
}

/// Chunks with starts left to place, those starts, and the table's
/// approximate bytes.
#[rustler::nif]
fn gen_starts_stats(starts: ResourceArc<Starts>) -> (usize, usize, usize) {
    let (chunks, live) = starts.table.len();
    (chunks, live, starts.table.heap_bytes())
}

/// The starts left to place, for a snapshot.
#[rustler::nif(schedule = "DirtyCpu")]
fn gen_starts_snapshot<'a>(
    env: Env<'a>,
    starts: ResourceArc<Starts>,
) -> NifResult<(Atom, Binary<'a>)> {
    reply(starts.table.encode().map(|b| bytes(env, b)))
}

/// A start table from a snapshot.
#[rustler::nif(schedule = "DirtyCpu")]
fn gen_starts_restore(snapshot: Binary) -> NifResult<(Atom, ResourceArc<Starts>)> {
    reply(StartTable::decode(snapshot.as_slice()).map(|table| ResourceArc::new(Starts { table })))
}

/// A chunk at status `terrain` (VMC-077n): its proto chunk, with `starts`
/// the beards of the starts that reach it.
#[rustler::nif(schedule = "DirtyCpu")]
fn gen_terrain(
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    starts: Option<ResourceArc<Starts>>,
    x: i32,
    z: i32,
) -> NifResult<(Atom, ResourceArc<ProtoCell>)> {
    reply((|| {
        let mut state = state.lease()?;
        let biome_source = BiomeSource::parse(&biome_source, state.registry())?;
        let table = starts.as_ref().map(|s| &s.table);
        let chunk = state.generation_terrain(x, z, &biome_source, table)?;
        Ok(ProtoCell::new(chunk))
    })())
}

/// Decorate chunk `center` (VMC-077n) over `cells`, its 3 × 3, lent to this
/// call: with `starts`, the pieces of the starts that reach it first in each
/// step. Returns the count of reads beyond the 3 × 3 (which see empty chunks).
#[rustler::nif(schedule = "DirtyCpu")]
fn gen_decorate(
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    starts: Option<ResourceArc<Starts>>,
    center: (i32, i32),
    cells: Vec<ResourceArc<ProtoCell>>,
) -> NifResult<(Atom, u32)> {
    reply((|| {
        let mut state = state.lease()?;
        let biome_source = BiomeSource::parse(&biome_source, state.registry())?;
        let mut guards = Vec::with_capacity(cells.len());
        for cell in &cells {
            guards.push(cell.chunk.lock().map_err(|_| "proto cell poisoned")?);
        }
        let mut chunks = Vec::with_capacity(guards.len());
        for guard in &mut guards {
            chunks.push(guard.take().ok_or("a proto cell lent twice")?);
        }
        let positions: Vec<(i32, i32)> = chunks.iter().map(|c| (c.x, c.z)).collect();
        let mut area = Area::of(chunks)?;
        let table = starts.as_ref().map(|s| &s.table);
        let result = state.generation_decorate(&biome_source, &mut area, center, table);
        // The chunks go back to their cells whatever the decoration did.
        for (guard, (x, z)) in guards.iter_mut().zip(positions) {
            let slot = (z - area.z) * area.size + (x - area.x);
            **guard = area.chunks[slot as usize].take();
        }
        result
    })())
}

/// Approximate heap bytes of the proto chunks in `cells` (VMC-077q); a cell
/// lent to a job counts nothing.
#[rustler::nif]
fn gen_cells_bytes(cells: Vec<ResourceArc<ProtoCell>>) -> NifResult<(Atom, usize)> {
    reply((|| {
        let mut total = 0;
        for cell in &cells {
            let chunk = cell.chunk.lock().map_err(|_| "proto cell poisoned")?;
            total += chunk.as_ref().map_or(0, |c| c.heap_bytes());
        }
        Ok(total)
    })())
}

/// A proto chunk as `proto::encode` writes it (snapshots, parity).
#[rustler::nif(schedule = "DirtyCpu")]
fn gen_encode<'a>(env: Env<'a>, cell: ResourceArc<ProtoCell>) -> NifResult<(Atom, Binary<'a>)> {
    reply((|| {
        let chunk = cell.chunk.lock().map_err(|_| "proto cell poisoned")?;
        let chunk = chunk.as_ref().ok_or("a proto cell lent out")?;
        Ok(bytes(env, valimc_core::worldgen::proto::encode(chunk)))
    })())
}

/// A proto cell from `gen_encode` output.
#[rustler::nif(schedule = "DirtyCpu")]
fn gen_decode(
    state: ResourceArc<WorldgenState>,
    encoded: Binary,
) -> NifResult<(Atom, ResourceArc<ProtoCell>)> {
    reply((|| {
        let state = state.lease()?;
        let chunk = valimc_core::worldgen::proto::decode(encoded.as_slice(), state.block_table()?)?;
        Ok(ProtoCell::new(chunk))
    })())
}

/// What live generation makes of `order` decorated one after the other over
/// the `size` × `size` chunks from `origin` (VMC-077n), in one call, with
/// structures when `structures`: the reference the scheduler's chunks equal.
/// Every chunk of the area as a cell, Z outer and X inner.
#[rustler::nif(schedule = "DirtyCpu")]
fn gen_reference(
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    origin: (i32, i32),
    size: i32,
    order: Vec<(i32, i32)>,
    structures: bool,
) -> NifResult<(Atom, Vec<ResourceArc<ProtoCell>>)> {
    reply((|| {
        if !(1..=64).contains(&size) {
            return Err("an area of 1 to 64 chunks".to_string());
        }
        let mut state = state.lease()?;
        let biome_source = BiomeSource::parse(&biome_source, state.registry())?;
        let area = state.reference_area(&biome_source, origin, size, &order, structures)?;
        Ok(area
            .chunks
            .into_iter()
            .flatten()
            .map(ProtoCell::new)
            .collect())
    })())
}

/// A block entity of a full chunk: created (with what decoration wrote into
/// it) or pending (`kind` nil: the block's default block entity).
#[derive(rustler::NifMap)]
pub(crate) struct FullBlockEntity {
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

/// An entity generation added (VMC-042b): its type, position, yaw (nil when
/// vanilla's is random), what else generation gave it as SNBT, whether it is
/// persistent and whether it rides the entity before it.
#[derive(rustler::NifMap)]
pub(crate) struct FullEntity {
    kind: String,
    position: (f64, f64, f64),
    yaw: Option<f32>,
    nbt: Option<String>,
    persistent: bool,
    rides: bool,
}

impl From<&valimc_core::worldgen::region::Entity> for FullEntity {
    fn from(e: &valimc_core::worldgen::region::Entity) -> Self {
        FullEntity {
            kind: e.kind.to_string(),
            position: (e.pos[0], e.pos[1], e.pos[2]),
            yaw: (!e.yaw.is_nan()).then_some(e.yaw),
            nbt: e.nbt.as_deref().map(str::to_string),
            persistent: e.persistent,
            rides: e.rides,
        }
    }
}

/// A decorated chunk made full (VMC-025d): its column image (protocol biome
/// ids), first free Y above the highest motion-blocking non-leaf block per
/// column (z * 16 + x), block entities, block ticks (position and the state
/// there, kept only where the block still matches), fluid ticks,
/// post-processing marks and entities.
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
    entities: Vec<FullEntity>,
    /// The starts natural spawning reads (VMC-042b): `{structure, box,
    /// pieces}`, boxes as six ints.
    structures: Vec<crate::spawn::Kept>,
}

/// A final chunk made full (VMC-077n), from its proto cell.
#[rustler::nif(schedule = "DirtyCpu")]
fn gen_full<'a>(
    env: Env<'a>,
    state: ResourceArc<WorldgenState>,
    cell: ResourceArc<ProtoCell>,
    protocol_biomes: Vec<u16>,
) -> NifResult<(Atom, FullChunk<'a>)> {
    reply((|| {
        let chunk = cell.chunk.lock().map_err(|_| "proto cell poisoned")?;
        let chunk = chunk.as_ref().ok_or("a proto cell lent out")?;
        full_chunk(env, &state, chunk, &protocol_biomes)
    })())
}

fn full_chunk<'a>(
    env: Env<'a>,
    state: &WorldgenState,
    chunk: &ProtoChunk,
    protocol_biomes: &[u16],
) -> Result<FullChunk<'a>, String> {
    use valimc_core::worldgen::blocks::{Heightmap, BLOCK_ENTITY, FLUID_NAMES};
    let state = state.lease()?;
    let table = state.block_table()?;
    {
        let (column, _) = state.final_column(chunk, protocol_biomes)?;
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
        Ok(FullChunk {
            x: chunk.x,
            z: chunk.z,
            image: bytes(env, column.to_image()),
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
            entities: chunk.entities.iter().map(FullEntity::from).collect(),
            structures: chunk
                .structures
                .iter()
                .map(|s| {
                    (
                        s.structure.to_string(),
                        s.bbox.to_vec(),
                        s.pieces.iter().map(|p| p.to_vec()).collect(),
                    )
                })
                .collect(),
        })
    }
}

/// A located structure: its locate position and identifier.
type Located = (i32, i32, i32, String);

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
) -> NifResult<(Atom, Option<Located>)> {
    reply(locate(&state, &biome_source, &structures, pos, radius))
}

fn locate(
    state: &WorldgenState,
    biome_source: &str,
    structures: &[String],
    pos: (i32, i32, i32),
    radius: i32,
) -> Result<Option<Located>, String> {
    let env = {
        let mut state = state.lease()?;
        let biome_source = BiomeSource::parse(biome_source, state.registry())?;
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

/// What a placement wrote into block entities, as full chunks carry them.
fn full_block_entities(
    entities: Vec<(
        [i32; 3],
        u16,
        Option<valimc_core::worldgen::region::BlockEntityData>,
    )>,
) -> Vec<FullBlockEntity> {
    entities
        .into_iter()
        .map(|(p, state, data)| FullBlockEntity {
            position: (p[0], p[1], p[2]),
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
        .collect()
}

/// A tree grown from a sapling (VMC-039a): changed blocks with their states
/// before and after, and block entities to write.
type GrownResult = (Vec<((i32, i32, i32), u16, u16)>, Vec<FullBlockEntity>);

/// What the generator grows at `pos` (`Growth::generated`): the tree of a
/// sapling there (`TreeGrower.growTree`, VMC-039a), its grower from the
/// block rules' growth facts, or what bone meal places on a grass block,
/// nylium, moss or a mushroom (VMC-039b), over the chunks of its plan (as
/// `/place feature`'s: the 3 × 3 around it; column images, or nil for the
/// flat `base` profile) with the level random `seed`; nil when nothing grew
/// (no such block there, or the tree did not fit).
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn worldgen_grow(
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    rules: ResourceArc<crate::rules::BlockRules>,
    pos: (i32, i32, i32),
    chunks: Vec<(i32, i32, Option<Binary>)>,
    base: Vec<u16>,
    seed: i64,
) -> NifResult<(Atom, Option<GrownResult>)> {
    reply((|| {
        let mut state = state.lease()?;
        let biome_source = BiomeSource::parse(&biome_source, state.registry())?;
        let mut protos = Vec::with_capacity(chunks.len());
        for (x, z, image) in &chunks {
            protos.push(state.place_chunk(
                &biome_source,
                (*x, *z),
                image.as_ref().map(|b| b.as_slice()),
                &base,
            )?);
        }
        let pos = [pos.0, pos.1, pos.2];
        let grows = protos
            .iter()
            .find(|c| (c.x, c.z) == (pos[0] >> 4, pos[2] >> 4))
            .and_then(|c| c.get(pos[0], pos[1], pos[2]));
        let growth = rules.rules.growth.as_ref().ok_or("no growth facts")?;
        let Some(generated) = grows.and_then(|s| growth.generated(&rules.rules.table, s)) else {
            return Ok(None);
        };
        let (placement, at) = valimc_core::worldgen::compiler::Placement::grown(generated, pos);
        let Some(placed) = state.place(&biome_source, &placement, at, protos, seed)? else {
            return Ok(None);
        };
        let blocks = placed
            .blocks
            .iter()
            .zip(&placed.replaced)
            .map(|(&(p, new), &old)| ((p[0], p[1], p[2]), old, new))
            .collect();
        Ok(Some((blocks, full_block_entities(placed.block_entities))))
    })())
}

/// `/place`'s plan (VMC-053): `{:chunks, checked, area}` with the chunks
/// vanilla checks are loaded and every chunk the placement uses, or `:invalid`
/// (no such template), `:failed` (no valid start, no jigsaw pieces) or
/// `:too_large` (more chunks than ValiMC places at once).
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_place_plan<'a>(
    env: Env<'a>,
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    spec: PlaceSpec,
    pos: (i32, i32, i32),
) -> NifResult<(Atom, Term<'a>)> {
    use valimc_core::worldgen::compiler::Plan;
    reply((|| {
        let placement = place_spec(&spec)?;
        let mut state = state.lease()?;
        let biome_source = BiomeSource::parse(&biome_source, state.registry())?;
        Ok(
            match state.place_plan(&biome_source, &placement, [pos.0, pos.1, pos.2])? {
                Plan::Chunks { checked, area } => (atoms::chunks(), checked, area).encode(env),
                Plan::Invalid => atoms::invalid().encode(env),
                Plan::Failed => atoms::failed().encode(env),
                Plan::TooLarge => atoms::too_large().encode(env),
            },
        )
    })())
}

/// A `/place` result: changed blocks, block entities to write, and the
/// entities placement added.
type PlacedResult = (
    Vec<((i32, i32, i32), u16)>,
    Vec<FullBlockEntity>,
    Vec<FullEntity>,
);

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
) -> NifResult<(Atom, Option<PlacedResult>)> {
    reply(place(
        &state,
        &biome_source,
        &spec,
        pos,
        &chunks,
        &base,
        seed,
    ))
}

fn place(
    state: &WorldgenState,
    biome_source: &str,
    spec: &PlaceSpec,
    pos: (i32, i32, i32),
    chunks: &[(i32, i32, Option<Binary>)],
    base: &[u16],
    seed: i64,
) -> Result<Option<PlacedResult>, String> {
    let placement = place_spec(spec)?;
    let mut state = state.lease()?;
    let biome_source = BiomeSource::parse(biome_source, state.registry())?;
    let mut protos = Vec::with_capacity(chunks.len());
    for (x, z, image) in chunks {
        protos.push(state.place_chunk(
            &biome_source,
            (*x, *z),
            image.as_ref().map(|b| b.as_slice()),
            base,
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
    let block_entities = full_block_entities(placed.block_entities);
    Ok(Some((
        placed.blocks.into_iter().map(|(p, s)| (t(p), s)).collect(),
        block_entities,
        placed.entities.iter().map(FullEntity::from).collect(),
    )))
}
