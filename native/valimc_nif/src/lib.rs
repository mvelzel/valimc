//! Rustler shim: each region owner holds one `Region` resource; calls are short
//! (batched) and run on normal schedulers. Inputs are validated by valimc_core.

use rustler::{Atom, Binary, Encoder, Env, NewBinary, ResourceArc, Term};
use std::sync::{Mutex, OnceLock};
use valimc_core::column::HEIGHT;
use valimc_core::{nbt, BlockFlags, ColumnStore, Storage, StoreError};

mod atoms {
    rustler::atoms! {
        ok,
        out_of_region,
        invalid_y,
        invalid_state,
        memory_budget,
        flags_missing,
        flags_mismatch,
        invalid_layers,
        poisoned,
        flat,
        dense,
    }
}

static FLAGS: OnceLock<BlockFlags> = OnceLock::new();

pub struct Region {
    store: Mutex<ColumnStore>,
}

#[rustler::resource_impl]
impl rustler::Resource for Region {}

fn error(e: StoreError) -> Atom {
    match e {
        StoreError::OutOfRegion => atoms::out_of_region(),
        StoreError::InvalidY => atoms::invalid_y(),
        StoreError::InvalidState => atoms::invalid_state(),
        StoreError::MemoryBudget => atoms::memory_budget(),
    }
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut out = NewBinary::new(env, bytes.len());
    out.as_mut_slice().copy_from_slice(bytes);
    Binary::from(out).encode(env)
}

/// Install the per-state flag bytes once per VM (idempotent for identical bytes).
#[rustler::nif]
fn flags_init(bytes: Binary) -> Result<Atom, Atom> {
    let flags = BlockFlags::new(bytes.as_slice().to_vec()).ok_or(atoms::invalid_state())?;
    let installed = FLAGS.get_or_init(|| flags.clone());
    if installed.state_count() == flags.state_count()
        && (0..flags.state_count()).all(|s| installed.get(s as u16) == flags.get(s as u16))
    {
        Ok(atoms::ok())
    } else {
        Err(atoms::flags_mismatch())
    }
}

/// `layers` is 384 big-endian u16 states, bottom (y = -64) first.
#[rustler::nif]
fn region_new(
    cx: i32,
    cz: i32,
    size: i32,
    layers: Binary,
    budget: usize,
) -> Result<ResourceArc<Region>, Atom> {
    let bytes = layers.as_slice();
    if bytes.len() != HEIGHT * 2 || size <= 0 || size > 64 {
        return Err(atoms::invalid_layers());
    }
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    let mut base = Box::new([0u16; HEIGHT]);
    for (i, pair) in bytes.chunks_exact(2).enumerate() {
        let state = u16::from_be_bytes([pair[0], pair[1]]);
        if !flags.valid(state as u32) {
            return Err(atoms::invalid_layers());
        }
        base[i] = state;
    }
    let store = ColumnStore::new((cx, cz), size, base, budget);
    Ok(ResourceArc::new(Region {
        store: Mutex::new(store),
    }))
}

fn with_store<T>(
    region: &Region,
    f: impl FnOnce(&mut ColumnStore) -> Result<T, Atom>,
) -> Result<T, Atom> {
    let mut guard = region.store.lock().map_err(|_| atoms::poisoned())?;
    f(&mut guard)
}

#[rustler::nif]
fn get_blocks(
    region: ResourceArc<Region>,
    positions: Vec<(i32, i32, i32)>,
) -> Result<Vec<u16>, Atom> {
    with_store(&region, |store| {
        positions
            .iter()
            .map(|(x, y, z)| store.get(*x, *y, *z).map_err(error))
            .collect()
    })
}

/// Apply all changes or none; returns the previous states in input order.
#[rustler::nif]
fn set_blocks(
    region: ResourceArc<Region>,
    changes: Vec<(i32, i32, i32, u32)>,
) -> Result<Vec<u16>, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    with_store(&region, |store| {
        store.set_many(&changes, flags).map_err(error)
    })
}

/// `{sections, world_surface_longs, motion_blocking_longs}` for one chunk.
#[rustler::nif]
fn encode_chunk<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
    biome: u32,
    global_bits: u32,
    biome_bits: u32,
) -> Result<Term<'a>, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    if !(1..=16).contains(&global_bits) || !(1..=16).contains(&biome_bits) {
        return Err(atoms::invalid_state());
    }
    let encoded = with_store(&region, |store| {
        if !store.touched((cx, cz)) {
            // Callers keep a cached packet for the unmodified base profile.
            store.check_chunk((cx, cz)).map_err(error)?;
            return Ok(None);
        }
        store
            .encode_chunk((cx, cz), flags, biome, global_bits, biome_bits)
            .map(Some)
            .map_err(error)
    })?;
    Ok(match encoded {
        None => atoms::flat().encode(env),
        Some((sections, surface, motion)) => (
            binary(env, &sections),
            binary(env, &surface),
            binary(env, &motion),
        )
            .encode(env),
    })
}

#[rustler::nif]
fn diff(region: ResourceArc<Region>) -> Result<Vec<(i32, i32, i32, u16)>, Atom> {
    with_store(&region, |store| Ok(store.diff()))
}

/// Positions in one chunk holding any of `states` (block-entity carriers).
#[rustler::nif]
fn chunk_find(
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
    states: Vec<u16>,
) -> Result<Vec<(i32, i32, i32, u16)>, Atom> {
    with_store(&region, |store| {
        store.find((cx, cz), &states).map_err(error)
    })
}

/// Chunks whose columns differ from (or once differed from) the base profile.
#[rustler::nif]
fn touched_chunks(region: ResourceArc<Region>) -> Result<Vec<(i32, i32)>, Atom> {
    with_store(&region, |store| Ok(store.columns.keys().copied().collect()))
}

/// An immutable read snapshot of one chunk: 24 section terms, bottom first. A
/// section is a state integer (uniform), `{palette_tuple, cells}` with one byte
/// per cell, or `{:dense, cells}` with a big-endian u16 per cell. `nil` for an
/// untouched chunk (readers use the base profile).
#[rustler::nif]
fn snapshot_chunk<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
) -> Result<Term<'a>, Atom> {
    with_store(&region, |store| {
        store.check_chunk((cx, cz)).map_err(error)?;
        let Some(column) = store.columns.get(&(cx, cz)) else {
            return Ok(rustler::types::atom::nil().encode(env));
        };
        let sections: Vec<Term<'a>> = column
            .sections
            .iter()
            .map(|section| match section {
                Storage::Single(state) => state.encode(env),
                Storage::Indexed { palette, cells } => {
                    let palette: Vec<Term<'a>> = palette.iter().map(|p| p.encode(env)).collect();
                    (
                        rustler::types::tuple::make_tuple(env, &palette),
                        binary(env, &cells[..]),
                    )
                        .encode(env)
                }
                Storage::Dense(cells) => {
                    let bytes: Vec<u8> = cells.iter().flat_map(|c| c.to_be_bytes()).collect();
                    (atoms::dense(), binary(env, &bytes)).encode(env)
                }
            })
            .collect();
        Ok(sections.encode(env))
    })
}

/// fsync a directory so a completed rename survives power loss (Erlang's `:file`
/// cannot open directories). Runs on a dirty I/O scheduler.
#[rustler::nif(schedule = "DirtyIo")]
fn fsync_dir(path: String) -> Result<Atom, String> {
    let dir = std::fs::File::open(&path).map_err(|e| e.to_string())?;
    dir.sync_all().map_err(|e| e.to_string())?;
    Ok(atoms::ok())
}

/// Flush a file through the drive's write cache. On Apple platforms `fsync`
/// stops at the cache and `File::sync_all` issues `F_FULLFSYNC`; any descriptor of
/// the file will do. Runs on a dirty I/O scheduler.
#[rustler::nif(schedule = "DirtyIo")]
fn full_sync(path: String) -> Result<Atom, String> {
    let file = std::fs::File::open(&path).map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    Ok(atoms::ok())
}

/// Install the region's randomly ticking states: one bit per state id (LSB first).
#[rustler::nif]
fn set_random_ticking(region: ResourceArc<Region>, bitmap: Binary) -> Result<Atom, Atom> {
    let bytes = bitmap.as_slice();
    with_store(&region, |store| {
        store.ticking = (0..bytes.len() * 8)
            .map(|i| bytes[i / 8] & (1 << (i % 8)) != 0)
            .collect();
        Ok(atoms::ok())
    })
}

/// One tick's random tick hits: `{x, y, z, state}` for sampled ticking states.
#[rustler::nif]
fn random_ticks(
    region: ResourceArc<Region>,
    per_section: u32,
) -> Result<Vec<(i32, i32, i32, u16)>, Atom> {
    if per_section > 4096 {
        return Err(atoms::invalid_state());
    }
    with_store(&region, |store| Ok(store.random_ticks(per_section)))
}

#[rustler::nif]
fn compact(region: ResourceArc<Region>) -> Result<Atom, Atom> {
    with_store(&region, |store| {
        store.compact();
        Ok(atoms::ok())
    })
}

#[rustler::nif]
fn heap_bytes(region: ResourceArc<Region>) -> Result<usize, Atom> {
    with_store(&region, |store| Ok(store.heap_bytes()))
}

// ---- Disk NBT (VMC-020) ----

mod nbt_atoms {
    rustler::atoms! {
        end_ = "end", byte, short, int, long, float, double, byte_array, string, list, compound,
        int_array, long_array,
        nbt_byte_limit, nbt_node_limit, nbt_depth_limit, truncated_nbt, unknown_nbt_tag,
        invalid_nbt_list, invalid_nbt_array_length, invalid_nbt_utf, nbt_root_not_compound,
        trailing_nbt_bytes,
    }
}

fn nbt_type(id: u8) -> Atom {
    use nbt_atoms::*;
    match id {
        1 => byte(),
        2 => short(),
        3 => int(),
        4 => long(),
        5 => float(),
        6 => double(),
        7 => byte_array(),
        8 => string(),
        9 => list(),
        10 => compound(),
        11 => int_array(),
        12 => long_array(),
        _ => end_(),
    }
}

fn nbt_error(e: nbt::NbtError) -> Atom {
    use nbt::NbtError::*;
    use nbt_atoms::*;
    match e {
        ByteLimit => nbt_byte_limit(),
        NodeLimit => nbt_node_limit(),
        DepthLimit => nbt_depth_limit(),
        Truncated => truncated_nbt(),
        UnknownTag => unknown_nbt_tag(),
        InvalidList => invalid_nbt_list(),
        InvalidArrayLength => invalid_nbt_array_length(),
        InvalidUtf => invalid_nbt_utf(),
        RootNotCompound => nbt_root_not_compound(),
        Trailing => trailing_nbt_bytes(),
    }
}

/// Builds `Valimc.NBT` terms; raw values and UTF-8 strings are sub-binaries of the input.
struct Terms<'a> {
    env: Env<'a>,
    input: Binary<'a>,
}

impl<'a> nbt::Visitor for Terms<'a> {
    type Value = Term<'a>;
    fn int(&mut self, value: i64) -> Term<'a> {
        value.encode(self.env)
    }
    fn raw(&mut self, start: usize, len: usize) -> Term<'a> {
        self.input
            .make_subbinary(start, len)
            .expect("range within input")
            .encode(self.env)
    }
    fn string(&mut self, text: nbt::Text) -> Term<'a> {
        match text {
            nbt::Text::Slice(start, len) => self.raw(start, len),
            nbt::Text::Owned(s) => binary(self.env, s.as_bytes()),
        }
    }
    fn list(&mut self, element: u8, items: Vec<Term<'a>>) -> Term<'a> {
        (nbt_type(element), items).encode(self.env)
    }
    fn compound(&mut self, entries: Vec<(Term<'a>, u8, Term<'a>)>) -> Term<'a> {
        let (keys, values): (Vec<Term<'a>>, Vec<Term<'a>>) = entries
            .into_iter()
            .map(|(name, id, value)| (name, (nbt_type(id), value).encode(self.env)))
            .unzip();
        // A repeated name keeps its last value, as vanilla's CompoundTag does.
        Term::map_from_arrays(self.env, &keys, &values).unwrap_or_else(|_| {
            keys.into_iter()
                .zip(values)
                .fold(Term::map_new(self.env), |map, (k, v)| {
                    map.map_put(k, v).expect("map")
                })
        })
    }
}

fn read_nbt<'a>(
    env: Env<'a>,
    input: Binary<'a>,
    bytes: usize,
    nodes: i64,
    depth: u32,
) -> Result<Term<'a>, Atom> {
    let limits = nbt::Limits {
        bytes,
        nodes,
        depth,
    };
    let mut terms = Terms { env, input };
    let slice = input.as_slice();
    nbt::read(slice, limits, &mut terms)
        .map(|value| (nbt_atoms::compound(), value).encode(env))
        .map_err(nbt_error)
}

/// Read a disk NBT root (inputs up to `Valimc.NBT`'s scheduler threshold).
#[rustler::nif]
fn nbt_read<'a>(
    env: Env<'a>,
    input: Binary<'a>,
    bytes: usize,
    nodes: i64,
    depth: u32,
) -> Result<Term<'a>, Atom> {
    read_nbt(env, input, bytes, nodes, depth)
}

/// Larger inputs on a dirty CPU scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn nbt_read_dirty<'a>(
    env: Env<'a>,
    input: Binary<'a>,
    bytes: usize,
    nodes: i64,
    depth: u32,
) -> Result<Term<'a>, Atom> {
    read_nbt(env, input, bytes, nodes, depth)
}

// ---- LZ4 region chunks (VMC-021) ----

mod lz4_atoms {
    rustler::atoms! { truncated_compression, invalid_compression, nbt_byte_limit }
}

fn lz4_decode<'a>(env: Env<'a>, input: Binary<'a>, max: usize) -> Result<Term<'a>, Atom> {
    match valimc_core::lz4::decode_stream(input.as_slice(), max) {
        Ok(bytes) => Ok(binary(env, &bytes)),
        Err(valimc_core::lz4::Lz4Error::Truncated) => Err(lz4_atoms::truncated_compression()),
        Err(valimc_core::lz4::Lz4Error::Corrupt) => Err(lz4_atoms::invalid_compression()),
        Err(valimc_core::lz4::Lz4Error::Limit) => Err(lz4_atoms::nbt_byte_limit()),
    }
}

/// Decode an LZ4 block stream (small inputs).
#[rustler::nif]
fn lz4_decode_stream<'a>(env: Env<'a>, input: Binary<'a>, max: usize) -> Result<Term<'a>, Atom> {
    lz4_decode(env, input, max)
}

/// Larger inputs on a dirty CPU scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn lz4_decode_stream_dirty<'a>(
    env: Env<'a>,
    input: Binary<'a>,
    max: usize,
) -> Result<Term<'a>, Atom> {
    lz4_decode(env, input, max)
}

// ---- Imported columns (VMC-021b) ----

/// One section as imported: block palette, packed data, bits; biome palette, data, bits.
type SectionSpec<'a> = (Vec<u16>, Binary<'a>, u32, Vec<u16>, Binary<'a>, u32);

fn imported_column(sections: &[SectionSpec]) -> Result<valimc_core::column::Column, Atom> {
    use valimc_core::column::{Column, SECTIONS};
    use valimc_core::section::Biomes;
    if sections.len() != SECTIONS {
        return Err(atoms::invalid_y());
    }
    let mut storages = Vec::with_capacity(SECTIONS);
    let mut biomes = Vec::with_capacity(SECTIONS);
    for (palette, data, bits, biome_palette, biome_data, biome_bits) in sections {
        storages.push(
            Storage::from_palette(palette, data.as_slice(), *bits).ok_or(atoms::invalid_layers())?,
        );
        biomes.push(
            Biomes::from_palette(biome_palette, biome_data.as_slice(), *biome_bits)
                .ok_or(atoms::invalid_layers())?,
        );
    }
    Ok(Column {
        sections: storages,
        biomes: Some(biomes),
    })
}

/// Replace a chunk's column with 24 imported sections (bottom to top).
#[rustler::nif]
fn put_column(
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
    sections: Vec<SectionSpec>,
) -> Result<Atom, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    let column = imported_column(&sections)?;
    with_store(&region, |store| {
        store.put_column((cx, cz), column, flags).map_err(error)
    })?;
    Ok(atoms::ok())
}

/// The column image of 24 imported sections, without a region (imports).
#[rustler::nif]
fn column_image_of<'a>(env: Env<'a>, sections: Vec<SectionSpec>) -> Result<Term<'a>, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    let column = imported_column(&sections)?;
    let mut valid = true;
    for storage in &column.sections {
        storage.for_each(|_, state| valid &= flags.valid(state as u32));
    }
    if !valid {
        return Err(atoms::invalid_state());
    }
    Ok(binary(env, &column.to_image()))
}

/// The column image of a flat world's chunk (VMC-028b): every column holds
/// `layers` (384 big-endian states from the bottom), its biome `biome`.
#[rustler::nif]
fn column_layers_image<'a>(env: Env<'a>, layers: Binary<'a>, biome: u16) -> Result<Term<'a>, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    if layers.len() != HEIGHT * 2 {
        return Err(atoms::invalid_layers());
    }
    let mut states = [0u16; HEIGHT];
    for (state, bytes) in states.iter_mut().zip(layers.as_slice().chunks_exact(2)) {
        *state = u16::from_be_bytes([bytes[0], bytes[1]]);
        if !flags.valid(*state as u32) {
            return Err(atoms::invalid_state());
        }
    }
    let mut column = valimc_core::column::Column::from_layers(&states);
    column.biomes = Some(vec![
        valimc_core::section::Biomes::Single(biome);
        valimc_core::column::SECTIONS
    ]);
    Ok(binary(env, &column.to_image()))
}

/// Vanilla paletted storage of big-endian u16 `values` (export, VMC-021e3): the
/// palette and the packed longs as a big-endian binary.
#[rustler::nif]
fn pack_paletted<'a>(env: Env<'a>, values: Binary<'a>, min_bits: u32) -> Result<Term<'a>, Atom> {
    if !values.len().is_multiple_of(2) {
        return Err(atoms::invalid_layers());
    }
    let values: Vec<u16> = values
        .as_slice()
        .chunks_exact(2)
        .map(|b| u16::from_be_bytes([b[0], b[1]]))
        .collect();
    let (palette, longs) =
        valimc_core::section::pack_vanilla(&values, min_bits).ok_or(atoms::invalid_layers())?;
    let data: Vec<u8> = longs.iter().flat_map(|l| l.to_be_bytes()).collect();
    Ok((palette, binary(env, &data)).encode(env))
}

/// A chunk's states and biomes as big-endian u16 binaries (section index order).
#[rustler::nif]
fn dump_column<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
    default_biome: u16,
) -> Result<Term<'a>, Atom> {
    let (states, biomes) = with_store(&region, |store| {
        store.dump_column((cx, cz), default_biome).map_err(error)
    })?;
    let be = |values: &[u16]| {
        values
            .iter()
            .flat_map(|v| v.to_be_bytes())
            .collect::<Vec<u8>>()
    };
    Ok((binary(env, &be(&states)), binary(env, &be(&biomes))).encode(env))
}

/// The biome registry id at a block as `Level.getBiome` reads it (vanilla's
/// fuzzed zoom with the hashed seed), or nil when the quart it picks lies
/// outside the region (VMC-072b).
#[rustler::nif]
fn region_biome(
    region: ResourceArc<Region>,
    zoom_seed: i64,
    position: (i32, i32, i32),
    default_biome: u16,
) -> Result<Option<u16>, Atom> {
    let quart = valimc_core::worldgen::surface::zoom(zoom_seed, position.0, position.1, position.2);
    with_store(&region, |store| Ok(store.noise_biome(quart, default_biome)))
}

/// The region-log image of a chunk's column (VMC-021c), or `flat` for the base profile.
#[rustler::nif]
fn column_image<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
) -> Result<Term<'a>, Atom> {
    let image = with_store(&region, |store| store.column_image((cx, cz)).map_err(error))?;
    Ok(match image {
        Some(bytes) => binary(env, &bytes),
        None => atoms::flat().encode(env),
    })
}

/// Restore a chunk's column from its image.
#[rustler::nif]
fn put_column_image(
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
    image: Binary,
) -> Result<Atom, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    let column =
        valimc_core::column::Column::from_image(image.as_slice()).ok_or(atoms::invalid_layers())?;
    with_store(&region, |store| {
        store.put_column((cx, cz), column, flags).map_err(error)
    })?;
    Ok(atoms::ok())
}

// ---- Light (VMC-022) ----

static LIGHT: OnceLock<valimc_core::light::LightFacts> = OnceLock::new();

/// Install the light facts once per VM.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn light_facts_init(
    properties: Binary,
    faces: Vec<Binary>,
    sizes: Vec<usize>,
    occludes: Vec<Binary>,
    sky_states: Binary,
    sky_size: usize,
    sky_pairs: Binary,
) -> Result<Atom, Atom> {
    if faces.len() != 6 || sizes.len() != 6 || occludes.len() != 6 {
        return Err(atoms::invalid_state());
    }
    let facts = valimc_core::light::LightFacts::new(
        properties.as_slice().to_vec(),
        std::array::from_fn(|d| faces[d].as_slice().to_vec()),
        std::array::from_fn(|d| sizes[d]),
        std::array::from_fn(|d| occludes[d].as_slice().to_vec()),
        sky_states.as_slice().to_vec(),
        sky_size,
        sky_pairs.as_slice().to_vec(),
    )
    .ok_or(atoms::invalid_state())?;
    let installed = LIGHT.get_or_init(|| facts);
    if installed.state_count() == properties.len() {
        Ok(atoms::ok())
    } else {
        Err(atoms::flags_mismatch())
    }
}

/// Light of chunks given as column images over the chunk rectangle starting at
/// (`min_cx`, `min_cz`); absent chunks are air. Returns, per given chunk,
/// 24 sections of sky then block nibble arrays (vanilla layout).
#[rustler::nif(schedule = "DirtyCpu")]
fn light_columns<'a>(
    env: Env<'a>,
    images: Vec<(i32, i32, Binary)>,
    min_cx: i32,
    min_cz: i32,
    chunks_x: usize,
    chunks_z: usize,
) -> Result<Vec<(i32, i32, Term<'a>)>, Atom> {
    use valimc_core::column::{Column, SECTIONS};
    use valimc_core::light::{block_light, nibbles, sky_light, Area, HEIGHT};
    let facts = LIGHT.get().ok_or(atoms::flags_missing())?;
    let (wx, wz) = (chunks_x * 16, chunks_z * 16);
    let mut states = vec![0u16; wx * wz * HEIGHT];
    let mut chunks = Vec::new();
    for (cx, cz, image) in &images {
        let column = Column::from_image(image.as_slice()).ok_or(atoms::invalid_layers())?;
        let (ox, oz) = ((cx - min_cx) as usize * 16, (cz - min_cz) as usize * 16);
        if *cx < min_cx || *cz < min_cz || ox >= wx || oz >= wz {
            return Err(atoms::out_of_region());
        }
        for (s, storage) in column.sections.iter().enumerate() {
            storage.for_each(|i, state| {
                let (x, y, z) = (i & 15, s * 16 + (i >> 8), (i >> 4) & 15);
                states[((ox + x) * wz + oz + z) * HEIGHT + y] = state;
            });
        }
        chunks.push((*cx, *cz, ox, oz));
    }
    let area = Area {
        wx,
        wz,
        states: &states,
    };
    let sky = sky_light(&area, facts);
    let block = block_light(&area, facts);
    Ok(chunks
        .into_iter()
        .map(|(cx, cz, ox, oz)| {
            let mut out = Vec::with_capacity(SECTIONS * 4096);
            for s in 0..SECTIONS {
                for levels in [&sky, &block] {
                    out.extend(nibbles(|i| {
                        let (x, y, z) = (i & 15, s * 16 + (i >> 8), (i >> 4) & 15);
                        levels[((ox + x) * wz + oz + z) * HEIGHT + y]
                    }));
                }
            }
            (cx, cz, binary(env, &out))
        })
        .collect())
}

/// Light the region and its ring from scratch (VMC-022c).
#[rustler::nif(schedule = "DirtyCpu")]
fn light_compute(region: ResourceArc<Region>) -> Result<Atom, Atom> {
    let facts = LIGHT.get().ok_or(atoms::flags_missing())?;
    with_store(&region, |store| {
        store.light_compute(facts);
        Ok(atoms::ok())
    })
}

fn relight(region: &Region, positions: &[(i32, i32, i32)]) -> Result<Vec<(i32, i32)>, Atom> {
    let facts = LIGHT.get().ok_or(atoms::flags_missing())?;
    with_store(region, |store| Ok(store.light_update(facts, positions)))
}

/// Relight after block changes; returns the region's chunks whose light changed.
#[rustler::nif]
fn light_update(
    region: ResourceArc<Region>,
    positions: Vec<(i32, i32, i32)>,
) -> Result<Vec<(i32, i32)>, Atom> {
    relight(&region, &positions)
}

/// Larger batches on a dirty CPU scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn light_update_dirty(
    region: ResourceArc<Region>,
    positions: Vec<(i32, i32, i32)>,
) -> Result<Vec<(i32, i32)>, Atom> {
    relight(&region, &positions)
}

/// A chunk's light image, or `flat` before the region is lit.
#[rustler::nif]
fn light_image<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
) -> Result<Term<'a>, Atom> {
    let image = with_store(&region, |store| store.light_image((cx, cz)).map_err(error))?;
    Ok(match image {
        Some(bytes) => binary(env, &bytes),
        None => atoms::flat().encode(env),
    })
}

/// Set ring chunks from a neighbour's column images (or `flat`) and relight once.
#[rustler::nif(schedule = "DirtyCpu")]
fn halo_put(
    region: ResourceArc<Region>,
    chunks: Vec<(i32, i32, Term)>,
) -> Result<Vec<(i32, i32)>, Atom> {
    let facts = LIGHT.get().ok_or(atoms::flags_missing())?;
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    let mut columns = Vec::with_capacity(chunks.len());
    for (cx, cz, image) in chunks {
        let column = match image.decode::<Binary>() {
            Ok(bytes) => {
                let column = valimc_core::column::Column::from_image(bytes.as_slice())
                    .ok_or(atoms::invalid_layers())?;
                let mut valid = true;
                for storage in &column.sections {
                    storage.for_each(|_, state| valid &= flags.valid(state as u32));
                }
                if !valid {
                    return Err(atoms::invalid_state());
                }
                Some(column)
            }
            Err(_) => None,
        };
        columns.push(((cx, cz), column));
    }
    with_store(&region, |store| {
        store.halo_put(facts, columns).map_err(error)
    })
}

/// Apply a neighbour's block changes in the ring and relight.
#[rustler::nif]
fn halo_edits(
    region: ResourceArc<Region>,
    edits: Vec<(i32, i32, i32, u32)>,
) -> Result<Vec<(i32, i32)>, Atom> {
    let facts = LIGHT.get().ok_or(atoms::flags_missing())?;
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    if edits.iter().any(|e| !flags.valid(e.3)) {
        return Err(atoms::invalid_state());
    }
    let edits: Vec<(i32, i32, i32, u16)> = edits
        .into_iter()
        .map(|(x, y, z, s)| (x, y, z, s as u16))
        .collect();
    with_store(&region, |store| Ok(store.halo_edits(facts, &edits)))
}

// ---- World generation (VMC-023) ----

/// Run a random-source operation trace (`valimc_core::worldgen::trace`).
#[rustler::nif]
fn worldgen_random_trace(kind: String, seed: i64, ops: Vec<String>) -> Result<Vec<String>, String> {
    valimc_core::worldgen::trace::run(&kind, seed, &ops)
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
) -> Result<NoiseSamples, String> {
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
}

/// Worldgen registries parsed from the generated facts.
pub struct WorldgenRegistry {
    registry: std::sync::Arc<valimc_core::worldgen::compiler::Registry>,
}

#[rustler::resource_impl]
impl rustler::Resource for WorldgenRegistry {}

/// Noises and compiled samplers for one seed and noise settings. Compiling is
/// lazy and each state keeps caches, so a call leases a state of its own from
/// a pool (VMC-025d): generations of one seed run in parallel, one state per
/// concurrent call.
pub struct WorldgenState {
    registry: std::sync::Arc<valimc_core::worldgen::compiler::Registry>,
    seed: i64,
    settings: String,
    pool: Mutex<Vec<valimc_core::worldgen::compiler::Worldgen>>,
}

#[rustler::resource_impl]
impl rustler::Resource for WorldgenState {}

/// States kept for reuse; more concurrent calls build more and drop the rest.
const WORLDGEN_POOL: usize = 64;

/// A state leased from a pool, returned when dropped (not after a panic).
struct WorldgenLease<'a> {
    owner: &'a WorldgenState,
    state: Option<valimc_core::worldgen::compiler::Worldgen>,
}

impl WorldgenState {
    fn lease(&self) -> Result<WorldgenLease<'_>, String> {
        let pooled = self
            .pool
            .lock()
            .map_err(|_| "worldgen state poisoned")?
            .pop();
        let state = match pooled {
            Some(state) => state,
            None => valimc_core::worldgen::compiler::Worldgen::new(
                self.registry.clone(),
                self.seed,
                &self.settings,
            )?,
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

fn json_of(term: Term) -> Result<valimc_core::worldgen::json::Json, String> {
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
    let state =
        valimc_core::worldgen::compiler::Worldgen::new(registry.registry.clone(), seed, &settings)?;
    Ok(ResourceArc::new(WorldgenState {
        registry: registry.registry.clone(),
        seed,
        settings,
        pool: Mutex::new(vec![state]),
    }))
}

/// Sample a density function for parity checks
/// (`valimc_core::worldgen::trace::density`).
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_density_samples(
    state: ResourceArc<WorldgenState>,
    function: String,
    cached: bool,
    ops: Vec<Vec<i32>>,
) -> Result<Vec<Vec<u32>>, String> {
    let mut state = state.lease()?;
    valimc_core::worldgen::trace::density(&mut state, &function, cached, &ops)
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
) -> Result<ChunkBiomeBinaries<'a>, String> {
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
}

/// The biomes at the minimal climate distance from a target: the answers a
/// lookup can give, depending on lookup history.
#[rustler::nif]
fn worldgen_closest_biomes(
    state: ResourceArc<WorldgenState>,
    preset: String,
    target: Vec<i64>,
) -> Result<Vec<String>, String> {
    let state = state.lease()?;
    let list = state.biome_parameters(&preset)?;
    let target: [i64; 6] = target.try_into().map_err(|_| "a target has six values")?;
    Ok(list
        .closest_biomes(&target)
        .into_iter()
        .map(|b| list.biomes[b as usize].clone())
        .collect())
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
) -> Result<Vec<FilledBinary<'a>>, String> {
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
) -> Result<Vec<FilledBinary<'a>>, String> {
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

/// A scheduled tick: position, block id or fluid name, delay and priority.
type BlockTick = ((i32, i32, i32), u16, i32, i32);
type FluidTick = ((i32, i32, i32), String, i32, i32);

/// One decorated chunk for `check_decoration.exs`.
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
) -> Result<Vec<DecoratedChunk<'a>>, String> {
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
}

/// Structure placement parity (VMC-025f): the 5 × 5 chunks around `centre`
/// with their terrain, the chunks in `order` decorated with every placed
/// feature and the starts of `structures` (identifiers) placed in their
/// steps; also each start as placement left it (canonical SNBT).
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_decorate_structures<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    centre: (i32, i32),
    order: Vec<(i32, i32)>,
    structures: Vec<String>,
) -> Result<(Vec<DecoratedChunk<'a>>, Vec<String>), String> {
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
}

/// A chunk's blocks (big endian), post-processing marks, scheduled ticks and
/// block entities, as `check_decoration.exs` compares them.
fn decorated_chunk<'a>(
    env: rustler::Env<'a>,
    chunk: &valimc_core::worldgen::region::ProtoChunk,
) -> DecoratedChunk<'a> {
    use valimc_core::worldgen::blocks::FLUID_NAMES;
    let mut blocks = NewBinary::new(env, chunk.blocks.len() * 2);
    for (bytes, id) in blocks.as_mut_slice().chunks_mut(2).zip(&chunk.blocks) {
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
) -> Result<Vec<ShapeOutcome>, String> {
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
) -> Result<u64, String> {
    let mut state = state.lease()?;
    let included: std::collections::HashSet<(usize, usize)> = features.into_iter().collect();
    let (_, elapsed) =
        state.decorate_area_timed(&biome_source, origin, size, &order, Some(&included))?;
    Ok(elapsed.as_nanos() as u64)
}

/// Structure generation for parity checks (VMC-025e): the structure sets
/// that can occur for `biome_source`, and every concentric ring set's
/// positions.
type RingPositions = Vec<(String, Vec<(i32, i32)>)>;

#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_structure_state(
    state: ResourceArc<WorldgenState>,
    biome_source: String,
) -> Result<(Vec<String>, RingPositions), String> {
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
}

/// A structure start: its chunk, structure and canonical SNBT.
type StartRow = (i32, i32, String, String);

/// `createStructures` in fresh chunks (VMC-025e): every start, and the sets
/// skipped because ValiMC does not generate one of their structure types yet.
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_structure_starts(
    state: ResourceArc<WorldgenState>,
    biome_source: String,
    chunks: Vec<(i32, i32)>,
) -> Result<(Vec<StartRow>, Vec<String>), String> {
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
) -> Result<(WindowPlacements, Vec<ReferenceRow>), String> {
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
    let mut state = state.lease()?;
    let mut out = Vec::with_capacity(chunks.len());
    for (x, z) in chunks {
        let chunk = state.proto_terrain(x, z, &biome_source)?;
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
    decorate_protos(env, state, "minecraft:overworld", chunks, order)
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
    decorate_protos(env, state, &biome_source, chunks, order)
}

fn decorate_protos<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    biome_source: &str,
    chunks: Vec<Binary>,
    order: Vec<(i32, i32)>,
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
    let lenient_reads = state.decorate_held(biome_source, &mut area, &order, None, true)?;
    Ok((
        area.held()
            .filter(|c| c.touched)
            .map(|c| proto_binary(env, c))
            .collect(),
        lenient_reads,
    ))
}

/// Encoded proto chunks as `worldgen_decorate` reports chunks (parity).
#[rustler::nif(schedule = "DirtyCpu")]
fn worldgen_proto_inspect<'a>(
    env: rustler::Env<'a>,
    state: ResourceArc<WorldgenState>,
    chunks: Vec<Binary>,
) -> Result<Vec<DecoratedChunk<'a>>, String> {
    let state = state.lease()?;
    let mut out = Vec::with_capacity(chunks.len());
    for bytes in &chunks {
        let chunk = valimc_core::worldgen::proto::decode(bytes.as_slice(), state.block_table()?)?;
        out.push(decorated_chunk(env, &chunk));
    }
    Ok(out)
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
) -> Result<(u64, u64, usize), String> {
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

// ---- Container loot tables (VMC-072a) ----

pub struct LootRegistry {
    loot: std::sync::Arc<valimc_core::loot::Loot>,
}

#[rustler::resource_impl]
impl rustler::Resource for LootRegistry {}

/// Parse the loot facts (`priv/loot/tables.json`, `registries.json`).
#[rustler::nif(schedule = "DirtyCpu")]
fn loot_registry(tables: Term, registries: Term) -> Result<ResourceArc<LootRegistry>, String> {
    let loot = valimc_core::loot::Loot::parse(&json_of(tables)?, &json_of(registries)?)?;
    Ok(ResourceArc::new(LootRegistry {
        loot: std::sync::Arc::new(loot),
    }))
}

/// What a table may ask the world, answered up front: the biome at the loot
/// origin, the structure a map search finds (for any destination) and the
/// next free map id.
struct LootAnswers {
    biome: Option<String>,
    structure: Option<[i32; 3]>,
    next_map: i32,
}

impl valimc_core::loot::LootWorld for LootAnswers {
    fn biome(&mut self, _pos: [i32; 3]) -> Option<String> {
        self.biome.clone()
    }
    fn map_structure(
        &mut self,
        _tag: Option<&str>,
        _structures: &[String],
        _origin: [i32; 3],
        _radius: i32,
        _skip_existing: bool,
    ) -> Option<[i32; 3]> {
        self.structure
    }
    fn new_map(&mut self, _x: i32, _z: i32, _scale: i32) -> i32 {
        let id = self.next_map;
        self.next_map += 1;
        id
    }
}

/// A `Valimc.NBT` term.
fn nbt_term<'a>(env: Env<'a>, kind: Atom, value: Term<'a>) -> Term<'a> {
    (kind, value).encode(env)
}

fn nbt_compound<'a>(env: Env<'a>, fields: Vec<(&str, Term<'a>)>) -> Term<'a> {
    let map = fields.into_iter().fold(Term::map_new(env), |map, (k, v)| {
        map.map_put(binary(env, k.as_bytes()), v).expect("map")
    });
    nbt_term(env, nbt_atoms::compound(), map)
}

fn nbt_string<'a>(env: Env<'a>, s: &str) -> Term<'a> {
    nbt_term(env, nbt_atoms::string(), binary(env, s.as_bytes()))
}

fn nbt_int<'a>(env: Env<'a>, n: i32) -> Term<'a> {
    nbt_term(env, nbt_atoms::int(), n.encode(env))
}

/// A text component's JSON as NBT: objects as compounds, strings, booleans
/// as bytes, integers as ints, other numbers as doubles, lists.
fn json_nbt<'a>(env: Env<'a>, json: &valimc_core::worldgen::json::Json) -> Term<'a> {
    use valimc_core::worldgen::json::Json;
    match json {
        Json::Object(fields) => nbt_compound(
            env,
            fields
                .iter()
                .map(|(k, v)| (k.as_str(), json_nbt(env, v)))
                .collect(),
        ),
        Json::String(s) => nbt_string(env, s),
        Json::Bool(b) => nbt_term(env, nbt_atoms::byte(), (*b as i32).encode(env)),
        Json::Number(n) if n.fract() == 0.0 && n.abs() < 2_147_483_648.0 => nbt_int(env, *n as i32),
        Json::Number(n) => nbt_term(env, nbt_atoms::double(), binary(env, &n.to_be_bytes())),
        Json::Array(items) => {
            let tags: Vec<Term<'a>> = items.iter().map(|i| json_nbt(env, i)).collect();
            list_term(env, tags)
        }
        Json::Null => nbt_compound(env, Vec::new()),
    }
}

/// `Valimc.NBT.list/1` of tagged terms: one element type, values unwrapped.
fn list_term<'a>(env: Env<'a>, tags: Vec<Term<'a>>) -> Term<'a> {
    if tags.is_empty() {
        return nbt_term(
            env,
            nbt_atoms::list(),
            (nbt_atoms::end_(), Vec::<Term>::new()).encode(env),
        );
    }
    let mut kind = None;
    let mut values = Vec::with_capacity(tags.len());
    for tag in tags {
        let (k, v): (Atom, Term<'a>) = tag.decode().expect("tagged term");
        kind = Some(k);
        values.push(v);
    }
    nbt_term(
        env,
        nbt_atoms::list(),
        (kind.expect("a kind"), values).encode(env),
    )
}

/// A loot stack as an item tag (`{id, count, components}` as world files
/// store it).
fn loot_stack<'a>(env: Env<'a>, stack: &valimc_core::loot::Stack) -> Term<'a> {
    let mut components: Vec<(&str, Term<'a>)> = Vec::new();
    let levels = |list: &Vec<(String, i32)>| {
        nbt_compound(
            env,
            list.iter()
                .map(|(e, l)| (e.as_str(), nbt_int(env, *l)))
                .collect(),
        )
    };
    if !stack.enchantments.is_empty() {
        components.push(("minecraft:enchantments", levels(&stack.enchantments)));
    }
    if !stack.stored_enchantments.is_empty() {
        components.push((
            "minecraft:stored_enchantments",
            levels(&stack.stored_enchantments),
        ));
    }
    if stack.damage != 0 {
        components.push(("minecraft:damage", nbt_int(env, stack.damage)));
    }
    if let Some(p) = &stack.potion {
        components.push((
            "minecraft:potion_contents",
            nbt_compound(env, vec![("potion", nbt_string(env, p))]),
        ));
    }
    if !stack.stew_effects.is_empty() {
        let entries = stack
            .stew_effects
            .iter()
            .map(|(e, d)| {
                let mut fields = vec![("id", nbt_string(env, e))];
                if *d != 160 {
                    fields.push(("duration", nbt_int(env, *d)));
                }
                nbt_compound(env, fields)
            })
            .collect();
        components.push(("minecraft:suspicious_stew_effects", list_term(env, entries)));
    }
    if let Some(i) = &stack.instrument {
        components.push(("minecraft:instrument", nbt_string(env, i)));
    }
    if let Some(a) = stack.ominous_amplifier {
        components.push(("minecraft:ominous_bottle_amplifier", nbt_int(env, a)));
    }
    if let Some(n) = &stack.item_name {
        components.push(("minecraft:item_name", json_nbt(env, n)));
    }
    if let Some(n) = &stack.custom_name {
        components.push(("minecraft:custom_name", json_nbt(env, n)));
    }
    if let Some(id) = stack.map_id {
        components.push(("minecraft:map_id", nbt_int(env, id)));
    }
    if !stack.map_decorations.is_empty() {
        let entries = stack
            .map_decorations
            .iter()
            .map(|(key, kind, x, z, rotation)| {
                (
                    key.as_str(),
                    nbt_compound(
                        env,
                        vec![
                            ("type", nbt_string(env, kind)),
                            (
                                "x",
                                nbt_term(env, nbt_atoms::double(), binary(env, &x.to_be_bytes())),
                            ),
                            (
                                "z",
                                nbt_term(env, nbt_atoms::double(), binary(env, &z.to_be_bytes())),
                            ),
                            (
                                "rotation",
                                nbt_term(
                                    env,
                                    nbt_atoms::float(),
                                    binary(env, &rotation.to_be_bytes()),
                                ),
                            ),
                        ],
                    ),
                )
            })
            .collect();
        components.push(("minecraft:map_decorations", nbt_compound(env, entries)));
    }
    let mut fields = vec![
        ("id", nbt_string(env, &stack.item)),
        ("count", nbt_int(env, stack.count)),
    ];
    if !components.is_empty() {
        fields.push(("components", nbt_compound(env, components)));
    }
    nbt_compound(env, fields)
}

fn loot_random(seed: i64) -> valimc_core::worldgen::random::Random {
    valimc_core::worldgen::random::Random::legacy(seed)
}

/// `LootTable.fill` of an empty container with `size` slots and a stored
/// seed: the slots (item tags or nil) and the next free map id.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn loot_fill<'a>(
    env: Env<'a>,
    registry: ResourceArc<LootRegistry>,
    table: String,
    seed: i64,
    luck: f64,
    origin: (f64, f64, f64),
    size: usize,
    biome: Option<String>,
    structure: Option<(i32, i32, i32)>,
    next_map: i32,
) -> Result<(Vec<Term<'a>>, i32), String> {
    let mut world = LootAnswers {
        biome,
        structure: structure.map(|(x, y, z)| [x, y, z]),
        next_map,
    };
    let slots = registry.loot.fill(
        &table,
        loot_random(seed),
        luck as f32,
        [origin.0, origin.1, origin.2],
        size,
        &mut world,
    )?;
    let terms = slots
        .iter()
        .map(|slot| match slot {
            Some(stack) => loot_stack(env, stack),
            None => rustler::types::atom::nil().encode(env),
        })
        .collect();
    Ok((terms, world.next_map))
}

/// `LootTable.getRandomItems` with a stored seed (brushable blocks): the item
/// tags and the next free map id.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn loot_items<'a>(
    env: Env<'a>,
    registry: ResourceArc<LootRegistry>,
    table: String,
    seed: i64,
    luck: f64,
    origin: (f64, f64, f64),
    biome: Option<String>,
    structure: Option<(i32, i32, i32)>,
    next_map: i32,
) -> Result<(Vec<Term<'a>>, i32), String> {
    let mut world = LootAnswers {
        biome,
        structure: structure.map(|(x, y, z)| [x, y, z]),
        next_map,
    };
    let items = registry.loot.items(
        &table,
        loot_random(seed),
        luck as f32,
        [origin.0, origin.1, origin.2],
        &mut world,
    )?;
    Ok((
        items.iter().map(|s| loot_stack(env, s)).collect(),
        world.next_map,
    ))
}

rustler::init!("Elixir.Valimc.Native");
