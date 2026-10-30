//! Block and sky light over the Region resource, chunk by chunk (VMC-077c).

use crate::facts::{CARRIERS, FLAGS, LIGHT};
use crate::region::{error, with_owned, with_store, Region};
use crate::{atoms, bytes, done};
use rustler::{Atom, Binary, Encoder, Env, NifResult, ResourceArc, Term};
use std::sync::Arc;
use valimc_core::column::{with_light, Column, PacketSpec, Prepared};
use valimc_core::light_grid::{light_alone, ChunkLight, TooLarge};

/// Whether the region's dimension has sky light (VMC-026b); set before lighting.
#[rustler::nif]
fn light_sky(env: Env, region: ResourceArc<Region>, sky: bool) -> NifResult<Atom> {
    done(with_owned(env, &region, |store| {
        store.sky = sky;
        Ok(())
    }))
}

/// Queue steps a light update takes on a normal scheduler (about 0.5 ms at
/// 25–30 ns a step); one that needs more is undone and runs dirty.
const UPDATE_BUDGET: usize = 16_384;

/// A chunk whose light changed and its changed sections' sky and block bits.
type Change = ((i32, i32), u32, u32);

/// Light the region (VMC-077c): its chunks but the `absent` ones, from the light
/// their columns were stored with or lit alone, then the seams between them.
#[rustler::nif(schedule = "DirtyCpu")]
fn light_init(env: Env, region: ResourceArc<Region>, absent: Vec<(i32, i32)>) -> NifResult<Atom> {
    done((|| {
        let facts = LIGHT.get().ok_or(atoms::light_facts_missing())?;
        with_owned(env, &region, |store| {
            store.light_init(facts, &absent).map_err(error)
        })
    })())
}

fn relight(
    env: Env,
    region: &Region,
    positions: &[(i32, i32, i32)],
    budget: Option<usize>,
) -> Result<Vec<Change>, Atom> {
    let facts = LIGHT.get().ok_or(atoms::light_facts_missing())?;
    with_owned(env, region, |store| {
        store
            .light_update(facts, positions, budget)
            .map_err(|TooLarge| atoms::too_large())
    })
}

/// Relight after block changes; returns the region's light changes, or
/// `too_large` (and nothing changed) when it needs more than a normal
/// scheduler allows.
#[rustler::nif]
fn light_update(
    env: Env,
    region: ResourceArc<Region>,
    positions: Vec<(i32, i32, i32)>,
) -> Result<Vec<Change>, Atom> {
    relight(env, &region, &positions, Some(UPDATE_BUDGET))
}

/// The same, unbounded, on a dirty CPU scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn light_update_dirty(
    env: Env,
    region: ResourceArc<Region>,
    positions: Vec<(i32, i32, i32)>,
) -> Result<Vec<Change>, Atom> {
    relight(env, &region, &positions, None)
}

/// A chunk's light image, nil while the chunk is unknown to light; with
/// `sections` (`{sky_bits, block_bits}`) only those layers.
#[rustler::nif]
fn light_image<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    cx: i32,
    cz: i32,
    sections: Option<(u32, u32)>,
) -> Result<Term<'a>, Atom> {
    let image = with_store(&region, |store| {
        store.light_image((cx, cz), sections).map_err(error)
    })?;
    Ok(match image {
        Some(image) => bytes(env, image).encode(env),
        None => rustler::types::atom::nil().encode(env),
    })
}

/// A column image with the light of its chunk lit alone (VMC-077c), which a
/// region adopts when it installs or loads the column.
#[rustler::nif(schedule = "DirtyCpu")]
fn light_column_image<'a>(env: Env<'a>, image: Binary<'a>, sky: bool) -> Result<Binary<'a>, Atom> {
    Ok(match lit_alone(image.as_slice(), sky)? {
        Some(lit) => bytes(env, lit),
        None => image,
    })
}

/// `image` with the light of its chunk lit alone, or None when it has light.
pub(crate) fn lit_alone(image: &[u8], sky: bool) -> Result<Option<Vec<u8>>, Atom> {
    let facts = LIGHT.get().ok_or(atoms::light_facts_missing())?;
    let (column, light) = Column::read_image(image).ok_or(atoms::invalid_layers())?;
    if light.is_some() {
        return Ok(None);
    }
    let light = light_alone(&column.sections, facts, sky);
    Ok(Some(with_light(image, &light)))
}

/// A generated column decoded and checked once (VMC-081c2), with the light
/// its chunk was lit with alone and, from its generation job, its chunk
/// packet's parts: its owner installs it and its neighbours' rings adopt it
/// without decoding, sharing its sections, and its first packet is not
/// encoded again.
pub struct ColumnHandle {
    column: Column,
    light: Option<ChunkLight>,
    prepared: Option<Arc<Prepared>>,
}

#[rustler::resource_impl]
impl rustler::Resource for ColumnHandle {}

fn handle_of(image: &[u8]) -> Result<ColumnHandle, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    let (column, light) = Column::read_image(image).ok_or(atoms::invalid_layers())?;
    if column
        .sections
        .iter()
        .all(|s| s.states_valid(|state| flags.valid(state as u32)))
    {
        Ok(ColumnHandle {
            column,
            light,
            prepared: None,
        })
    } else {
        Err(atoms::invalid_state())
    }
}

/// A column image (with its light, if stored) as a handle to install.
#[rustler::nif]
fn column_handle(image: Binary) -> Result<ResourceArc<ColumnHandle>, Atom> {
    handle_of(image.as_slice()).map(ResourceArc::new)
}

/// `column_handle` on a generation thread (VMC-081c), before queued bulk work;
/// with `packet` (`{cx, cz, spec}`) also the chunk's packet parts.
#[rustler::nif]
fn column_handle_background<'a>(
    env: Env<'a>,
    tag: Term<'a>,
    image: Binary<'a>,
    packet: Option<(i32, i32, PacketSpec)>,
) -> Atom {
    let bytes = image.as_slice().to_vec();
    crate::background::submit(env, tag, true, move || {
        let error = |e| format!("a column image: {e:?}");
        let mut handle = handle_of(&bytes).map_err(error)?;
        if let Some((cx, cz, spec)) = packet {
            let flags = FLAGS.get().ok_or("block facts not installed")?;
            let carriers = CARRIERS.get().ok_or("carrier states not installed")?;
            let prepared = Prepared::new((cx, cz), &handle.column, flags, spec, carriers)
                .map_err(|e| format!("a chunk packet: {e:?}"))?;
            handle.prepared = Some(Arc::new(prepared));
        }
        Ok(ResourceArc::new(handle))
    })
}

/// A ring chunk as a neighbour sends it: a handle, an image (with the light
/// it was stored with, if any) or `flat`.
fn ring_chunk(term: Term) -> Result<(Option<Column>, Option<ChunkLight>), Atom> {
    if let Ok(handle) = term.decode::<ResourceArc<ColumnHandle>>() {
        return Ok((Some(handle.column.clone()), handle.light.clone()));
    }
    match term.decode::<Binary>() {
        Ok(bytes) => {
            let handle = handle_of(bytes.as_slice())?;
            Ok((Some(handle.column), handle.light))
        }
        Err(_) => Ok((None, None)),
    }
}

fn adopt_ring(
    env: Env,
    region: &Region,
    chunks: Vec<(i32, i32, Term)>,
) -> Result<Vec<Change>, Atom> {
    let facts = LIGHT.get().ok_or(atoms::light_facts_missing())?;
    let mut columns = Vec::with_capacity(chunks.len());
    for (cx, cz, term) in chunks {
        let (column, light) = ring_chunk(term)?;
        columns.push(((cx, cz), column, light));
    }
    with_owned(env, region, |store| {
        store.halo_put(facts, columns).map_err(error)
    })
}

/// Adopt ring chunks from a neighbour's column handles or images (or
/// `flat`); returns the region's light changes. Short: a few chunks
/// (`halo_put_dirty` for more).
#[rustler::nif]
fn halo_put(
    env: Env,
    region: ResourceArc<Region>,
    chunks: Vec<(i32, i32, Term)>,
) -> Result<Vec<Change>, Atom> {
    adopt_ring(env, &region, chunks)
}

/// `halo_put` on a dirty scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn halo_put_dirty(
    env: Env,
    region: ResourceArc<Region>,
    chunks: Vec<(i32, i32, Term)>,
) -> Result<Vec<Change>, Atom> {
    adopt_ring(env, &region, chunks)
}

fn install(
    env: Env,
    region: &Region,
    handles: Vec<(i32, i32, ResourceArc<ColumnHandle>)>,
) -> Result<Vec<Change>, Atom> {
    let facts = LIGHT.get().ok_or(atoms::light_facts_missing())?;
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    let columns = handles
        .iter()
        .map(|(cx, cz, h)| ((*cx, *cz), h.column.clone(), h.light.clone()))
        .collect();
    with_owned(env, region, |store| {
        let changes = store.put_columns(facts, flags, columns).map_err(error)?;
        for (cx, cz, h) in &handles {
            if let Some(prepared) = &h.prepared {
                store.prepare((*cx, *cz), prepared.clone());
            }
        }
        Ok(changes)
    })
}

/// Install generated columns (VMC-075) from their handles, all or nothing,
/// with the light they were generated with; returns the region's light
/// changes. Short: a few chunks (`put_columns_dirty` for more).
#[rustler::nif]
fn put_columns(
    env: Env,
    region: ResourceArc<Region>,
    handles: Vec<(i32, i32, ResourceArc<ColumnHandle>)>,
) -> Result<Vec<Change>, Atom> {
    install(env, &region, handles)
}

/// `put_columns` on a dirty scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn put_columns_dirty(
    env: Env,
    region: ResourceArc<Region>,
    handles: Vec<(i32, i32, ResourceArc<ColumnHandle>)>,
) -> Result<Vec<Change>, Atom> {
    install(env, &region, handles)
}

/// Apply a neighbour's block changes to known ring chunks; returns the
/// positions applied, to relight.
#[rustler::nif]
fn halo_set(
    env: Env,
    region: ResourceArc<Region>,
    edits: Vec<(i32, i32, i32, u32)>,
) -> Result<Vec<(i32, i32, i32)>, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    if edits.len() > 4096 || edits.iter().any(|e| !flags.valid(e.3)) {
        return Err(atoms::invalid_state());
    }
    let edits: Vec<(i32, i32, i32, u16)> = edits
        .into_iter()
        .map(|(x, y, z, s)| (x, y, z, s as u16))
        .collect();
    with_owned(env, &region, |store| Ok(store.halo_set(&edits)))
}
