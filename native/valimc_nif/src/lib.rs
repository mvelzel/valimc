//! Rustler shim: each region owner holds one `Region` resource; calls are short
//! (batched) and run on normal schedulers. Inputs are validated by valimc_core.

use rustler::{Atom, Binary, Encoder, Env, NewBinary, ResourceArc, Term};
use std::sync::{Mutex, OnceLock};
use valimc_core::column::HEIGHT;
use valimc_core::{BlockFlags, ColumnStore, Storage, StoreError};

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
fn snapshot_chunk<'a>(env: Env<'a>, region: ResourceArc<Region>, cx: i32, cz: i32) -> Result<Term<'a>, Atom> {
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
                    (rustler::types::tuple::make_tuple(env, &palette), binary(env, &cells[..])).encode(env)
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

rustler::init!("Elixir.Valimc.Native");
