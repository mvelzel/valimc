//! Published chunk snapshots (VMC-077p, `valimc_core::snapshot`) as
//! resources: a region owner publishes one per chunk into its table after
//! each commit that changes the chunk, and any process reads it without a
//! lock or a copy. A snapshot shares its sections with the owner's store,
//! which clones a section only when it writes it, so republishing costs work
//! for the sections that changed, not for the chunk. Readers pass handles
//! back in batches (`World.View`, the physics kernel) and nothing is decoded.

use crate::atoms;
use crate::facts::{FLAGS, LIGHT};
use crate::region::{error, packed_blocks, with_store, Region};
use rustler::{Atom, Binary, Env, NewBinary, NifResult, ResourceArc, Term};
use std::collections::HashMap;
use valimc_core::flags::AIR;
use valimc_core::snapshot::ChunkSnapshot;

pub struct Snapshot(pub ChunkSnapshot);

#[rustler::resource_impl]
impl rustler::Resource for Snapshot {}

/// Publish `chunks` (`{cx, cz, previous}`, `previous` the chunk's last
/// handle or nil) of the region at `revision`: one handle per chunk, in
/// order. Sections the previous handle still shares keep its revision.
#[rustler::nif]
fn snapshot_publish(
    region: ResourceArc<Region>,
    chunks: Vec<(i32, i32, Option<&Snapshot>)>,
    revision: u64,
) -> Result<Vec<ResourceArc<Snapshot>>, Atom> {
    let handles: Vec<ResourceArc<Snapshot>> = with_store(&region, |store| {
        chunks
            .iter()
            .map(|&(cx, cz, previous)| {
                store
                    .snapshot((cx, cz), revision, previous.map(|p| &p.0))
                    .map(|s| ResourceArc::new(Snapshot(s)))
                    .map_err(error)
            })
            .collect()
    })?;
    // The region keeps what it published for its native mob sections.
    if let Ok(mut published) = region.published.lock() {
        published.revision += 1;
        for (&(cx, cz, _), handle) in chunks.iter().zip(&handles) {
            published.chunks.insert((cx, cz), handle.clone());
        }
    }
    Ok(handles)
}

/// The state at a position of the handle's chunk, nil outside the stored height.
#[rustler::nif]
fn snapshot_get(snapshot: &Snapshot, x: i32, y: i32, z: i32) -> Option<u16> {
    snapshot.0.get(x, y, z)
}

/// The states at packed positions (`<<x::32, y::32, z::32>>` each) as
/// big-endian u16s, read from `snapshots` (any chunks); `outside` outside the
/// stored height and 65535 in a chunk none of them holds.
#[rustler::nif]
fn snapshot_blocks<'a>(
    env: Env<'a>,
    snapshots: Vec<&'a Snapshot>,
    positions: Binary<'a>,
    outside: u16,
) -> NifResult<Binary<'a>> {
    let (records, rest) = positions.as_slice().as_chunks::<12>();
    if !rest.is_empty() {
        return Err(rustler::Error::BadArg);
    }
    let by_chunk: HashMap<(i32, i32), &ChunkSnapshot> =
        snapshots.iter().map(|s| (s.0.chunk, &s.0)).collect();
    let mut out = NewBinary::new(env, records.len() * 2);
    for (state, r) in out
        .as_mut_slice()
        .as_chunks_mut::<2>()
        .0
        .iter_mut()
        .zip(records)
    {
        let at = |i: usize| i32::from_be_bytes([r[i], r[i + 1], r[i + 2], r[i + 3]]);
        let (x, y, z) = (at(0), at(4), at(8));
        let read = match by_chunk.get(&(x >> 4, z >> 4)) {
            Some(s) => s.get(x, y, z).unwrap_or(outside),
            None => u16::MAX,
        };
        *state = read.to_be_bytes();
    }
    Ok(out.into())
}

/// Column `(x, z)`'s MOTION_BLOCKING height and lowest sky source (absolute
/// y, the build bottom when none), computed from the snapshot's sections.
#[rustler::nif]
fn snapshot_column(snapshot: &Snapshot, x: i32, z: i32) -> Result<(i32, i32), Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    let light = LIGHT.get().ok_or(atoms::light_facts_missing())?;
    Ok(snapshot.0.column(x, z, flags, light))
}

/// The stored biome of quart `(qx, qy, qz)`, nil for a column without biomes.
#[rustler::nif]
fn snapshot_biome(snapshot: &Snapshot, qx: i32, qy: i32, qz: i32) -> Option<u16> {
    snapshot.0.biome((qx, qy, qz))
}

/// Blocks of the chunk whose state is in `states`, as packed `{x, y, z,
/// state}` records.
#[rustler::nif]
fn snapshot_find<'a>(env: Env<'a>, snapshot: &Snapshot, states: Vec<u16>) -> Binary<'a> {
    packed_blocks(env, &snapshot.0.find(&states))
}

/// The highest stored section (bottom 0) below `below` holding a state
/// other than air (`getHighestFilledSectionIndex`), nil if none does.
#[rustler::nif]
fn snapshot_highest_filled(snapshot: &Snapshot, below: usize) -> Result<Option<usize>, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    Ok(snapshot
        .0
        .highest_filled(below, |s| flags.get(s) & AIR != 0))
}

/// `{revision, section_revisions}`: the publication's revision and, per
/// section bottom first, the revision of the publication that last changed it.
#[rustler::nif]
fn snapshot_revisions<'a>(env: Env<'a>, snapshot: &Snapshot) -> Term<'a> {
    use rustler::Encoder;
    (snapshot.0.revision, snapshot.0.revisions.to_vec()).encode(env)
}

/// The resident block memory of the region's store and `snapshots`, shared
/// sections counted once (measurements).
#[cfg(feature = "parity")]
#[rustler::nif]
fn snapshot_resident(
    region: ResourceArc<Region>,
    snapshots: Vec<&Snapshot>,
) -> Result<usize, Atom> {
    with_store(&region, |store| {
        Ok(valimc_core::snapshot::resident_bytes(
            store.all_columns(),
            snapshots.iter().map(|s| &s.0),
        ))
    })
}
