//! The block rules over the Region resource (VMC-077m): `rules_new` parses
//! them once; `block_updates` runs the updates a batch of block changes starts
//! and the due ticks of dependent blocks, reading the owner's store without
//! changing it (a normal NIF and its dirty twin, `Valimc.Native.dispatch/3`).
//!
//! `changes` and `ticks` are packed `<<x::32, y::32, z::32, state::16>>`
//! records (signed coordinates): a changed cell with its old state, a due tick
//! with its state. The reply is `{:ok, {changes, destroyed, ticks, stopped,
//! skipped}}`: `changes` packs `<<x, y, z, state::16>>` (final states, in the
//! order they first changed), `destroyed` `<<x, y, z, state::16, drops::8>>`,
//! `ticks` `<<x, y, z, block::16, delay::32>>`; the counts are updates dropped
//! at the region's border and past the chain limit.

use crate::region::{with_store, Region};
use crate::{atoms, binary, reply};
use rustler::{Atom, Binary, Env, NifResult, ResourceArc, Term};
use std::collections::HashSet;
use std::sync::Arc;
use valimc_core::rules::Rules;

pub struct BlockRules {
    pub(crate) rules: Arc<Rules>,
}

#[rustler::resource_impl]
impl rustler::Resource for BlockRules {}

/// The rules from their facts (`Rules::parse`); the block facts must be
/// installed.
#[rustler::nif(schedule = "DirtyCpu")]
fn rules_new(facts: Term) -> NifResult<(Atom, ResourceArc<BlockRules>)> {
    reply((|| {
        let json = crate::worldgen::json_of(facts)?;
        let states = crate::facts::STATES
            .get()
            .ok_or("block facts not installed")?;
        Ok(ResourceArc::new(BlockRules {
            rules: Arc::new(Rules::parse(&json, states)?),
        }))
    })())
}

fn records(packed: &[u8]) -> Result<Vec<([i32; 3], u16)>, Atom> {
    let (records, rest) = packed.as_chunks::<14>();
    if !rest.is_empty() {
        return Err(atoms::invalid_positions());
    }
    Ok(records
        .iter()
        .map(|r| {
            let at = |i: usize| i32::from_be_bytes([r[i], r[i + 1], r[i + 2], r[i + 3]]);
            ([at(0), at(4), at(8)], u16::from_be_bytes([r[12], r[13]]))
        })
        .collect())
}

fn put_position(out: &mut Vec<u8>, pos: [i32; 3]) {
    for coordinate in pos {
        out.extend_from_slice(&coordinate.to_be_bytes());
    }
}

type Updated<'a> = (Binary<'a>, Binary<'a>, Binary<'a>, u64, u64);

#[rustler::nif]
fn block_updates<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    rules: ResourceArc<BlockRules>,
    changes: Binary,
    ticks: Binary,
    absent: Vec<(i32, i32)>,
    seed: u64,
) -> Result<Updated<'a>, Atom> {
    updates(env, &region, &rules.rules, changes, ticks, absent, seed)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn block_updates_dirty<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    rules: ResourceArc<BlockRules>,
    changes: Binary,
    ticks: Binary,
    absent: Vec<(i32, i32)>,
    seed: u64,
) -> Result<Updated<'a>, Atom> {
    updates(env, &region, &rules.rules, changes, ticks, absent, seed)
}

fn updates<'a>(
    env: Env<'a>,
    region: &Region,
    rules: &Rules,
    changes: Binary,
    ticks: Binary,
    absent: Vec<(i32, i32)>,
    seed: u64,
) -> Result<Updated<'a>, Atom> {
    let changes = records(changes.as_slice())?;
    let ticks = records(ticks.as_slice())?;
    let absent: HashSet<(i32, i32)> = absent.into_iter().collect();
    let outcome = with_store(region, |store| {
        valimc_core::rules::live::run(rules, store, &absent, &changes, &ticks, seed)
            .map_err(|_| atoms::invalid_state())
    })?;
    let mut changed = Vec::with_capacity(outcome.changes.len() * 14);
    for (pos, state) in &outcome.changes {
        put_position(&mut changed, *pos);
        changed.extend_from_slice(&state.to_be_bytes());
    }
    let mut destroyed = Vec::with_capacity(outcome.report.destroyed.len() * 15);
    for (pos, state, drops) in &outcome.report.destroyed {
        put_position(&mut destroyed, *pos);
        destroyed.extend_from_slice(&state.to_be_bytes());
        destroyed.push(u8::from(*drops));
    }
    let mut scheduled = Vec::with_capacity(outcome.block_ticks.len() * 18);
    for (pos, block, delay) in &outcome.block_ticks {
        put_position(&mut scheduled, *pos);
        scheduled.extend_from_slice(&block.to_be_bytes());
        scheduled.extend_from_slice(&delay.to_be_bytes());
    }
    Ok((
        binary(env, &changed),
        binary(env, &destroyed),
        binary(env, &scheduled),
        outcome.report.stopped,
        outcome.report.skipped,
    ))
}
