//! Block and sky light over the Region resource, chunk by chunk (VMC-077c).

use crate::facts::{FLAGS, LIGHT};
use crate::region::{error, with_owned, with_store, Region};
use crate::{atoms, bytes, done};
use rustler::{Atom, Binary, Encoder, Env, NifResult, ResourceArc, Term};
use valimc_core::column::{with_light, Column};
use valimc_core::light_grid::{light_alone, TooLarge};

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

fn valid_column(bytes: &[u8]) -> Result<Column, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    let column = Column::from_image(bytes).ok_or(atoms::invalid_layers())?;
    let mut valid = true;
    for storage in &column.sections {
        storage.for_each(|_, state| valid &= flags.valid(state as u32));
    }
    if valid {
        Ok(column)
    } else {
        Err(atoms::invalid_state())
    }
}

/// Adopt ring chunks from a neighbour's column images (or `flat`); returns the
/// region's light changes.
#[rustler::nif(schedule = "DirtyCpu")]
fn halo_put(
    env: Env,
    region: ResourceArc<Region>,
    chunks: Vec<(i32, i32, Term)>,
) -> Result<Vec<Change>, Atom> {
    let facts = LIGHT.get().ok_or(atoms::light_facts_missing())?;
    let mut columns = Vec::with_capacity(chunks.len());
    for (cx, cz, image) in chunks {
        let column = match image.decode::<Binary>() {
            Ok(bytes) => Some(valid_column(bytes.as_slice())?),
            Err(_) => None,
        };
        columns.push(((cx, cz), column));
    }
    with_owned(env, &region, |store| {
        store.halo_put(facts, columns).map_err(error)
    })
}

/// Install generated columns (VMC-075) from their images, all or nothing, with
/// the light they were generated with; returns the region's light changes.
#[rustler::nif(schedule = "DirtyCpu")]
fn put_columns_lit(
    env: Env,
    region: ResourceArc<Region>,
    images: Vec<(i32, i32, Binary)>,
) -> Result<Vec<Change>, Atom> {
    let facts = LIGHT.get().ok_or(atoms::light_facts_missing())?;
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    let mut columns = Vec::with_capacity(images.len());
    for (cx, cz, image) in images {
        let (column, light) = Column::read_image(image.as_slice()).ok_or(atoms::invalid_layers())?;
        columns.push(((cx, cz), column, light));
    }
    with_owned(env, &region, |store| {
        store.put_columns(facts, flags, columns).map_err(error)
    })
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
