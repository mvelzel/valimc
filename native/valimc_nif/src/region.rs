//! The Region resource: one per region owner, holding its column store.

use crate::codec::{imported_column, SectionSpec};
use crate::{atoms, binary};
use rustler::{Atom, Binary, Encoder, Env, ResourceArc, Term};
use std::sync::{Mutex, OnceLock};
use valimc_core::column::HEIGHT;
use valimc_core::{BlockFlags, ColumnStore, Storage, StoreError};

pub(crate) static FLAGS: OnceLock<BlockFlags> = OnceLock::new();

pub struct Region {
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
    for (i, pair) in bytes.as_chunks::<2>().0.iter().enumerate() {
        let state = u16::from_be_bytes(*pair);
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

pub(crate) fn with_store<T>(
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

/// Column images by chunk as terms.
type ImageTerms<'a> = Vec<(i32, i32, Term<'a>)>;

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
) -> Result<(u32, ImageTerms<'a>), Atom> {
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
            .map(|((x, z), image)| (x, z, binary(env, &image)))
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
) -> Result<Term<'a>, Atom> {
    let bytes = with_store(&region, |store| {
        store
            .encode_biomes((cx, cz), default_biome, biome_bits, window)
            .map_err(error)
    })?;
    Ok(binary(env, &bytes))
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
