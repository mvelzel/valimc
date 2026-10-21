//! Block and sky light over the Region resource.

use crate::region::{error, with_store, Region, FLAGS};
use crate::{atoms, binary};
use rustler::{Atom, Binary, Encoder, Env, ResourceArc, Term};
use std::sync::OnceLock;

pub(crate) static LIGHT: OnceLock<valimc_core::light::LightFacts> = OnceLock::new();

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

/// Whether the region's dimension has sky light (VMC-026b); set before lighting.
#[rustler::nif]
fn light_sky(region: ResourceArc<Region>, sky: bool) -> Result<Atom, Atom> {
    with_store(&region, |store| {
        store.sky = sky;
        Ok(atoms::ok())
    })
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

/// Install generated columns (VMC-075) from their images, all or nothing, and
/// relight once; returns the region's chunks whose light changed.
#[rustler::nif(schedule = "DirtyCpu")]
fn put_columns_lit(
    region: ResourceArc<Region>,
    images: Vec<(i32, i32, Binary)>,
) -> Result<Vec<(i32, i32)>, Atom> {
    let facts = LIGHT.get().ok_or(atoms::flags_missing())?;
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    let mut columns = Vec::with_capacity(images.len());
    for (cx, cz, image) in images {
        let column = valimc_core::column::Column::from_image(image.as_slice())
            .ok_or(atoms::invalid_layers())?;
        columns.push(((cx, cz), column));
    }
    with_store(&region, |store| {
        store.put_columns(facts, flags, columns).map_err(error)
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
