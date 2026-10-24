//! PistonOracle's scenes on the live block-update engine (VMC-048b), built
//! only with the `parity` feature. A scene's cells go into the stores of the
//! 8 × 8-chunk sections it straddles, which each run reads as one group's
//! sections; moving pistons' block entities live in the stores as an owner
//! keeps them. Each game tick runs a player's actions (each its own run),
//! then the due block ticks (vanilla's `LevelTicks` order), then the block
//! events, then every moving piston's block entity in the order they were
//! made, as one run each phase.

use crate::atoms;
use crate::facts::FLAGS;
use crate::rules::BlockRules;
use rustler::{Atom, ResourceArc};
use std::collections::{BTreeMap, HashMap, HashSet};
use valimc_core::column::{ColumnStore, HEIGHT};
use valimc_core::rules::live::{self, Action, Input, Outcome};
use valimc_core::rules::piston::Event;
use valimc_core::worldgen::random::Random;

/// A scene action: tick, kind (0 set, 1 a piston placed, 2 a use),
/// position and two values (the state set; a use's facing and whether the
/// player may build).
type SceneAction = (i64, u8, (i32, i32, i32), i32, i32);

/// A sound: position, name, volume and pitch bits, and whether the acting
/// player hears it already.
type SceneSound = ((f64, f64, f64), String, u32, u32, bool);

/// A moving piston: position, moved state, direction, extending, source,
/// progress and its old value as float bits, last ticked.
type SceneMoving = ((i32, i32, i32), u16, u8, (bool, bool), (u32, u32), i64);

/// A tick's outcome: the tick, the cells whose state differs from the
/// tick's start (sorted), sounds, block events raised and run, and the
/// moving pistons after it.
type SceneTick = (
    i64,
    Vec<(i32, i32, i32, u16)>,
    Vec<SceneSound>,
    Vec<(i32, i32, i32, u16, i32, i32)>,
    Vec<(i32, i32, i32, u16, i32, i32)>,
    Vec<SceneMoving>,
);

struct Scene {
    stores: Vec<ColumnStore>,
    pending: BTreeMap<(i64, i32, u64), ([i32; 3], u16)>,
    keys: HashSet<([i32; 3], u16)>,
    sequence: u64,
    time: i64,
    before: HashMap<[i32; 3], u16>,
    sounds: Vec<SceneSound>,
    raised: Vec<(i32, i32, i32, u16, i32, i32)>,
    executed: Vec<(i32, i32, i32, u16, i32, i32)>,
    events: Vec<Event>,
    order: i64,
}

impl Scene {
    fn store_of(&self, pos: [i32; 3]) -> Option<usize> {
        let chunk = (pos[0] >> 4, pos[2] >> 4);
        self.stores.iter().position(|s| {
            (s.chunk_min.0..s.chunk_min.0 + s.chunk_size).contains(&chunk.0)
                && (s.chunk_min.1..s.chunk_min.1 + s.chunk_size).contains(&chunk.1)
        })
    }

    fn get(&self, pos: [i32; 3]) -> u16 {
        self.store_of(pos)
            .and_then(|i| self.stores[i].get(pos[0], pos[1], pos[2]).ok())
            .unwrap_or(0)
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

    fn schedule(&mut self, pos: [i32; 3], block: u16, delay: i32, priority: i32) {
        if self.keys.insert((pos, block)) {
            self.pending.insert(
                (self.time + delay as i64, priority, self.sequence),
                (pos, block),
            );
            self.sequence += 1;
        }
    }

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
        for &(pos, moving) in &outcome.pistons {
            let i = self.store_of(pos).ok_or(atoms::out_of_region())?;
            self.stores[i]
                .set_pistons(&[(pos, moving)])
                .map_err(|_| atoms::invalid_state())?;
            if let Some(m) = moving {
                self.order = self.order.max(m.order + 1);
            }
        }
        let report = &outcome.report;
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
            self.raised.push((p[0], p[1], p[2], block, b0, b1));
        }
        for &(p, block, b0, b1) in &report.executed {
            self.executed.push((p[0], p[1], p[2], block, b0, b1));
        }
        self.events = outcome.events.clone();
        Ok(())
    }

    fn moving(&self) -> Vec<SceneMoving> {
        let mut out = Vec::new();
        for store in &self.stores {
            for list in store.pistons.values() {
                for &(p, m) in list.iter() {
                    out.push((
                        (p[0], p[1], p[2]),
                        m.moved,
                        m.direction,
                        (m.extending, m.source),
                        (m.progress.to_bits(), m.progress_o.to_bits()),
                        m.last_ticked,
                    ));
                }
            }
        }
        out
    }

    fn by_order(&self) -> Vec<[i32; 3]> {
        let mut all: Vec<(i64, [i32; 3])> = Vec::new();
        for store in &self.stores {
            for list in store.pistons.values() {
                all.extend(list.iter().map(|&(p, m)| (m.order, p)));
            }
        }
        all.sort_unstable();
        all.into_iter().map(|(_, p)| p).collect()
    }
}

/// One PistonOracle scene over `ticks` game ticks, the level random seeded
/// with `seed`; per tick with anything to report, its outcome.
#[rustler::nif(schedule = "DirtyCpu")]
fn piston_scene(
    rules: ResourceArc<BlockRules>,
    cells: Vec<(i32, i32, i32, u16)>,
    actions: Vec<SceneAction>,
    ticks: i64,
    seed: i64,
) -> Result<Vec<SceneTick>, Atom> {
    let rules = &rules.rules;
    let table = rules.table.clone();
    let sound_names = rules
        .power
        .as_ref()
        .map(|p| p.sounds.clone())
        .ok_or(atoms::invalid_state())?;
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
        sounds: Vec::new(),
        raised: Vec::new(),
        executed: Vec::new(),
        events: Vec::new(),
        order: 0,
    };
    for &(x, y, z, state) in &cells {
        scene.set([x, y, z], state)?;
    }
    let mut random = Random::legacy(seed);
    let absent = HashSet::new();
    let mut out = Vec::new();
    for t in 0..ticks {
        scene.time = t;
        scene.before.clear();
        scene.sounds.clear();
        scene.raised.clear();
        scene.executed.clear();
        let run = |scene: &mut Scene,
                   random: &mut Random,
                   changes: &[([i32; 3], u16)],
                   actions: &[Action],
                   ticks: &[([i32; 3], u16)],
                   (run_events, handling_tick): (bool, bool)|
         -> Result<Outcome, Atom> {
            let pending: Vec<([i32; 3], u16)> = scene.keys.iter().copied().collect();
            let events = scene.events.clone();
            let input = Input {
                changes,
                actions,
                ticks,
                pending: &pending,
                time: scene.time,
                sky: Some(15),
                events: &events,
                run_events,
                handling_tick,
                order: scene.order,
                ..Input::default()
            };
            let stores: Vec<&ColumnStore> = scene.stores.iter().collect();
            let outcome = live::run(rules, &stores, &absent, &input, random, None)
                .map_err(|_| atoms::invalid_state())?
                .ok_or(atoms::too_large())?;
            scene.apply(&outcome, &sound_names)?;
            Ok(outcome)
        };
        // A player's actions, before the level ticks.
        for &(_, kind, (x, y, z), a, b) in actions.iter().filter(|a| a.0 == t) {
            let pos = [x, y, z];
            match kind {
                0 => {
                    let old = scene.get(pos);
                    if old == a as u16 {
                        continue;
                    }
                    scene.set(pos, a as u16)?;
                    run(
                        &mut scene,
                        &mut random,
                        &[(pos, old)],
                        &[],
                        &[],
                        (false, false),
                    )?;
                }
                1 => {
                    run(
                        &mut scene,
                        &mut random,
                        &[],
                        &[Action::Placed { pos }],
                        &[],
                        (false, false),
                    )?;
                }
                2 => {
                    let use_ = Action::Use {
                        pos,
                        facing: a as usize,
                        may_build: b == 1,
                    };
                    run(&mut scene, &mut random, &[], &[use_], &[], (false, false))?;
                }
                _ => return Err(atoms::invalid_state()),
            }
        }
        // The due block ticks, then the block events.
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
            run(&mut scene, &mut random, &[], &[], &due, (false, true))?;
        }
        if !scene.events.is_empty() {
            run(&mut scene, &mut random, &[], &[], &[], (true, true))?;
        }
        // The block entities, in the order they were made.
        let moving: Vec<Action> = scene
            .by_order()
            .into_iter()
            .map(|pos| Action::Moving { pos })
            .collect();
        if !moving.is_empty() {
            run(&mut scene, &mut random, &[], &moving, &[], (false, false))?;
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
        out.push((
            t,
            changed,
            std::mem::take(&mut scene.sounds),
            std::mem::take(&mut scene.raised),
            std::mem::take(&mut scene.executed),
            scene.moving(),
        ));
    }
    Ok(out)
}

/// A moving piston as PistonOracle's push scenes give it: position, moved
/// state, direction, extending, source, progress bits.
type MovingT = ((i32, i32, i32), u16, u8, bool, bool, u32);

/// A pushed body as PistonOracle's push scenes give it: kind (0 an item, 1
/// an armor stand), feet, velocity, on ground.
type PushedT = (u8, (f64, f64, f64), (f64, f64, f64), bool);

/// One block entity phase of a PistonOracle push scene on the kernel
/// (`physics::piston::push_all`): the world after the phase (`cells` and the
/// moving pistons `moving`, `{x, y, z, moved, direction, extending, source,
/// progress bits}`), the moving pistons that ticked in order (as they were
/// before) and the bodies before; the bodies after.
#[rustler::nif(schedule = "DirtyCpu")]
fn piston_pushes(
    cells: Vec<(i32, i32, i32, u16)>,
    moving: Vec<MovingT>,
    ticking: Vec<MovingT>,
    bodies: Vec<PushedT>,
    states: (u16, u16, u16),
) -> Result<Vec<PushedT>, Atom> {
    use valimc_core::physics::piston::{push_all, Push, PushBody, PushStates, World};
    use valimc_core::physics::source::{AirWhereUnreadable, MovingStates, States};
    use valimc_core::piston::Moving;
    let facts = crate::facts::PHYSICS.get().ok_or(atoms::invalid_state())?;
    let moving_of =
        |(moved, direction, extending, source, progress): (u16, u8, bool, bool, u32)| {
            let progress = f32::from_bits(progress);
            Moving {
                moved,
                direction,
                extending,
                source,
                progress,
                progress_o: progress,
                last_ticked: 0,
                order: 0,
            }
        };
    let states_source = States(cells.iter().map(|&(x, y, z, s)| ([x, y, z], s)).collect());
    let air = AirWhereUnreadable(&states_source);
    let source = MovingStates {
        states: &air,
        moving: moving
            .iter()
            .map(|&((x, y, z), m, d, e, s, p)| ([x, y, z], moving_of((m, d, e, s, p))))
            .collect(),
    };
    let pushes: Vec<Push> = ticking
        .iter()
        .map(|&((x, y, z), m, d, e, s, p)| (([x, y, z]), moving_of((m, d, e, s, p))))
        .map(|(pos, m)| Push {
            pos,
            moving: m,
            progress: m.progress + 0.5,
            state: states.2,
            landed: m.progress >= 1.0,
        })
        .collect();
    let mut list: Vec<PushBody> = bodies
        .iter()
        .map(|&(kind, (x, y, z), (vx, vy, vz), on_ground)| {
            let living = kind == 1;
            PushBody {
                position: [x, y, z],
                half_width: if living { 0.25 } else { 0.125 },
                height: if living { 1.975f32 as f64 } else { 0.25 },
                velocity: [vx, vy, vz],
                on_ground,
                step: if living { 0.6 } else { 0.0 },
                simulates: true,
                authoritative: true,
                ignored: false,
                bounciness: 0.0,
                suppress_bounce: false,
                living,
                gravity: if living { 0.08 } else { 0.04 },
                air_drag: 0.98,
                pushed: false,
            }
        })
        .collect();
    let world = World {
        source: &source,
        facts,
        border: None,
        states: PushStates {
            slime: states.0,
            honey: states.1,
        },
    };
    push_all(&world, &pushes, &mut list);
    Ok(bodies
        .iter()
        .zip(&list)
        .map(|(&(kind, ..), b)| {
            (
                kind,
                (b.position[0], b.position[1], b.position[2]),
                (b.velocity[0], b.velocity[1], b.velocity[2]),
                b.on_ground,
            )
        })
        .collect())
}
