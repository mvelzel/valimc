//! RedstoneOracle's circuit scenes on the live block-update engine
//! (VMC-047a, VMC-048a), built only with the `parity` feature. A scene's
//! cells go into the stores of the 8 × 8-chunk sections it straddles, which
//! each run reads as one group's sections. Each game tick runs the due block
//! ticks (vanilla's `LevelTicks` order: trigger tick, then priority, then
//! scheduling order; a position and block pending once), then every twentieth
//! tick the daylight detectors' updates, then each action as its own run (a
//! set cell is a change the owner made; a container's new contents its
//! signal and `setChanged`), then the entities' contacts. Comparators'
//! outputs and containers' signals are kept as an owner keeps them. The day
//! check samples `power::Day`.

use crate::atoms;
use crate::facts::FLAGS;
use crate::rules::BlockRules;
use rustler::{Atom, ResourceArc};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use valimc_core::column::{ColumnStore, HEIGHT};
use valimc_core::rules::components::{EntityBox, EntityKind};
use valimc_core::rules::fluid::Options;
use valimc_core::rules::live::{self, Action, Input, Outcome};
use valimc_core::worldgen::random::Random;

/// A scene action: tick, kind (0 set, 1 use, 2 a hook or diode placed, 3 a
/// page turned, 4 a target hit, 5 tripwire disarmed, 6 a container filled),
/// position, and two values (the state set; a use's facing and whether the
/// player may build; a hit's power and whether an arrow made it; a fill's
/// signal, -1 where no container was).
type SceneAction = (i64, u8, (i32, i32, i32), i32, i32);

/// An entity: the tick it appears, its box, kind (0 not living, 1 living,
/// 2 an arrow) and the tick it is gone by.
type SceneEntity = (i64, (f64, f64, f64), (f64, f64, f64), u8, i64);

/// A daylight update tick: the tick, `skyDarken` and the sun angle's bits.
type SceneDay = (i64, i32, u32);

/// A sound: position, name, volume and pitch bits, and whether the acting
/// player hears it already.
type SceneSound = ((f64, f64, f64), String, u32, u32, bool);

/// A tick's outcome: the tick, the cells whose state differs from the tick's
/// start (sorted), level events (sorted), sounds, block events, primed TNT
/// cells, use results, each in order, and the comparators whose output
/// differs from the tick's start (a new one's from 0), sorted.
type SceneTick = (
    i64,
    Vec<(i32, i32, i32, u16)>,
    Vec<(i32, i32, i32, i32, i32)>,
    Vec<SceneSound>,
    (
        Vec<(i32, i32, i32, u16, i32, i32)>,
        Vec<(i32, i32, i32)>,
        Vec<i32>,
        Vec<(i32, i32, i32, i32)>,
    ),
);

struct Scene {
    stores: Vec<ColumnStore>,
    /// Pending block ticks: (trigger, priority, sequence) => (position, block).
    pending: BTreeMap<(i64, i32, u64), ([i32; 3], u16)>,
    keys: HashSet<([i32; 3], u16)>,
    sequence: u64,
    time: i64,
    /// This tick's cells as they were at its start.
    before: HashMap<[i32; 3], u16>,
    /// Every cell ever set, `BlockPos` order (y, z, x).
    known: BTreeSet<(i32, i32, i32)>,
    events: Vec<(i32, i32, i32, i32, i32)>,
    sounds: Vec<SceneSound>,
    block_events: Vec<(i32, i32, i32, u16, i32, i32)>,
    primed: Vec<(i32, i32, i32)>,
    toggles: Vec<([i32; 3], i64)>,
    table: std::sync::Arc<valimc_core::worldgen::blocks::BlockTable>,
    /// Comparators' outputs, and containers' signals (their block entities').
    outputs: HashMap<[i32; 3], i32>,
    containers: HashMap<[i32; 3], i32>,
}

impl Scene {
    fn get(&self, pos: [i32; 3]) -> u16 {
        self.store_of(pos)
            .and_then(|i| self.stores[i].get(pos[0], pos[1], pos[2]).ok())
            .unwrap_or(0)
    }

    fn store_of(&self, pos: [i32; 3]) -> Option<usize> {
        let chunk = (pos[0] >> 4, pos[2] >> 4);
        self.stores.iter().position(|s| {
            (s.chunk_min.0..s.chunk_min.0 + s.chunk_size).contains(&chunk.0)
                && (s.chunk_min.1..s.chunk_min.1 + s.chunk_size).contains(&chunk.1)
        })
    }

    fn set(&mut self, pos: [i32; 3], state: u16) -> Result<(), Atom> {
        let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
        let old = self.get(pos);
        if self.table.block_of(old) != self.table.block_of(state) {
            self.containers.remove(&pos);
        }
        self.before.entry(pos).or_insert(old);
        self.known.insert((pos[1], pos[2], pos[0]));
        let i = self.store_of(pos).ok_or(atoms::out_of_region())?;
        self.stores[i]
            .set_many(&[(pos[0], pos[1], pos[2], state as u32)], flags)
            .map_err(|_| atoms::invalid_state())?;
        Ok(())
    }

    fn schedule(&mut self, pos: [i32; 3], block: u16, delay: i32, priority: i32) {
        if self.keys.insert((pos, block)) {
            self.pending.insert(
                (self.time + delay as i64, priority, self.sequence),
                (pos, block),
            );
            self.sequence += 1;
        }
    }

    /// Commit a run: its cells, ticks and what it played.
    fn apply(&mut self, outcome: &Outcome, sound_names: &[String]) -> Result<(), Atom> {
        if !outcome.fluid_ticks.is_empty() {
            return Err(atoms::invalid_state());
        }
        for &(pos, state) in &outcome.changes {
            self.set(pos, state)?;
        }
        for &(pos, block, delay, priority) in &outcome.block_ticks {
            self.schedule(pos, block, delay, priority);
        }
        for &(pos, output) in &outcome.outputs {
            match output {
                Some(output) => self.outputs.insert(pos, output),
                None => self.outputs.remove(&pos),
            };
        }
        let report = &outcome.report;
        for d in &report.destroyed {
            if d.effects {
                self.events
                    .push((d.pos[0], d.pos[1], d.pos[2], 2001, d.state as i32));
            }
        }
        for &(p, kind, data) in &report.events {
            self.events.push((p[0], p[1], p[2], kind, data));
        }
        for s in &report.sounds {
            let name = sound_names
                .get(s.sound as usize)
                .cloned()
                .unwrap_or_default();
            self.sounds.push((
                (s.pos[0], s.pos[1], s.pos[2]),
                name,
                s.volume.to_bits(),
                s.pitch.to_bits(),
                s.actor,
            ));
        }
        for &(p, block, b0, b1) in &report.block_events {
            self.block_events.push((p[0], p[1], p[2], block, b0, b1));
        }
        for p in &report.primed {
            self.primed.push((p[0], p[1], p[2]));
        }
        self.toggles = outcome.toggles.clone();
        Ok(())
    }
}

/// One RedstoneOracle scene over `ticks` game ticks, the level random seeded
/// with `seed`; per tick with anything to report, its outcome.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn redstone_scene(
    rules: ResourceArc<BlockRules>,
    cells: Vec<(i32, i32, i32, u16)>,
    actions: Vec<SceneAction>,
    entities: Vec<SceneEntity>,
    days: Vec<SceneDay>,
    ticks: i64,
    seed: i64,
    tnt_explodes: bool,
) -> Result<Vec<SceneTick>, Atom> {
    let rules = &rules.rules;
    let table = rules.table.clone();
    let sound_names = rules
        .power
        .as_ref()
        .map(|p| p.sounds.clone())
        .ok_or(atoms::invalid_state())?;
    let daylight = table
        .block("daylight_detector")
        .map_err(|_| atoms::invalid_state())?;
    let mut scene = Scene {
        stores: [(0, -8), (8, -8), (0, 0), (8, 0)]
            .into_iter()
            .map(|min| ColumnStore::new(min, 8, Box::new([0; HEIGHT]), 1 << 26))
            .collect(),
        pending: BTreeMap::new(),
        keys: HashSet::new(),
        sequence: 0,
        time: 0,
        before: HashMap::new(),
        known: BTreeSet::new(),
        events: Vec::new(),
        sounds: Vec::new(),
        block_events: Vec::new(),
        primed: Vec::new(),
        toggles: Vec::new(),
        outputs: HashMap::new(),
        containers: HashMap::new(),
        table: table.clone(),
    };
    for &(x, y, z, state) in &cells {
        scene.set([x, y, z], state)?;
    }
    let options = Options {
        tnt_explodes,
        ..Options::default()
    };
    let mut random = Random::legacy(seed);
    let absent = HashSet::new();
    let mut bodies: Vec<(EntityBox, i64)> = Vec::new();
    let (mut darken, mut angle) = (0, 0.0f32);
    let mut out = Vec::new();
    for t in 0..ticks {
        scene.time = t;
        scene.before.clear();
        scene.events.clear();
        scene.sounds.clear();
        scene.block_events.clear();
        scene.primed.clear();
        bodies.retain(|&(_, until)| until > t);
        let mut results = Vec::new();
        let outputs_before = scene.outputs.clone();
        // One run: the stores read as one group's, the entities and the
        // day as they stand.
        let run = |scene: &mut Scene,
                   random: &mut Random,
                   bodies: &[(EntityBox, i64)],
                   (darken, angle): (i32, f32),
                   changes: &[([i32; 3], u16)],
                   actions: &[Action],
                   ticks: &[([i32; 3], u16)]|
         -> Result<Outcome, Atom> {
            let entities: Vec<EntityBox> = bodies.iter().map(|&(b, _)| b).collect();
            let pending: Vec<([i32; 3], u16)> = scene.keys.iter().copied().collect();
            let toggles = scene.toggles.clone();
            let outputs: Vec<([i32; 3], i32)> =
                scene.outputs.iter().map(|(&p, &o)| (p, o)).collect();
            let containers: Vec<([i32; 3], i32)> =
                scene.containers.iter().map(|(&p, &s)| (p, s)).collect();
            let input = Input {
                changes,
                actions,
                ticks,
                options,
                pending: &pending,
                entities: &entities,
                time: scene.time,
                toggles: &toggles,
                sky_darken: darken,
                sun_angle: angle,
                sky: Some(15),
                outputs: &outputs,
                containers: &containers,
                ..Input::default()
            };
            let stores: Vec<&ColumnStore> = scene.stores.iter().collect();
            let outcome = live::run(rules, &stores, &absent, &input, random, None)
                .map_err(|_| atoms::invalid_state())?
                .ok_or(atoms::too_large())?;
            scene.apply(&outcome, &sound_names)?;
            Ok(outcome)
        };
        // `ServerLevel.tick`: the due block ticks.
        let mut due = Vec::new();
        while let Some(entry) = scene.pending.first_entry() {
            if entry.key().0 > t {
                break;
            }
            let (pos, block) = entry.remove();
            scene.keys.remove(&(pos, block));
            due.push((pos, table.default_state_of(block)));
        }
        if !due.is_empty() {
            run(
                &mut scene,
                &mut random,
                &bodies,
                (darken, angle),
                &[],
                &[],
                &due,
            )?;
        }
        // The daylight detectors' block entities.
        if let Some(&(_, d, bits)) = days.iter().find(|d| d.0 == t) {
            (darken, angle) = (d, f32::from_bits(bits));
            let detectors: Vec<Action> = scene
                .known
                .iter()
                .map(|&(y, z, x)| [x, y, z])
                .filter(|&p| table.block_of(scene.get(p)) == daylight)
                .map(|pos| Action::Daylight { pos })
                .collect();
            if !detectors.is_empty() {
                run(
                    &mut scene,
                    &mut random,
                    &bodies,
                    (darken, angle),
                    &[],
                    &detectors,
                    &[],
                )?;
            }
        }
        for &(_, (min_x, min_y, min_z), (max_x, max_y, max_z), kind, until) in
            entities.iter().filter(|e| e.0 == t)
        {
            let kind = match kind {
                1 => EntityKind::Living,
                2 => EntityKind::Arrow,
                _ => EntityKind::Other,
            };
            let entity = EntityBox {
                min: [min_x, min_y, min_z],
                max: [max_x, max_y, max_z],
                kind,
            };
            bodies.push((entity, until));
        }
        for &(_, kind, (x, y, z), a, b) in actions.iter().filter(|a| a.0 == t) {
            let pos = [x, y, z];
            let action = match kind {
                0 => {
                    let old = scene.get(pos);
                    if old == a as u16 {
                        continue;
                    }
                    scene.set(pos, a as u16)?;
                    run(
                        &mut scene,
                        &mut random,
                        &bodies,
                        (darken, angle),
                        &[(pos, old)],
                        &[],
                        &[],
                    )?;
                    continue;
                }
                1 => Action::Use {
                    pos,
                    facing: a as usize,
                    may_build: b == 1,
                },
                2 => Action::Placed { pos },
                3 => Action::Page { pos },
                4 => Action::Hit {
                    pos,
                    power: a,
                    arrow: b == 1,
                },
                5 => Action::Disarm { pos },
                6 if a < 0 => continue,
                6 => {
                    scene.containers.insert(pos, a);
                    Action::OutputChanged { pos }
                }
                _ => return Err(atoms::invalid_state()),
            };
            let outcome = run(
                &mut scene,
                &mut random,
                &bodies,
                (darken, angle),
                &[],
                &[action],
                &[],
            )?;
            if kind == 1 {
                results.push(outcome.results[0]);
            }
        }
        if !bodies.is_empty() {
            run(
                &mut scene,
                &mut random,
                &bodies,
                (darken, angle),
                &[],
                &[Action::Contacts],
                &[],
            )?;
        }
        let mut changed: Vec<(i32, i32, i32, u16)> = scene
            .before
            .iter()
            .filter_map(|(&pos, &old)| {
                let now = scene.get(pos);
                (now != old).then_some((pos[0], pos[1], pos[2], now))
            })
            .collect();
        changed.sort_unstable();
        let mut events = std::mem::take(&mut scene.events);
        events.sort_unstable();
        let sounds = std::mem::take(&mut scene.sounds);
        let block_events = std::mem::take(&mut scene.block_events);
        let primed = std::mem::take(&mut scene.primed);
        let mut outputs: Vec<(i32, i32, i32, i32)> = scene
            .outputs
            .iter()
            .filter(|&(p, &o)| o != outputs_before.get(p).copied().unwrap_or(0))
            .map(|(p, &o)| (p[0], p[1], p[2], o))
            .collect();
        // `BlockPos` order: y, then z, then x.
        outputs.sort_unstable_by_key(|&(x, y, z, _)| (y, z, x));
        if !changed.is_empty()
            || !events.is_empty()
            || !sounds.is_empty()
            || !block_events.is_empty()
            || !primed.is_empty()
            || !results.is_empty()
            || !outputs.is_empty()
        {
            out.push((
                t,
                changed,
                events,
                sounds,
                (block_events, primed, results, outputs),
            ));
        }
    }
    Ok(out)
}

/// `power::Day` at RedstoneOracle's day samples (`ticks`, rain and thunder
/// levels as float bits): each `skyDarken` and sun angle's bits.
#[rustler::nif(schedule = "DirtyCpu")]
fn redstone_day(
    rules: ResourceArc<BlockRules>,
    samples: Vec<(i64, u32, u32)>,
) -> Result<Vec<(i32, u32)>, Atom> {
    let day = &rules
        .rules
        .power
        .as_ref()
        .ok_or(atoms::invalid_state())?
        .day;
    Ok(samples
        .into_iter()
        .map(|(ticks, rain, thunder)| {
            let darken = day.sky_darken(ticks, f32::from_bits(rain), f32::from_bits(thunder));
            (darken, day.sun_angle(ticks).to_bits())
        })
        .collect())
}
