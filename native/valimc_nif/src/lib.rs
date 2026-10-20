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
) -> Result<Term<'a>, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    if !(1..=16).contains(&global_bits) {
        return Err(atoms::invalid_state());
    }
    let encoded = with_store(&region, |store| {
        if !store.touched((cx, cz)) {
            // Callers keep a cached packet for the unmodified base profile.
            store.check_chunk((cx, cz)).map_err(error)?;
            return Ok(None);
        }
        store
            .encode_chunk((cx, cz), flags, biome, global_bits)
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

rustler::init!("Elixir.Valimc.Native");
