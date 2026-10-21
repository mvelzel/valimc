//! The block fact table (VMC-077d), installed once per VM by
//! `Valimc.Registry.BlockFacts.install!`: the storage flags, the light facts
//! and the per-state facts worldgen's block table reads all come from it.

use crate::{atoms, done};
use rustler::{Atom, Binary, NifMap, NifResult};
use std::sync::OnceLock;
use valimc_core::light::LightFacts;
use valimc_core::{BlockFlags, StateFacts};

pub(crate) static FLAGS: OnceLock<BlockFlags> = OnceLock::new();
pub(crate) static LIGHT: OnceLock<LightFacts> = OnceLock::new();
pub(crate) static STATES: OnceLock<StateFacts> = OnceLock::new();

/// The table's columns: `flags` and `signal` are eight big-endian bytes per
/// state, `fluid_remains` two, the others one byte per state; the light faces and sky carry their class counts
/// and pair tables.
#[derive(NifMap)]
struct Columns<'a> {
    flags: Binary<'a>,
    heightmaps: Binary<'a>,
    fluid: Binary<'a>,
    fluid_level: Binary<'a>,
    fluid_remains: Binary<'a>,
    signal: Binary<'a>,
    light: Binary<'a>,
    light_faces: Vec<Binary<'a>>,
    light_classes: Vec<usize>,
    light_occludes: Vec<Binary<'a>>,
    sky: Binary<'a>,
    sky_classes: usize,
    sky_pairs: Binary<'a>,
}

/// Install the facts; a second install of the same table is a no-op.
#[rustler::nif]
fn block_facts_init(columns: Columns) -> NifResult<Atom> {
    done(install(&columns))
}

fn install(columns: &Columns) -> Result<(), Atom> {
    if let Some(installed) = STATES.get() {
        return if installed.state_count() == columns.heightmaps.len() {
            Ok(())
        } else {
            Err(atoms::flags_mismatch())
        };
    }
    let faces = &columns.light_faces;
    let (classes, occludes) = (&columns.light_classes, &columns.light_occludes);
    if !columns.flags.len().is_multiple_of(8)
        || !columns.signal.len().is_multiple_of(8)
        || faces.len() != 6
        || classes.len() != 6
        || occludes.len() != 6
    {
        return Err(atoms::invalid_state());
    }
    let words = |column: &Binary| {
        column
            .as_slice()
            .as_chunks::<8>()
            .0
            .iter()
            .map(|&word| u64::from_be_bytes(word))
            .collect()
    };
    let flags = words(&columns.flags);
    let states = StateFacts::new(
        flags,
        columns.heightmaps.as_slice().to_vec(),
        columns.fluid.as_slice().to_vec(),
        columns.fluid_level.as_slice().to_vec(),
        columns
            .fluid_remains
            .as_slice()
            .as_chunks::<2>()
            .0
            .iter()
            .map(|&pair| u16::from_be_bytes(pair))
            .collect(),
        words(&columns.signal),
    )
    .ok_or(atoms::invalid_state())?;
    let light = LightFacts::new(
        columns.light.as_slice().to_vec(),
        std::array::from_fn(|d| faces[d].as_slice().to_vec()),
        std::array::from_fn(|d| classes[d]),
        std::array::from_fn(|d| occludes[d].as_slice().to_vec()),
        columns.sky.as_slice().to_vec(),
        columns.sky_classes,
        columns.sky_pairs.as_slice().to_vec(),
    )
    .ok_or(atoms::invalid_state())?;
    if light.state_count() != states.state_count() {
        return Err(atoms::invalid_state());
    }
    FLAGS.get_or_init(|| states.storage_flags());
    LIGHT.get_or_init(|| light);
    STATES.get_or_init(|| states);
    Ok(())
}
