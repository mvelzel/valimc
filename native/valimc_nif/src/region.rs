//! The Region resource: one per region owner, holding its column store. Only
//! the process that created it may change it (`with_owned`).
//!
//! Positions travel as packed big-endian binaries: a position is
//! `<<x::32-signed, y::32-signed, z::32-signed>>`, a block read at a position
//! adds `<<state::16>>`, a change to write `<<state::32>>` (so an out-of-range
//! state is refused, not wrapped).

use crate::facts::{FLAGS, LIGHT};
use crate::{atoms, binary, bytes, done};
use rustler::{Atom, Binary, Encoder, Env, LocalPid, NewBinary, NifResult, ResourceArc, Term};
use std::sync::Mutex;
use valimc_core::column::HEIGHT;
use valimc_core::{ColumnStore, Storage, StoreError};

pub struct Region {
    owner: LocalPid,
    store: Mutex<ColumnStore>,
}

#[rustler::resource_impl]
impl rustler::Resource for Region {}

pub(crate) fn error(e: StoreError) -> Atom {
    match e {
        StoreError::OutOfRegion => atoms::out_of_region(),
        StoreError::InvalidY => atoms::invalid_y(),
        StoreError::InvalidState => atoms::invalid_state(),
        StoreError::MemoryBudget => atoms::memory_budget(),
    }
}

/// A region owned by the calling process. `layers` is 384 big-endian u16
/// states, bottom (y = -64) first.
#[rustler::nif]
fn region_new(
    env: Env,
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
    for (i, pair) in bytes.as_chunks::<2>().0.iter().enumerate() {
        let state = u16::from_be_bytes(*pair);
        if !flags.valid(state as u32) {
            return Err(atoms::invalid_layers());
        }
        base[i] = state;
    }
    let store = ColumnStore::new((cx, cz), size, base, budget);
    Ok(ResourceArc::new(Region {
        owner: env.pid(),
        store: Mutex::new(store),
    }))
}

/// Read the store (any process: reads change nothing).
pub(crate) fn with_store<T>(
    region: &Region,
    f: impl FnOnce(&mut ColumnStore) -> Result<T, Atom>,
) -> Result<T, Atom> {
    let mut guard = region.store.lock().map_err(|_| atoms::poisoned())?;
    f(&mut guard)
}

/// Change the store: only its owner may.
pub(crate) fn with_owned<T>(
    env: Env,
    region: &Region,
    f: impl FnOnce(&mut ColumnStore) -> Result<T, Atom>,
) -> Result<T, Atom> {
    if env.pid() != region.owner {
        return Err(atoms::not_owner());
    }
    with_store(region, f)
}

/// Packed positions (see the module doc).
fn positions(packed: &[u8]) -> Result<impl Iterator<Item = (i32, i32, i32)> + '_, Atom> {
    let (records, rest) = packed.as_chunks::<12>();
    if !rest.is_empty() {
        return Err(atoms::invalid_positions());
    }
    Ok(records.iter().map(|r| {
        let at = |i: usize| i32::from_be_bytes([r[i], r[i + 1], r[i + 2], r[i + 3]]);
        (at(0), at(4), at(8))
    }))
}

/// Blocks at positions as packed `{x, y, z, state}` records.
fn packed_blocks<'a>(env: Env<'a>, blocks: &[(i32, i32, i32, u16)]) -> Binary<'a> {
    let mut out = NewBinary::new(env, blocks.len() * 14);
    for (record, (x, y, z, state)) in out
        .as_mut_slice()
        .as_chunks_mut::<14>()
        .0
        .iter_mut()
        .zip(blocks)
    {
        record[0..4].copy_from_slice(&x.to_be_bytes());
        record[4..8].copy_from_slice(&y.to_be_bytes());
        record[8..12].copy_from_slice(&z.to_be_bytes());
        record[12..14].copy_from_slice(&state.to_be_bytes());
    }
    out.into()
}

/// The states at packed positions, as big-endian u16 in input order.
#[rustler::nif]
fn get_blocks<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    positions_bin: Binary,
) -> Result<Binary<'a>, Atom> {
    let positions = positions(positions_bin.as_slice())?;
    let mut out = NewBinary::new(env, positions_bin.len() / 6);
    with_store(&region, |store| {
        for (bytes, (x, y, z)) in out
            .as_mut_slice()
            .as_chunks_mut::<2>()
            .0
            .iter_mut()
            .zip(positions)
        {
            *bytes = store.get(x, y, z).map_err(error)?.to_be_bytes();
        }
        Ok(())
    })?;
    Ok(out.into())
}

/// Apply packed `{x, y, z, state::32}` changes, all or none
/// (`Valimc.Native.dispatch/3` picks this or the dirty twin).
#[rustler::nif]
fn set_blocks(env: Env, region: ResourceArc<Region>, changes: Binary) -> NifResult<Atom> {
    done(set_many(env, &region, changes))
}

/// `set_blocks` on a dirty CPU scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn set_blocks_dirty(env: Env, region: ResourceArc<Region>, changes: Binary) -> NifResult<Atom> {
    done(set_many(env, &region, changes))
}

fn set_many(env: Env, region: &Region, changes: Binary) -> Result<(), Atom> {
    {
        let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
        let (records, rest) = changes.as_slice().as_chunks::<16>();
        if !rest.is_empty() {
            return Err(atoms::invalid_positions());
        }
        let changes: Vec<(i32, i32, i32, u32)> = records
            .iter()
            .map(|r| {
                let at = |i: usize| i32::from_be_bytes([r[i], r[i + 1], r[i + 2], r[i + 3]]);
                (at(0), at(4), at(8), at(12) as u32)
            })
            .collect();
        with_owned(env, region, |store| {
            store.set_many(&changes, flags).map_err(error).map(drop)
        })
    }
}

/// `{sections, world_surface_longs, motion_blocking_longs}` for one chunk's
/// stored sections `first..first + count` (the dimension's window).
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn encode_chunk<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
    biome: u32,
    global_bits: u32,
    biome_bits: u32,
    window: (usize, usize),
) -> Result<Term<'a>, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    if !(1..=16).contains(&global_bits) || !(1..=16).contains(&biome_bits) {
        return Err(atoms::invalid_state());
    }
    let whole = window == (0, valimc_core::column::SECTIONS);
    let encoded = with_store(&region, |store| {
        if whole && !store.touched((cx, cz)) {
            // Callers keep a cached packet for the unmodified base profile.
            store.check_chunk((cx, cz)).map_err(error)?;
            return Ok(None);
        }
        store
            .encode_chunk((cx, cz), flags, biome, global_bits, biome_bits, window)
            .map(Some)
            .map_err(error)
    })?;
    Ok(match encoded {
        None => atoms::flat().encode(env),
        Some((sections, surface, motion)) => (
            bytes(env, sections),
            bytes(env, surface),
            bytes(env, motion),
        )
            .encode(env),
    })
}

/// Packed `{x, y, z, state}` records of the positions in one chunk holding any
/// of `states` (block-entity carriers).
#[rustler::nif]
fn chunk_find<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
    states: Vec<u16>,
) -> Result<Binary<'a>, Atom> {
    let found = with_store(&region, |store| {
        store.find((cx, cz), &states).map_err(error)
    })?;
    Ok(packed_blocks(env, &found))
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
                    let mut out = NewBinary::new(env, cells.len() * 2);
                    for (bytes, cell) in out
                        .as_mut_slice()
                        .as_chunks_mut::<2>()
                        .0
                        .iter_mut()
                        .zip(cells.iter())
                    {
                        *bytes = cell.to_be_bytes();
                    }
                    (atoms::dense(), Binary::from(out)).encode(env)
                }
            })
            .collect();
        Ok(sections.encode(env))
    })
}

/// Install the region's randomly ticking states: one bit per state id (LSB first).
#[rustler::nif]
fn set_random_ticking(env: Env, region: ResourceArc<Region>, bitmap: Binary) -> NifResult<Atom> {
    let bytes = bitmap.as_slice();
    done(with_owned(env, &region, |store| {
        store.ticking = (0..bytes.len() * 8)
            .map(|i| bytes[i / 8] & (1 << (i % 8)) != 0)
            .collect();
        Ok(())
    }))
}

/// One tick's random tick hits, packed `{x, y, z, state}` records of sampled
/// ticking states (the draws advance the region's random;
/// `Valimc.Native.dispatch/3` picks this or the dirty twin).
#[rustler::nif]
fn random_ticks<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    per_section: u32,
) -> Result<Binary<'a>, Atom> {
    sample_ticks(env, &region, per_section)
}

/// `random_ticks` on a dirty CPU scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn random_ticks_dirty<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    per_section: u32,
) -> Result<Binary<'a>, Atom> {
    sample_ticks(env, &region, per_section)
}

fn sample_ticks<'a>(env: Env<'a>, region: &Region, per_section: u32) -> Result<Binary<'a>, Atom> {
    if per_section > 4096 {
        return Err(atoms::invalid_state());
    }
    let hits = with_owned(env, region, |store| Ok(store.random_ticks(per_section)))?;
    Ok(packed_blocks(env, &hits))
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
    Ok((be_u16(env, &states), be_u16(env, &biomes)).encode(env))
}

/// A chunk's published column facts (VMC-077e) as `{heights, biomes}`:
/// `heights` per column (`z * 16 + x`) a big-endian u16 MOTION_BLOCKING
/// height and lowest sky source, relative to y = -64; `biomes` its stored
/// biomes as big-endian u16 (24 sections × 64 quarts) or nil for the region's
/// default biome.
#[rustler::nif]
fn column_facts<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
) -> Result<Term<'a>, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    let light = LIGHT.get().ok_or(atoms::light_facts_missing())?;
    let (heights, biomes) = with_store(&region, |store| {
        store.column_facts((cx, cz), flags, light).map_err(error)
    })?;
    let biomes = match biomes {
        Some(biomes) => be_u16(env, &biomes).encode(env),
        None => rustler::types::atom::nil().encode(env),
    };
    Ok((be_u16(env, &heights), biomes).encode(env))
}

fn be_u16<'a>(env: Env<'a>, values: &[u16]) -> Binary<'a> {
    let mut out = NewBinary::new(env, values.len() * 2);
    for (bytes, value) in out
        .as_mut_slice()
        .as_chunks_mut::<2>()
        .0
        .iter_mut()
        .zip(values)
    {
        *bytes = value.to_be_bytes();
    }
    Binary::from(out)
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

/// Column images by chunk.
type Images<'a> = Vec<(i32, i32, Binary<'a>)>;

/// `/fillbiome` (VMC-053j4): the changed cell count and the new column
/// images of `chunks`, without changing the region.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn fill_biomes<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    chunks: Vec<(i32, i32)>,
    min: (i32, i32, i32),
    max: (i32, i32, i32),
    biome: u16,
    filter: Option<Vec<u16>>,
    default_biome: u16,
) -> Result<(u32, Images<'a>), Atom> {
    let (count, images) = with_store(&region, |store| {
        store
            .fill_biomes(
                &chunks,
                [min.0, min.1, min.2],
                [max.0, max.1, max.2],
                biome,
                filter.as_deref(),
                default_biome,
            )
            .map_err(error)
    })?;
    Ok((
        count,
        images
            .into_iter()
            .map(|((x, z), image)| (x, z, bytes(env, image)))
            .collect(),
    ))
}

/// A chunk's biome containers for `chunks_biomes` (VMC-053j4).
#[rustler::nif]
fn encode_biomes<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
    default_biome: u32,
    biome_bits: u32,
    window: (usize, usize),
) -> Result<Binary<'a>, Atom> {
    let encoded = with_store(&region, |store| {
        store
            .encode_biomes((cx, cz), default_biome, biome_bits, window)
            .map_err(error)
    })?;
    Ok(bytes(env, encoded))
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
        Some(image) => bytes(env, image).encode(env),
        None => atoms::flat().encode(env),
    })
}

/// Restore a chunk's column from its image, with the light it was stored with.
#[rustler::nif]
fn put_column_image(
    env: Env,
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
    image: Binary,
) -> NifResult<Atom> {
    done((|| {
        let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
        // Images from before stored light (VMC-077c) are refused, not read (D4).
        if image.first() < Some(&valimc_core::column::IMAGE_VERSION) {
            return Err(atoms::old_column_image());
        }
        let (column, light) = valimc_core::column::Column::read_image(image.as_slice())
            .ok_or(atoms::invalid_layers())?;
        with_owned(env, &region, |store| {
            store
                .restore_column((cx, cz), column, light, flags)
                .map_err(error)
        })
    })())
}
