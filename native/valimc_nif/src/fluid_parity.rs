//! FluidOracle's flow scenes on the live block-update engine (VMC-031a),
//! built only with the `parity` feature. A scene's cells go into the stores
//! of the 8 × 8-chunk sections it straddles, which one run reads as a group's
//! sections; each game tick applies its actions (a set cell is a change the
//! owner made, a bucket or pickup an engine action), then one run takes the
//! due block ticks and fluid ticks, kept in vanilla's `LevelTicks` order
//! (trigger tick, then scheduling order; a position and type pending once).

use crate::atoms;
use crate::facts::FLAGS;
use crate::rules::BlockRules;
use rustler::{Atom, ResourceArc};
use std::collections::{BTreeMap, HashMap, HashSet};
use valimc_core::column::{ColumnStore, HEIGHT};
use valimc_core::rules::fluid::{Options, BREAK};
use valimc_core::rules::live::{self, Action, Input, Outcome};
use valimc_core::worldgen::random::Random;

/// A scene action: tick, kind (0 set, 1 a bucket emptied, 2 a pickup, 3 a
/// lava cell's random tick), position and the state set, the bucket's fluid
/// or whether fire spreads.
type SceneAction = (i64, u8, i32, i32, i32, u16);

/// A tick's outcome: the tick, the cells whose state differs from the tick's
/// start (sorted), the level events (sorted) and the actions' results.
type SceneTick = (
    i64,
    Vec<(i32, i32, i32, u16)>,
    Vec<(i32, i32, i32, i32, i32)>,
    Vec<i32>,
);

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum Kind {
    Block(u16),
    Fluid(u8),
}

struct Scene {
    stores: Vec<ColumnStore>,
    /// Pending ticks: (trigger, sequence) => (position, kind).
    pending: BTreeMap<(i64, u64), ([i32; 3], Kind)>,
    keys: HashSet<([i32; 3], Kind)>,
    sequence: u64,
    time: i64,
    /// This tick's cells as they were at its start.
    before: HashMap<[i32; 3], u16>,
    events: Vec<(i32, i32, i32, i32, i32)>,
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
        self.before.entry(pos).or_insert(old);
        let i = self.store_of(pos).ok_or(atoms::out_of_region())?;
        self.stores[i]
            .set_many(&[(pos[0], pos[1], pos[2], state as u32)], flags)
            .map_err(|_| atoms::invalid_state())?;
        Ok(())
    }

    fn schedule(&mut self, pos: [i32; 3], kind: Kind, delay: i32) {
        if self.keys.insert((pos, kind)) {
            self.pending
                .insert((self.time + delay as i64, self.sequence), (pos, kind));
            self.sequence += 1;
        }
    }

    /// Commit a run: its cells, ticks and events.
    fn apply(&mut self, outcome: &Outcome) -> Result<(), Atom> {
        for &(pos, state) in &outcome.changes {
            self.set(pos, state)?;
        }
        for &(pos, block, delay) in &outcome.block_ticks {
            self.schedule(pos, Kind::Block(block), delay);
        }
        for &(pos, fluid, delay) in &outcome.fluid_ticks {
            self.schedule(pos, Kind::Fluid(fluid), delay);
        }
        for d in &outcome.report.destroyed {
            if d.effects {
                self.events
                    .push((d.pos[0], d.pos[1], d.pos[2], BREAK, d.state as i32));
            }
        }
        for &(p, kind, data) in &outcome.report.events {
            self.events.push((p[0], p[1], p[2], kind, data));
        }
        Ok(())
    }
}

/// One FluidOracle scene: from `cells`, `ticks` game ticks with `actions`,
/// the level random seeded with `seed`, the fluid settings' bits `options`.
/// Per tick with any change, event or action, its outcome.
#[rustler::nif(schedule = "DirtyCpu")]
fn fluid_scene(
    rules: ResourceArc<BlockRules>,
    cells: Vec<(i32, i32, i32, u16)>,
    actions: Vec<SceneAction>,
    ticks: i64,
    seed: i64,
    options: u32,
) -> Result<Vec<SceneTick>, Atom> {
    let rules = &rules.rules;
    let table = rules.table.clone();
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
        events: Vec::new(),
    };
    for &(x, y, z, state) in &cells {
        scene.set([x, y, z], state)?;
    }
    let options = Options::from_bits(options);
    let mut random = Random::legacy(seed);
    let absent = HashSet::new();
    let mut out = Vec::new();
    let run = |scene: &mut Scene, input: &Input, random: &mut Random| -> Result<Outcome, Atom> {
        let stores: Vec<&ColumnStore> = scene.stores.iter().collect();
        let outcome = live::run(rules, &stores, &absent, input, random, None)
            .map_err(|_| atoms::invalid_state())?
            .ok_or(atoms::too_large())?;
        scene.apply(&outcome)?;
        Ok(outcome)
    };
    for t in 0..ticks {
        scene.time = t;
        scene.before.clear();
        scene.events.clear();
        let mut results = Vec::new();
        for &(_, kind, x, y, z, value) in actions.iter().filter(|a| a.0 == t) {
            let pos = [x, y, z];
            match kind {
                0 => {
                    let old = scene.get(pos);
                    if old == value {
                        continue;
                    }
                    scene.set(pos, value)?;
                    let changes = [(pos, old)];
                    let input = Input {
                        changes: &changes,
                        options,
                        ..Input::default()
                    };
                    run(&mut scene, &input, &mut random)?;
                }
                3 => {
                    let actions = [Action::RandomTick {
                        pos,
                        fire: value == 1,
                        rain: false,
                    }];
                    let input = Input {
                        actions: &actions,
                        options,
                        ..Input::default()
                    };
                    run(&mut scene, &input, &mut random)?;
                }
                _ => {
                    let action = if kind == 1 {
                        Action::Empty {
                            pos,
                            kind: value as u8,
                            retry: None,
                            secondary: false,
                        }
                    } else {
                        Action::Pickup { pos }
                    };
                    let actions = [action];
                    let input = Input {
                        actions: &actions,
                        options,
                        ..Input::default()
                    };
                    let outcome = run(&mut scene, &input, &mut random)?;
                    results.push(outcome.results[0]);
                }
            }
        }
        // `ServerLevel.tick`: the due block ticks, then the due fluid ticks.
        let mut due = Vec::new();
        while let Some(entry) = scene.pending.first_entry() {
            if entry.key().0 > t {
                break;
            }
            let (pos, kind) = entry.remove();
            scene.keys.remove(&(pos, kind));
            due.push((pos, kind));
        }
        if !due.is_empty() {
            let block_ticks: Vec<([i32; 3], u16)> = due
                .iter()
                .filter_map(|&(pos, kind)| match kind {
                    Kind::Block(block) => {
                        let state = scene.get(pos);
                        (table.block_of(state) == block).then_some((pos, state))
                    }
                    Kind::Fluid(_) => None,
                })
                .collect();
            let fluid_ticks: Vec<([i32; 3], u8)> = due
                .iter()
                .filter_map(|&(pos, kind)| match kind {
                    Kind::Fluid(fluid) => Some((pos, fluid)),
                    Kind::Block(_) => None,
                })
                .collect();
            let input = Input {
                ticks: &block_ticks,
                fluid_ticks: &fluid_ticks,
                options,
                ..Input::default()
            };
            run(&mut scene, &input, &mut random)?;
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
        if !changed.is_empty() || !events.is_empty() || !results.is_empty() {
            out.push((t, changed, events, results));
        }
    }
    Ok(out)
}
