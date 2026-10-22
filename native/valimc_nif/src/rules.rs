//! The block rules over the Region resource (VMC-077m): `rules_new` parses
//! them once; `block_updates` runs the updates a batch of block changes in a
//! section starts, its actions (buckets, post-processing marks, VMC-031a),
//! the due ticks of its dependent blocks and its due fluid ticks, reading its
//! store and its group's other sections' (`siblings`, VMC-077j) without
//! changing them (a normal NIF and its dirty twin,
//! `Valimc.Native.dispatch/3`). A cascade's cost is not bounded by its input:
//! on a normal scheduler the run stops after `NORMAL_BUDGET` updates and
//! answers `{:error, :too_large}` for the caller to run it dirty.
//!
//! `changes` and `ticks` are packed `<<x::32, y::32, z::32, state::16>>`
//! records (signed coordinates): a changed cell with its old state, a due tick
//! with its state; `fluid_ticks` `<<x, y, z, fluid::8>>`; `actions`
//! `<<kind::8, x, y, z, fluid::8, flags::8, rx, ry, rz>>` (kind 0 a bucket
//! emptied, 1 a pickup, 2 a post-processing mark; flags bit 0 a retry cell,
//! bit 1 sneaking); `options` the fluid settings' bits (`Options::from_bits`).
//! The reply is `{:ok, {{changes, destroyed, ticks, fluid_ticks, events,
//! results}, {stopped, skipped, updates}}}`: `changes` packs `<<x, y, z,
//! state::16>>` (final states, in the order they first changed), `destroyed`
//! `<<x, y, z, state::16, flags::8>>` (bit 0: its loot drops; bit 1: it breaks
//! with particles and sound), `ticks` `<<x, y, z, block::16, delay::32>>`,
//! `fluid_ticks` `<<x, y, z, fluid::8, delay::32>>`, `events` `<<x, y, z,
//! type::32, data::32>>`, each in any of the group's sections, and `results`
//! one integer per action (`live::Outcome::results`); the counts are updates
//! dropped at the group's edge, past the chain limit and run.

use crate::region::Region;
use crate::{atoms, binary, reply};
use rustler::{Atom, Binary, Env, NifResult, ResourceArc, Term};
use std::collections::HashSet;
use std::sync::Arc;
use std::sync::MutexGuard;
use valimc_core::column::ColumnStore;
use valimc_core::rules::fluid::Options;
use valimc_core::rules::live::{Action, Input};
use valimc_core::rules::Rules;
use valimc_core::worldgen::random::Random;

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
            rules: Arc::new(Rules::parse(&json, states, crate::facts::PHYSICS.get())?),
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

fn fluid_records(packed: &[u8]) -> Result<Vec<([i32; 3], u8)>, Atom> {
    let (records, rest) = packed.as_chunks::<13>();
    if !rest.is_empty() {
        return Err(atoms::invalid_positions());
    }
    Ok(records
        .iter()
        .map(|r| (position(&r[0..12]), r[12]))
        .collect())
}

fn position(bytes: &[u8]) -> [i32; 3] {
    let at = |i: usize| i32::from_be_bytes([bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]]);
    [at(0), at(4), at(8)]
}

pub(crate) fn actions(packed: &[u8]) -> Result<Vec<Action>, Atom> {
    let (records, rest) = packed.as_chunks::<27>();
    if !rest.is_empty() {
        return Err(atoms::invalid_positions());
    }
    records
        .iter()
        .map(|r| {
            let pos = position(&r[1..13]);
            Ok(match r[0] {
                0 => Action::Empty {
                    pos,
                    kind: r[13],
                    retry: (r[14] & 1 == 1).then(|| position(&r[15..27])),
                    secondary: r[14] & 2 == 2,
                },
                1 => Action::Pickup { pos },
                2 => Action::PostProcess { pos },
                _ => return Err(atoms::invalid_positions()),
            })
        })
        .collect()
}

fn put_position(out: &mut Vec<u8>, pos: [i32; 3]) {
    for coordinate in pos {
        out.extend_from_slice(&coordinate.to_be_bytes());
    }
}

type Updated<'a> = (
    (
        Binary<'a>,
        Binary<'a>,
        Binary<'a>,
        Binary<'a>,
        Binary<'a>,
        Vec<i32>,
    ),
    (u64, u64, u64),
);

/// A run's packed inputs.
pub(crate) struct Packed<'a> {
    changes: Binary<'a>,
    ticks: Binary<'a>,
    fluid_ticks: Binary<'a>,
    actions: Binary<'a>,
    options: u32,
}

/// The first of `states` that can survive at `position` in a section, read
/// with its group's other sections (placement's `canSurvive`), or `nil`.
#[rustler::nif]
fn block_first_surviving(
    region: ResourceArc<Region>,
    siblings: Vec<ResourceArc<Region>>,
    rules: ResourceArc<BlockRules>,
    position: (i32, i32, i32),
    states: Vec<u16>,
    absent: Vec<(i32, i32)>,
) -> Result<Option<u16>, Atom> {
    let (x, y, z) = position;
    let absent: HashSet<(i32, i32)> = absent.into_iter().collect();
    let guards = lock_group(&region, &siblings)?;
    let stores: Vec<&ColumnStore> = guards.iter().map(|guard| &**guard).collect();
    valimc_core::rules::live::first_surviving(&rules.rules, &stores, &absent, [x, y, z], &states)
        .map_err(|_| atoms::invalid_state())
}

/// The stores of a section and its group's others, locked. Every lock is the
/// calling group's own: only it runs its sections' rules, and readers take
/// one store at a time. A store named twice is locked once.
fn lock_group<'r>(
    region: &'r Region,
    siblings: &'r [ResourceArc<Region>],
) -> Result<Vec<MutexGuard<'r, ColumnStore>>, Atom> {
    let mut regions: Vec<&Region> = vec![region];
    for sibling in siblings {
        if !regions.iter().any(|r| std::ptr::eq(*r, &**sibling)) {
            regions.push(sibling);
        }
    }
    regions
        .iter()
        .map(|region| region.store.lock().map_err(|_| atoms::poisoned()))
        .collect()
}

/// Updates a normal-scheduler run may take: about 0.4 ms at the engine's
/// slowest rate (redstone cascades, about 5 million a second), under 1 ms
/// while a loaded host halves it.
const NORMAL_BUDGET: u64 = 2_048;

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn block_updates<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    siblings: Vec<ResourceArc<Region>>,
    rules: ResourceArc<BlockRules>,
    changes: Binary<'a>,
    ticks: Binary<'a>,
    fluid_ticks: Binary<'a>,
    actions: Binary<'a>,
    absent: Vec<(i32, i32)>,
    seed: i64,
    options: u32,
) -> Result<Updated<'a>, Atom> {
    let packed = Packed {
        changes,
        ticks,
        fluid_ticks,
        actions,
        options,
    };
    updates(
        env,
        &region,
        &siblings,
        &rules.rules,
        &packed,
        absent,
        seed,
        Some(NORMAL_BUDGET),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn block_updates_dirty<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    siblings: Vec<ResourceArc<Region>>,
    rules: ResourceArc<BlockRules>,
    changes: Binary<'a>,
    ticks: Binary<'a>,
    fluid_ticks: Binary<'a>,
    actions: Binary<'a>,
    absent: Vec<(i32, i32)>,
    seed: i64,
    options: u32,
) -> Result<Updated<'a>, Atom> {
    let packed = Packed {
        changes,
        ticks,
        fluid_ticks,
        actions,
        options,
    };
    updates(
        env,
        &region,
        &siblings,
        &rules.rules,
        &packed,
        absent,
        seed,
        None,
    )
}

#[allow(clippy::too_many_arguments)]
fn updates<'a>(
    env: Env<'a>,
    region: &Region,
    siblings: &[ResourceArc<Region>],
    rules: &Rules,
    packed: &Packed,
    absent: Vec<(i32, i32)>,
    seed: i64,
    budget: Option<u64>,
) -> Result<Updated<'a>, Atom> {
    let changes = records(packed.changes.as_slice())?;
    let ticks = records(packed.ticks.as_slice())?;
    let fluid_ticks = fluid_records(packed.fluid_ticks.as_slice())?;
    let actions = actions(packed.actions.as_slice())?;
    let absent: HashSet<(i32, i32)> = absent.into_iter().collect();
    let guards = lock_group(region, siblings)?;
    let stores: Vec<&ColumnStore> = guards.iter().map(|guard| &**guard).collect();
    let input = Input {
        changes: &changes,
        actions: &actions,
        ticks: &ticks,
        fluid_ticks: &fluid_ticks,
        options: Options::from_bits(packed.options),
    };
    let mut random = Random::legacy(seed);
    let outcome =
        valimc_core::rules::live::run(rules, &stores, &absent, &input, &mut random, budget)
            .map_err(|_| atoms::invalid_state())?
            .ok_or(atoms::too_large())?;
    Ok(encode(env, &outcome))
}

/// A run's outcome as the reply packs it.
pub(crate) fn encode<'a>(env: Env<'a>, outcome: &valimc_core::rules::live::Outcome) -> Updated<'a> {
    let mut changed = Vec::with_capacity(outcome.changes.len() * 14);
    for (pos, state) in &outcome.changes {
        put_position(&mut changed, *pos);
        changed.extend_from_slice(&state.to_be_bytes());
    }
    let mut destroyed = Vec::with_capacity(outcome.report.destroyed.len() * 15);
    for block in &outcome.report.destroyed {
        put_position(&mut destroyed, block.pos);
        destroyed.extend_from_slice(&block.state.to_be_bytes());
        destroyed.push(u8::from(block.drops) | u8::from(block.effects) << 1);
    }
    let mut scheduled = Vec::with_capacity(outcome.block_ticks.len() * 18);
    for (pos, block, delay) in &outcome.block_ticks {
        put_position(&mut scheduled, *pos);
        scheduled.extend_from_slice(&block.to_be_bytes());
        scheduled.extend_from_slice(&delay.to_be_bytes());
    }
    let mut fluid = Vec::with_capacity(outcome.fluid_ticks.len() * 17);
    for (pos, kind, delay) in &outcome.fluid_ticks {
        put_position(&mut fluid, *pos);
        fluid.push(*kind);
        fluid.extend_from_slice(&delay.to_be_bytes());
    }
    let mut events = Vec::with_capacity(outcome.report.events.len() * 20);
    for (pos, kind, data) in &outcome.report.events {
        put_position(&mut events, *pos);
        events.extend_from_slice(&kind.to_be_bytes());
        events.extend_from_slice(&data.to_be_bytes());
    }
    (
        (
            binary(env, &changed),
            binary(env, &destroyed),
            binary(env, &scheduled),
            binary(env, &fluid),
            binary(env, &events),
            outcome.results.clone(),
        ),
        (
            outcome.report.stopped,
            outcome.report.skipped,
            outcome.report.updates,
        ),
    )
}
