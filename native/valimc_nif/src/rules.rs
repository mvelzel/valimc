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
//! `<<kind::8, x, y, z, value::8, flags::8, rx, ry, rz>>` (kind 0 a bucket
//! emptied, 1 a pickup, 2 a post-processing mark, 3 a random tick (flags
//! bit 0: lava's fire spreads; bit 1: it rains above, VMC-039a), VMC-047a's
//! 4 a use (value: the player's facing; flags bit 0: it
//! may build), 5 the entities' contacts, 6 a daylight detector's update, 7 a
//! lectern's page, 8 a target's hit (value: its power; flags bit 0: an
//! arrow's), 9 a tripwire hook placed, 10 tripwire disarmed, VMC-039a's 11
//! bone meal (value: the clicked face, 255 none; flags bit 0: corals grow,
//! VMC-039b), 12 a tool's transformer (value: the tool; flags: the clicked
//! face), 13 farmland trampled, 14 a block entity's output changed
//! (VMC-048a) and 15 berries picked (VMC-039b); for buckets the value is the
//! fluid, flags bit 0 a retry cell,
//! bit 1 sneaking); `options` the level's settings' bits (`Options::from_bits`);
//! `redstone` the redstone context: `<<time::64, day::64, rain::float-32,
//! thunder::float-32, n::32, toggles (x, y, z, when::64)..., n::32,
//! entities (min x, y, z, max x, y, z as float-64, kind::8)..., n::32,
//! pending ticks (x, y, z, block::16)...>>` (`day` the overworld clock's
//! ticks and the weather's levels, which daylight detectors read).
//! The reply is `{:ok, {{changes, destroyed, ticks, fluid_ticks, events,
//! results}, {stopped, skipped, updates}, {sounds, block_events, primed,
//! toggles, outputs, dispensed}, ...}}`: `changes` packs `<<x, y, z,
//! state::16>>` (final states, in the order they first changed), `destroyed`
//! `<<x, y, z, state::16, flags::8>>` (bit 0: its loot drops; bit 1: it breaks
//! with particles and sound), `ticks` `<<x, y, z, block::16, delay::32>>`,
//! `fluid_ticks` `<<x, y, z, fluid::8, delay::32>>`, `events` `<<x, y, z,
//! type::32, data::32>>`, each in any of the group's sections, and `results`
//! one integer per action (`live::Outcome::results`); the counts are updates
//! dropped at the group's edge, past the chain limit and run. `sounds` packs
//! `<<x, y, z as float-64, sound::16, volume::float-32, pitch::float-32,
//! actor::8>>`, `block_events` `<<x, y, z, block::16, b0::32, b1::32>>`,
//! `primed` and `dispensed` (VMC-049a) `<<x, y, z>>` and `toggles` as given.
//! `random` (VMC-081g1, `random_phase`) adds the tick's random ticks after
//! the fluid ticks; the reply's last pair packs the draws the owner ticks
//! (`<<x, y, z, state::16>>`) and the plants that grow what the generator
//! grows (`<<x, y, z>>`).

use crate::region::Region;
use crate::{atoms, binary, reply};
use rustler::{Atom, Binary, Env, NifResult, ResourceArc, Term};
use std::collections::HashSet;
use std::sync::Arc;
use std::sync::MutexGuard;
use valimc_core::column::ColumnStore;
use valimc_core::random_tick::RandomTicks;
use valimc_core::rules::components::{EntityBox, EntityKind};
use valimc_core::rules::fluid::Options;
use valimc_core::rules::live::{Action, Input, RandomPhase};
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
                3 => Action::RandomTick {
                    pos,
                    fire: r[14] & 1 == 1,
                    rain: r[14] & 2 == 2,
                },
                4 => Action::Use {
                    pos,
                    facing: (r[13] as usize).min(5),
                    may_build: r[14] & 1 == 1,
                },
                5 => Action::Contacts,
                6 => Action::Daylight { pos },
                7 => Action::Page { pos },
                8 => Action::Hit {
                    pos,
                    power: r[13] as i32,
                    arrow: r[14] & 1 == 1,
                },
                9 => Action::Placed { pos },
                10 => Action::Disarm { pos },
                11 => Action::BoneMeal {
                    pos,
                    face: (r[13] < 6).then_some(r[13] as usize),
                    corals: r[14] & 1 == 1,
                },
                12 => Action::Transform {
                    pos,
                    tool: r[13] as usize,
                    face: r[14] as usize,
                },
                13 => Action::Trample { pos },
                14 => Action::OutputChanged { pos },
                15 => Action::Harvest { pos },
                // A mob's edit: `from` and `to` (0xFFFF: destroyed), then the
                // event's data (-1: none), big-endian, and its flags (1:
                // neighbour updates, 2: only where it survives, 4: drop loot).
                16 => {
                    let from = u16::from_be_bytes([r[15], r[16]]);
                    let to = u16::from_be_bytes([r[17], r[18]]);
                    let event = i32::from_be_bytes([r[19], r[20], r[21], r[22]]);
                    Action::Edit {
                        pos,
                        from,
                        to: (to != u16::MAX).then_some(to),
                        event: (event >= 0).then_some(event),
                        flags: r[23],
                    }
                }
                17 => Action::Moving { pos },
                18 => Action::Shear {
                    pos,
                    facing: r[13] as usize,
                },
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
    (
        Binary<'a>,
        Binary<'a>,
        Binary<'a>,
        Binary<'a>,
        Binary<'a>,
        Binary<'a>,
    ),
    (
        Binary<'a>,
        Binary<'a>,
        Binary<'a>,
        Binary<'a>,
        Binary<'a>,
        Binary<'a>,
    ),
    (Binary<'a>, Binary<'a>),
);

/// A run's packed inputs.
pub(crate) struct Packed<'a> {
    changes: Binary<'a>,
    ticks: Binary<'a>,
    fluid_ticks: Binary<'a>,
    actions: Binary<'a>,
    options: u32,
    redstone: Binary<'a>,
    random: Binary<'a>,
}

/// The tick's random phase (VMC-081g1): `<<per_section::32, mask::64,
/// radius::32, wet::8, n::32, players (x, y, z as float-64)...>>`, none when
/// empty.
fn random_phase(packed: &[u8]) -> Result<Option<RandomPhase>, Atom> {
    if packed.is_empty() {
        return Ok(None);
    }
    let mut r = Reader(packed);
    let per_section = r.i32()?;
    let mask = r.i64()? as u64;
    let radius = r.i32()?;
    let wet = r.take::<1>()?[0] != 0;
    let mut players = Vec::new();
    for _ in 0..r.count(24)? {
        players.push([r.f64()?, r.f64()?, r.f64()?]);
    }
    if !r.0.is_empty() || !(0..=4096).contains(&per_section) {
        return Err(atoms::invalid_positions());
    }
    Ok(Some(RandomPhase {
        per_section: per_section as u32,
        mask,
        players,
        radius,
        wet,
    }))
}

/// The redstone context of a run (VMC-047a), unpacked.
#[derive(Default)]
struct Context {
    time: i64,
    day: i64,
    rain: f32,
    thunder: f32,
    toggles: Vec<([i32; 3], i64)>,
    entities: Vec<EntityBox>,
    pending: Vec<([i32; 3], u16)>,
    /// Comparators' outputs and the owner's containers' signals (VMC-048a).
    outputs: Vec<([i32; 3], i32)>,
    containers: Vec<([i32; 3], i32)>,
    /// Pistons' part (VMC-048b), when the context carries it.
    events: Vec<valimc_core::rules::piston::Event>,
    run_events: bool,
    handling_tick: bool,
    order: i64,
    border: Option<[f64; 4]>,
    build: Option<(i32, i32)>,
}

/// A reader over a packed binary that fails past its end.
struct Reader<'b>(&'b [u8]);

impl Reader<'_> {
    fn take<const N: usize>(&mut self) -> Result<[u8; N], Atom> {
        let (head, rest) = self
            .0
            .split_first_chunk::<N>()
            .ok_or(atoms::invalid_positions())?;
        self.0 = rest;
        Ok(*head)
    }
    fn i32(&mut self) -> Result<i32, Atom> {
        Ok(i32::from_be_bytes(self.take()?))
    }
    fn i64(&mut self) -> Result<i64, Atom> {
        Ok(i64::from_be_bytes(self.take()?))
    }
    fn f64(&mut self) -> Result<f64, Atom> {
        Ok(f64::from_be_bytes(self.take()?))
    }
    fn pos(&mut self) -> Result<[i32; 3], Atom> {
        Ok([self.i32()?, self.i32()?, self.i32()?])
    }
    /// A record count, bounded by what is left.
    fn count(&mut self, size: usize) -> Result<usize, Atom> {
        let n = self.i32()?;
        if n < 0 || n as usize * size > self.0.len() {
            return Err(atoms::invalid_positions());
        }
        Ok(n as usize)
    }
}

fn context(packed: &[u8]) -> Result<Context, Atom> {
    if packed.is_empty() {
        return Ok(Context::default());
    }
    let mut r = Reader(packed);
    let mut context = Context {
        time: r.i64()?,
        day: r.i64()?,
        rain: f32::from_be_bytes(r.take()?),
        thunder: f32::from_be_bytes(r.take()?),
        ..Context::default()
    };
    for _ in 0..r.count(20)? {
        context.toggles.push((r.pos()?, r.i64()?));
    }
    for _ in 0..r.count(49)? {
        let min = [r.f64()?, r.f64()?, r.f64()?];
        let max = [r.f64()?, r.f64()?, r.f64()?];
        let kind = match r.take::<1>()?[0] {
            1 => EntityKind::Living,
            2 => EntityKind::Arrow,
            _ => EntityKind::Other,
        };
        context.entities.push(EntityBox { min, max, kind });
    }
    for _ in 0..r.count(14)? {
        context
            .pending
            .push((r.pos()?, u16::from_be_bytes(r.take()?)));
    }
    for _ in 0..r.count(16)? {
        context.outputs.push((r.pos()?, r.i32()?));
    }
    for _ in 0..r.count(16)? {
        context.containers.push((r.pos()?, r.i32()?));
    }
    // Pistons' part: flags (1 run events, 2 handling tick), the next tick
    // order, the border, the build height and the pending block events.
    if !r.0.is_empty() {
        let flags = r.take::<1>()?[0];
        context.run_events = flags & 1 != 0;
        context.handling_tick = flags & 2 != 0;
        context.order = r.i64()?;
        context.border = Some([r.f64()?, r.f64()?, r.f64()?, r.f64()?]);
        context.build = Some((r.i32()?, r.i32()?));
        for _ in 0..r.count(22)? {
            let pos = r.pos()?;
            let block = u16::from_be_bytes(r.take()?);
            context.events.push((pos, block, r.i32()?, r.i32()?));
        }
    }
    if !r.0.is_empty() {
        return Err(atoms::invalid_positions());
    }
    Ok(context)
}

/// What placing `item` at `position` writes (VMC-029d), reading the
/// section and its group's other sections (`siblings`) and the comparators'
/// `outputs` (a repeater's lock): `[{x, y, z, state}]`
/// (the placed block first among them) or `nil` when vanilla refuses it.
/// `values` are the click's inputs by `placement::VARS` (the light ones are
/// read here); `seed` seeds the random a placement draws from.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn block_place(
    region: ResourceArc<Region>,
    siblings: Vec<ResourceArc<Region>>,
    rules: ResourceArc<BlockRules>,
    item: u16,
    values: Vec<u8>,
    position: (i32, i32, i32),
    absent: Vec<(i32, i32)>,
    seed: i64,
    outputs: Vec<((i32, i32, i32), i32)>,
) -> Result<Option<Vec<(i32, i32, i32, u16)>>, Atom> {
    let values: [u8; 13] = values.try_into().map_err(|_| atoms::invalid_state())?;
    let outputs: Vec<([i32; 3], i32)> = outputs
        .into_iter()
        .map(|((x, y, z), output)| ([x, y, z], output))
        .collect();
    let (x, y, z) = position;
    let absent: HashSet<(i32, i32)> = absent.into_iter().collect();
    let guards = lock_group(&region, &siblings)?;
    let stores: Vec<&ColumnStore> = guards.iter().map(|guard| &**guard).collect();
    let writes = valimc_core::rules::live::place(
        &rules.rules,
        &stores,
        &absent,
        item,
        values,
        [x, y, z],
        seed,
        &outputs,
    )
    .map_err(|_| atoms::invalid_state())?;
    Ok(writes.map(|writes| {
        writes
            .into_iter()
            .map(|(p, s)| (p[0], p[1], p[2], s))
            .collect()
    }))
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
    redstone: Binary<'a>,
    random: Binary<'a>,
) -> Result<Updated<'a>, Atom> {
    let packed = Packed {
        changes,
        ticks,
        fluid_ticks,
        actions,
        options,
        redstone,
        random,
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
    redstone: Binary<'a>,
    random: Binary<'a>,
) -> Result<Updated<'a>, Atom> {
    let packed = Packed {
        changes,
        ticks,
        fluid_ticks,
        actions,
        options,
        redstone,
        random,
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
    let absent: HashSet<(i32, i32)> = absent.into_iter().collect();
    let phase = random_phase(packed.random.as_slice())?;
    let mut guards = lock_group(region, siblings)?;
    // The random phase draws with the own section's random tick state, out
    // of the store for the run.
    let mut ticks = phase
        .as_ref()
        .map(|_| std::mem::replace(&mut guards[0].random, RandomTicks::new(0, 0)));
    let outcome = run_locked(
        &guards,
        rules,
        packed,
        &absent,
        seed,
        budget,
        phase.as_ref().zip(ticks.as_mut()),
    );
    if let Some(ticks) = ticks {
        guards[0].random = ticks;
    }
    Ok(encode(env, &outcome?))
}

#[allow(clippy::too_many_arguments)]
fn run_locked(
    guards: &[MutexGuard<'_, ColumnStore>],
    rules: &Rules,
    packed: &Packed,
    absent: &HashSet<(i32, i32)>,
    seed: i64,
    budget: Option<u64>,
    phase: Option<(&RandomPhase, &mut RandomTicks)>,
) -> Result<valimc_core::rules::live::Outcome, Atom> {
    let changes = records(packed.changes.as_slice())?;
    let ticks = records(packed.ticks.as_slice())?;
    let fluid_ticks = fluid_records(packed.fluid_ticks.as_slice())?;
    let actions = actions(packed.actions.as_slice())?;
    let stores: Vec<&ColumnStore> = guards.iter().map(|guard| &**guard).collect();
    let context = context(packed.redstone.as_slice())?;
    let (sky_darken, sun_angle) = match &rules.power {
        Some(power) => (
            power
                .day
                .sky_darken(context.day, context.rain, context.thunder),
            power.day.sun_angle(context.day),
        ),
        None => (0, 0.0),
    };
    let input = Input {
        changes: &changes,
        actions: &actions,
        ticks: &ticks,
        fluid_ticks: &fluid_ticks,
        options: Options::from_bits(packed.options),
        pending: &context.pending,
        entities: &context.entities,
        time: context.time,
        toggles: &context.toggles,
        sky_darken,
        sun_angle,
        sky: None,
        outputs: &context.outputs,
        containers: &context.containers,
        events: &context.events,
        run_events: context.run_events,
        handling_tick: context.handling_tick,
        order: context.order,
        border: context.border,
        build: context.build,
    };
    let mut random = Random::legacy(seed);
    valimc_core::rules::live::run_ticking(
        rules,
        &stores,
        absent,
        &input,
        &mut random,
        budget,
        phase,
    )
    .map_err(|_| atoms::invalid_state())?
    .ok_or(atoms::too_large())
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
    let mut scheduled = Vec::with_capacity(outcome.block_ticks.len() * 19);
    for (pos, block, delay, priority) in &outcome.block_ticks {
        put_position(&mut scheduled, *pos);
        scheduled.extend_from_slice(&block.to_be_bytes());
        scheduled.extend_from_slice(&delay.to_be_bytes());
        scheduled.push(*priority as i8 as u8);
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
    let report = &outcome.report;
    let mut sounds = Vec::with_capacity(report.sounds.len() * 35);
    for sound in &report.sounds {
        for c in sound.pos {
            sounds.extend_from_slice(&c.to_be_bytes());
        }
        sounds.extend_from_slice(&sound.sound.to_be_bytes());
        sounds.extend_from_slice(&sound.volume.to_be_bytes());
        sounds.extend_from_slice(&sound.pitch.to_be_bytes());
        sounds.push(u8::from(sound.actor));
    }
    let mut block_events = Vec::with_capacity(report.block_events.len() * 22);
    for (pos, block, b0, b1) in &report.block_events {
        put_position(&mut block_events, *pos);
        block_events.extend_from_slice(&block.to_be_bytes());
        block_events.extend_from_slice(&b0.to_be_bytes());
        block_events.extend_from_slice(&b1.to_be_bytes());
    }
    let mut primed = Vec::with_capacity(report.primed.len() * 12);
    for pos in &report.primed {
        put_position(&mut primed, *pos);
    }
    let mut dispensed = Vec::with_capacity(report.dispensed.len() * 12);
    for pos in &report.dispensed {
        put_position(&mut dispensed, *pos);
    }
    let mut toggles = Vec::with_capacity(outcome.toggles.len() * 20);
    for (pos, when) in &outcome.toggles {
        put_position(&mut toggles, *pos);
        toggles.extend_from_slice(&when.to_be_bytes());
    }
    let mut outputs = Vec::with_capacity(outcome.outputs.len() * 16);
    for (pos, output) in &outcome.outputs {
        put_position(&mut outputs, *pos);
        outputs.extend_from_slice(&output.unwrap_or(-1).to_be_bytes());
    }
    // Moving pistons kept (their records) and gone (positions), the pending
    // block events, those that ran, and the pushes (VMC-048b).
    let mut kept = Vec::new();
    let mut gone = Vec::new();
    for (pos, moving) in &outcome.pistons {
        match moving {
            Some(m) => m.pack(*pos, &mut kept),
            None => put_position(&mut gone, *pos),
        }
    }
    let event_records = |events: &[valimc_core::rules::piston::Event]| {
        let mut out = Vec::with_capacity(events.len() * 22);
        for (pos, block, b0, b1) in events {
            put_position(&mut out, *pos);
            out.extend_from_slice(&block.to_be_bytes());
            out.extend_from_slice(&b0.to_be_bytes());
            out.extend_from_slice(&b1.to_be_bytes());
        }
        out
    };
    let pending = event_records(&outcome.events);
    let executed = event_records(&outcome.report.executed);
    let mut hidden = Vec::with_capacity(outcome.hidden.len() * 12);
    for pos in &outcome.hidden {
        put_position(&mut hidden, *pos);
    }
    let mut drawn = Vec::with_capacity(outcome.drawn.len() * 14);
    for (pos, state) in &outcome.drawn {
        put_position(&mut drawn, *pos);
        drawn.extend_from_slice(&state.to_be_bytes());
    }
    let mut grown = Vec::with_capacity(outcome.grown.len() * 12);
    for pos in &outcome.grown {
        put_position(&mut grown, *pos);
    }
    let mut pushes = Vec::new();
    for push in &outcome.report.pushes {
        push.moving.pack(push.pos, &mut pushes);
        pushes.extend_from_slice(&push.progress.to_bits().to_be_bytes());
        pushes.extend_from_slice(&push.state.to_be_bytes());
        pushes.push(u8::from(push.landed));
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
        (
            binary(env, &sounds),
            binary(env, &block_events),
            binary(env, &primed),
            binary(env, &toggles),
            binary(env, &outputs),
            binary(env, &dispensed),
        ),
        (
            binary(env, &kept),
            binary(env, &gone),
            binary(env, &pending),
            binary(env, &executed),
            binary(env, &pushes),
            binary(env, &hidden),
        ),
        (binary(env, &drawn), binary(env, &grown)),
    )
}
