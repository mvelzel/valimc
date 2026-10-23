//! GrowthOracle's scenes on the live block-update engine (VMC-039a), built
//! only with the `parity` feature. A scene's cells go into the stores of the
//! 8 × 8-chunk sections it straddles, which one run reads as a group's
//! sections. Each game tick applies its actions in order, each its own run (a
//! set cell is a change the owner made; a random tick or bone meal an engine
//! action), then runs the due block ticks in vanilla's `LevelTicks` order
//! (trigger tick, then scheduling order; a position and block pending once).
//! Fluid ticks are dropped, as the oracle never runs them. Every cell has the
//! scene's sky light and no block light.

use crate::atoms;
use crate::facts::FLAGS;
use crate::rules::BlockRules;
use rustler::{Atom, ResourceArc};
use std::collections::{BTreeMap, HashMap, HashSet};
use valimc_core::column::{ColumnStore, HEIGHT};
use valimc_core::rules::fluid::BREAK;
use valimc_core::rules::live::{self, Action, Input, Outcome};
use valimc_core::worldgen::random::Random;

/// A scene action: tick, kind (0 set, 1 a random tick, 2 bone meal),
/// position and the state set.
type SceneAction = (i64, u8, i32, i32, i32, u16);

/// A tick's outcome: the tick, the cells whose state differs from the tick's
/// start (sorted), the level events (sorted) and the random ticks' and bone
/// meals' results in order.
type SceneTick = (
    i64,
    Vec<(i32, i32, i32, u16)>,
    Vec<(i32, i32, i32, i32, i32)>,
    Vec<i32>,
);

struct Scene {
    stores: Vec<ColumnStore>,
    /// Pending block ticks: (trigger, sequence) => (position, block).
    pending: BTreeMap<(i64, u64), ([i32; 3], u16)>,
    keys: HashSet<([i32; 3], u16)>,
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

    /// Commit a run: its cells, block ticks and events.
    fn apply(&mut self, outcome: &Outcome) -> Result<(), Atom> {
        for &(pos, state) in &outcome.changes {
            self.set(pos, state)?;
        }
        for &(pos, block, delay, _) in &outcome.block_ticks {
            if self.keys.insert((pos, block)) {
                self.pending
                    .insert((self.time + delay as i64, self.sequence), (pos, block));
                self.sequence += 1;
            }
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

/// One GrowthOracle scene: from `cells`, `ticks` game ticks with `actions`,
/// the level random seeded with `seed`, sky light `sky`, `skyDarken`
/// `darken`, and rain at every cell or none. Per tick with any change, event
/// or result, its outcome.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn growth_scene(
    rules: ResourceArc<BlockRules>,
    cells: Vec<(i32, i32, i32, u16)>,
    actions: Vec<SceneAction>,
    ticks: i64,
    seed: i64,
    sky: i32,
    darken: i32,
    rain: bool,
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
    let mut random = Random::legacy(seed);
    let absent = HashSet::new();
    let mut out = Vec::new();
    let run = |scene: &mut Scene,
               changes: &[([i32; 3], u16)],
               actions: &[Action],
               ticks: &[([i32; 3], u16)],
               random: &mut Random|
     -> Result<Outcome, Atom> {
        let input = Input {
            changes,
            actions,
            ticks,
            sky: Some(sky),
            sky_darken: darken,
            ..Input::default()
        };
        let stores: Vec<&ColumnStore> = scene.stores.iter().collect();
        let outcome = live::run(rules, &stores, &absent, &input, random, None)
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
            if kind == 0 {
                let old = scene.get(pos);
                if old != value {
                    scene.set(pos, value)?;
                    run(&mut scene, &[(pos, old)], &[], &[], &mut random)?;
                }
                continue;
            }
            let action = if kind == 1 {
                Action::RandomTick {
                    pos,
                    fire: false,
                    rain,
                }
            } else {
                Action::BoneMeal { pos }
            };
            let outcome = run(&mut scene, &[], &[action], &[], &mut random)?;
            results.push(outcome.results[0]);
        }
        let mut due = Vec::new();
        while let Some(entry) = scene.pending.first_entry() {
            if entry.key().0 > t {
                break;
            }
            let (pos, block) = entry.remove();
            scene.keys.remove(&(pos, block));
            let state = scene.get(pos);
            if table.block_of(state) == block {
                due.push((pos, state));
            }
        }
        if !due.is_empty() {
            run(&mut scene, &[], &[], &due, &mut random)?;
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

/// Cells as `(x, y, z, state)`.
type Cells = Vec<(i32, i32, i32, u16)>;

/// A tree case: its cells, the sapling's cell and the random's seed.
type TreeCase = (Cells, (i32, i32, i32), i64);

/// GrowthOracle's trees: per case its cells (on an empty flat world of the
/// plains), the sapling's cell and the random's seed; the blocks the tree
/// changed (sorted), or nil when none grew.
#[rustler::nif(schedule = "DirtyCpu")]
fn growth_trees(
    rules: ResourceArc<BlockRules>,
    state: ResourceArc<crate::worldgen::WorldgenState>,
    cases: Vec<TreeCase>,
) -> Result<Vec<Option<Cells>>, String> {
    use valimc_core::worldgen::compiler::{BiomeSource, Placement};
    let table = rules.rules.table.clone();
    let growth = rules.rules.growth.as_ref().ok_or("no growth facts")?;
    let air = table.default_state("air")?;
    let mut worldgen = state.lease()?;
    let source = BiomeSource::parse("fixed:minecraft:plains", worldgen.registry())?;
    let base = vec![air; HEIGHT];
    cases
        .into_iter()
        .map(|(cells, (x, y, z), seed)| {
            let (cx, cz) = (x >> 4, z >> 4);
            let mut protos = Vec::new();
            for dz in -1..=1 {
                for dx in -1..=1 {
                    protos.push(worldgen.place_chunk(&source, (cx + dx, cz + dz), None, &base)?);
                }
            }
            for &(px, py, pz, s) in &cells {
                if let Some(chunk) = protos.iter_mut().find(|c| (c.x, c.z) == (px >> 4, pz >> 4)) {
                    chunk.set(&table, px, py, pz, s, air);
                }
            }
            let sapling = table.default_state_of(
                table.block_of(
                    cells
                        .iter()
                        .find(|c| (c.0, c.1, c.2) == (x, y, z))
                        .map_or(air, |c| c.3),
                ),
            );
            let grower = growth
                .grower(&table, sapling)
                .ok_or("no sapling at the case's cell")?
                .clone();
            let placed = worldgen.place(
                &source,
                &Placement::Sapling(grower),
                [x, y, z],
                protos,
                seed,
            )?;
            Ok(placed.map(|p| {
                let mut blocks: Vec<_> = p
                    .blocks
                    .iter()
                    .map(|&(p, s)| (p[0], p[1], p[2], s))
                    .collect();
                blocks.sort_unstable();
                blocks
            }))
        })
        .collect()
}
