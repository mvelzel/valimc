//! Redstone components on the block-update engine (VMC-047a): the signal
//! sources (levers, buttons, pressure plates, redstone torches with their
//! burnout, daylight detectors, target blocks, tripwire hooks and tripwire,
//! lecterns' page pulses) and the blocks that react to power (lamps, doors,
//! trapdoors, fence gates, note blocks, TNT), with VMC-048a's repeaters
//! (delay, locking), comparators (compare and subtract, analog inputs, their
//! block entity's output) and observers, as their vanilla classes do it
//! with the experimental redstone off: `neighborChanged`, scheduled ticks
//! with their priorities, `onPlace` and `affectNeighborsAfterRemoval`, and the
//! uses, placements, entity contacts, detector updates, page turns,
//! container changes and projectile hits that start them. Signals are
//! `power.rs`'s; every write is a `Level.setBlock` with its flags, so the
//! updates it starts run in vanilla's order.
//!
//! A reaction reads before it writes; one that reads past the owner's border
//! stops there, whole.

use super::at;
use super::power::{daylight_power, Kind};
use super::updater::{Engine, World, ALL, CLIENTS, KNOWN_SHAPE, UPDATE_LIMIT};
use crate::worldgen::blocks::{BlockTable, FLUID_WATER};

const DOWN: usize = 0;
const UP: usize = 1;
const NAMES: [&str; 6] = ["down", "up", "north", "south", "west", "east"];
/// `Block.UPDATE_IMMEDIATE`.
const IMMEDIATE: i32 = 8;
/// `Block.UPDATE_INVISIBLE` | 256 (`playerWillDestroy`'s disarm).
const DISARM_FLAGS: i32 = 260;
/// `RedstoneTorchBlock`'s burnout: toggles kept this long, this many burn
/// it out, and it relights no sooner than this.
const TOGGLE_TIMER: i64 = 60;
const MAX_TOGGLES: usize = 8;
const RESTART_DELAY: i32 = 160;
const TORCH_DELAY: i32 = 2;
const LAMP_DELAY: i32 = 4;
const TRIPWIRE_RECHECK: i32 = 10;
const HOOK_RANGE: i32 = 42;
/// Level events: a torch burning out, a lectern's page.
const BURNOUT: i32 = 1502;
const PAGE: i32 = 1043;
/// `TickPriority` values.
const EXTREMELY_HIGH: i32 = -3;
const VERY_HIGH: i32 = -2;
const HIGH: i32 = -1;
const NORMAL: i32 = 0;
const COMPARATOR_DELAY: i32 = 2;
const OBSERVER_DELAY: i32 = 2;

/// An entity a contact or a check sees: its box and kind.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EntityBox {
    pub min: [f64; 3],
    pub max: [f64; 3],
    pub kind: EntityKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntityKind {
    /// Not living: items, primed TNT, falling blocks, orbs.
    Other,
    /// Players and mobs.
    Living,
    /// An arrow (`AbstractArrow`).
    Arrow,
}

impl EntityBox {
    /// `AABB.intersects`.
    fn intersects(&self, b: &[f64; 6]) -> bool {
        (0..3).all(|i| self.min[i] < b[i + 3] && self.max[i] > b[i])
    }
}

/// A sound a reaction plays: where, which (an index into the facts'
/// sounds), its volume and pitch, and whether the acting player hears it
/// already (vanilla passes that player to `playSound`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sound {
    pub pos: [f64; 3],
    pub sound: u16,
    pub volume: f32,
    pub pitch: f32,
    pub actor: bool,
}

/// What redstone reads beyond the cells, per run.
#[derive(Clone, Debug, Default)]
pub struct Redstone {
    /// The game time (torch burnout).
    pub time: i64,
    /// Recent torch toggles, oldest first (`RECENT_TOGGLES`).
    pub toggles: Vec<([i32; 3], i64)>,
    /// This tick's due block ticks not yet run (`willTickThisTick`).
    pub due: Vec<([i32; 3], u16)>,
    /// The entities contacts and checks see.
    pub entities: Vec<EntityBox>,
    /// `Level.skyDarken` and `SUN_ANGLE` (degrees) for daylight detectors.
    pub sky_darken: i32,
    pub sun_angle: f32,
    /// The `tnt_explodes` game rule.
    pub tnt_explodes: bool,
}

/// A use's outcome: vanilla passes it on (an iron door, a detector to a
/// player who may not build), or it was used.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Used {
    Pass,
    Used,
}

/// The direction a state's `facing` names (north if none).
pub(super) fn facing(table: &BlockTable, state: u16) -> usize {
    NAMES
        .iter()
        .position(|n| Some(*n) == table.value(state, "facing"))
        .unwrap_or(2)
}

fn flag(table: &BlockTable, state: u16, property: &str) -> bool {
    table.value(state, property) == Some("true")
}

fn set(table: &BlockTable, state: u16, property: &str, value: bool) -> u16 {
    table
        .with(state, property, if value { "true" } else { "false" })
        .unwrap_or(state)
}

fn int(table: &BlockTable, state: u16, property: &str) -> i32 {
    table
        .value(state, property)
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
}

fn with_int(table: &BlockTable, state: u16, property: &str, value: i32) -> u16 {
    table
        .with(state, property, &value.to_string())
        .unwrap_or(state)
}

fn centre(pos: [i32; 3]) -> [f64; 3] {
    pos.map(|c| c as f64 + 0.5)
}

fn step(pos: [i32; 3], d: usize, n: i32) -> [i32; 3] {
    let s = super::STEP[d];
    [pos[0] + s[0] * n, pos[1] + s[1] * n, pos[2] + s[2] * n]
}

impl<W: World> Engine<'_, W> {
    fn kind_of(&self, state: u16) -> Option<(Kind, [u16; 4])> {
        let facts = self.power_facts()?;
        facts
            .component(&self.rules.table, state)
            .map(|c| (c.kind, c.sounds))
    }

    fn sound(&mut self, pos: [f64; 3], sound: u16, volume: f32, pitch: f32, actor: bool) {
        self.report.sounds.push(super::components::Sound {
            pos,
            sound,
            volume,
            pitch,
            actor,
        });
    }

    /// A door's, trapdoor's or fence gate's pitch: `nextFloat() * 0.1 + 0.9`.
    fn random_pitch(&mut self) -> f32 {
        self.world.next_float() * 0.1 + 0.9
    }

    /// Run `decide` (reads only) unless it reads past the border; `None`
    /// counts a stop.
    fn decide<T>(&mut self, decide: impl FnOnce(&mut Self) -> T) -> Option<T> {
        let mark = self.world.begin();
        let decision = decide(self);
        if self.world.crossed(mark) {
            self.report.stopped += 1;
            None
        } else {
            Some(decision)
        }
    }

    /// `neighborChanged` of a component at `pos` (holding `state`), told by
    /// a neighbour of block `source`; whether it is one.
    pub(super) fn component_neighbor_changed(
        &mut self,
        pos: [i32; 3],
        state: u16,
        source: u16,
    ) -> bool {
        let Some((kind, sounds)) = self.kind_of(state) else {
            return false;
        };
        let table = self.rules.table.clone();
        let block = table.block_of(state);
        match kind {
            Kind::Torch | Kind::WallTorch => {
                let Some(powered) = self.decide(|e| e.torch_signal(pos, state, kind)) else {
                    return true;
                };
                if flag(&table, state, "lit") == powered && !self.will_tick_this_tick(pos, block) {
                    self.world.schedule_block_tick(pos, block, TORCH_DELAY);
                }
            }
            Kind::Lamp => {
                let Some(powered) = self.decide(|e| e.has_neighbor_signal(pos)) else {
                    return true;
                };
                let lit = flag(&table, state, "lit");
                if lit != powered {
                    if lit {
                        self.world.schedule_block_tick(pos, block, LAMP_DELAY);
                    } else {
                        self.set_block(pos, set(&table, state, "lit", true), CLIENTS, UPDATE_LIMIT);
                    }
                }
            }
            Kind::Door { .. } => {
                let other = if table.value(state, "half") == Some("lower") {
                    UP
                } else {
                    DOWN
                };
                let Some(signal) = self.decide(|e| {
                    e.has_neighbor_signal(pos) || e.has_neighbor_signal(at(pos, other))
                }) else {
                    return true;
                };
                if source != block && signal != flag(&table, state, "powered") {
                    if signal != flag(&table, state, "open") {
                        let pitch = self.random_pitch();
                        let sound = sounds[if signal { 0 } else { 1 }];
                        self.sound(centre(pos), sound, 1.0, pitch, false);
                    }
                    let new = set(
                        &table,
                        set(&table, state, "powered", signal),
                        "open",
                        signal,
                    );
                    self.set_block(pos, new, CLIENTS, UPDATE_LIMIT);
                }
            }
            Kind::Trapdoor { .. } => {
                let Some(signal) = self.decide(|e| e.has_neighbor_signal(pos)) else {
                    return true;
                };
                if signal != flag(&table, state, "powered") {
                    let mut new = state;
                    if flag(&table, state, "open") != signal {
                        new = set(&table, new, "open", signal);
                        let pitch = self.random_pitch();
                        let sound = sounds[if signal { 0 } else { 1 }];
                        self.sound(centre(pos), sound, 1.0, pitch, false);
                    }
                    let new = set(&table, new, "powered", signal);
                    self.set_block(pos, new, CLIENTS, UPDATE_LIMIT);
                    if flag(&table, new, "waterlogged") {
                        self.world
                            .schedule_fluid_tick(pos, FLUID_WATER, super::WATER_DELAY);
                    }
                }
            }
            Kind::Gate => {
                let Some(signal) = self.decide(|e| e.has_neighbor_signal(pos)) else {
                    return true;
                };
                if flag(&table, state, "powered") != signal {
                    let new = set(
                        &table,
                        set(&table, state, "powered", signal),
                        "open",
                        signal,
                    );
                    self.set_block(pos, new, CLIENTS, UPDATE_LIMIT);
                    if flag(&table, state, "open") != signal {
                        let pitch = self.random_pitch();
                        let sound = sounds[if signal { 0 } else { 1 }];
                        self.sound(centre(pos), sound, 1.0, pitch, false);
                    }
                }
            }
            Kind::Note => {
                let Some(signal) = self.decide(|e| e.has_neighbor_signal(pos)) else {
                    return true;
                };
                if signal != flag(&table, state, "powered") {
                    if signal {
                        self.play_note(pos, state);
                    }
                    self.set_block(
                        pos,
                        set(&table, state, "powered", signal),
                        ALL,
                        UPDATE_LIMIT,
                    );
                }
            }
            Kind::Tnt => {
                let Some(signal) = self.decide(|e| e.has_neighbor_signal(pos)) else {
                    return true;
                };
                if signal && self.prime(pos, sounds[0]) {
                    self.remove_block(pos);
                }
            }
            Kind::Repeater | Kind::Comparator => self.diode_neighbor_changed(pos, state, kind),
            Kind::Observer => {}
            _ => return false,
        }
        true
    }

    /// A component's scheduled tick; whether it is one.
    pub(super) fn component_tick(&mut self, pos: [i32; 3], state: u16) -> bool {
        let Some((kind, sounds)) = self.kind_of(state) else {
            return false;
        };
        let table = self.rules.table.clone();
        match kind {
            Kind::Torch | Kind::WallTorch => {
                let Some(signal) = self.decide(|e| e.torch_signal(pos, state, kind)) else {
                    return true;
                };
                let time = self.redstone.time;
                let toggles = &mut self.redstone.toggles;
                let old = toggles
                    .iter()
                    .take_while(|&&(_, when)| time - when > TOGGLE_TIMER)
                    .count();
                toggles.drain(..old);
                if flag(&table, state, "lit") {
                    if signal {
                        self.set_block(pos, set(&table, state, "lit", false), ALL, UPDATE_LIMIT);
                        if self.toggled_too_often(pos, true) {
                            self.report.events.push((pos, BURNOUT, 0));
                            let now = table.block_of(self.world.get(pos));
                            self.world.schedule_block_tick(pos, now, RESTART_DELAY);
                        }
                    }
                } else if !signal && !self.toggled_too_often(pos, false) {
                    self.set_block(pos, set(&table, state, "lit", true), ALL, UPDATE_LIMIT);
                }
            }
            Kind::Lamp => {
                let Some(powered) = self.decide(|e| e.has_neighbor_signal(pos)) else {
                    return true;
                };
                if flag(&table, state, "lit") && !powered {
                    self.set_block(pos, set(&table, state, "lit", false), CLIENTS, UPDATE_LIMIT);
                }
            }
            Kind::Button { ticks, arrows } => {
                if flag(&table, state, "powered") {
                    self.button_check(pos, state, ticks, arrows, sounds);
                }
            }
            Kind::Plate { .. } | Kind::Weighted { .. } => {
                let signal = Self::plate_signal(&table, state, kind);
                if signal > 0 {
                    self.plate_check(pos, state, kind, signal, sounds);
                }
            }
            Kind::Hook => self.calculate_state(pos, state, false, true, -1, None),
            Kind::Tripwire => {
                if flag(&table, self.world.get(pos), "powered") {
                    let current = self.world.get(pos);
                    let bounds = self
                        .power_facts()
                        .map(|f| f.bounds(current, pos))
                        .unwrap_or_default();
                    let pressed = self.redstone.entities.iter().any(|e| e.intersects(&bounds));
                    self.tripwire_check(pos, pressed);
                }
            }
            Kind::Target => {
                if int(&table, state, "power") != 0 {
                    self.set_block(pos, with_int(&table, state, "power", 0), ALL, UPDATE_LIMIT);
                }
            }
            Kind::Lectern => self.lectern_powered(pos, state, false),
            Kind::Repeater => self.repeater_tick(pos, state),
            Kind::Comparator => self.comparator_refresh(pos, state),
            Kind::Observer => self.observer_tick(pos, state),
            _ => return false,
        }
        true
    }

    /// `onPlace` of a component (`old` was at `pos`).
    pub(super) fn component_placed(&mut self, pos: [i32; 3], old: u16, state: u16) {
        let Some((kind, sounds)) = self.kind_of(state) else {
            return;
        };
        let table = self.rules.table.clone();
        let block = table.block_of(state);
        // `DiodeBlock.onPlace` tells its front at every change.
        if matches!(kind, Kind::Repeater | Kind::Comparator) {
            self.update_neighbors_in_front(pos, state);
            return;
        }
        if table.block_of(old) == block {
            return;
        }
        match kind {
            Kind::Observer => {
                if flag(&table, state, "powered") && !self.world.has_block_tick(pos, block) {
                    let new = set(&table, state, "powered", false);
                    self.set_block(pos, new, CLIENTS | KNOWN_SHAPE, UPDATE_LIMIT);
                    self.update_neighbors_in_front(pos, new);
                }
            }
            Kind::Tnt => {
                let Some(signal) = self.decide(|e| e.has_neighbor_signal(pos)) else {
                    return;
                };
                if signal && self.prime(pos, sounds[0]) {
                    self.remove_block(pos);
                }
            }
            Kind::Target => {
                if int(&table, state, "power") > 0 && !self.world.has_block_tick(pos, block) {
                    let new = with_int(&table, state, "power", 0);
                    self.set_block(pos, new, CLIENTS | KNOWN_SHAPE, UPDATE_LIMIT);
                }
            }
            Kind::Tripwire => self.update_source(pos, state),
            _ => {}
        }
    }

    /// `affectNeighborsAfterRemoval` of the components without the generic
    /// signal hooks (`wire.rs`): hooks, tripwire, lecterns.
    pub(super) fn component_removed(&mut self, pos: [i32; 3], state: u16) {
        let Some((kind, sounds)) = self.kind_of(state) else {
            return;
        };
        let table = self.rules.table.clone();
        match kind {
            Kind::Hook => self.hook_removed(state, pos, sounds),
            Kind::Tripwire => self.update_source(pos, set(&table, state, "powered", true)),
            Kind::Lectern if flag(&table, state, "powered") => self.update_below(pos, state),
            Kind::Repeater | Kind::Comparator => self.update_neighbors_in_front(pos, state),
            Kind::Observer => {
                let block = table.block_of(state);
                if flag(&table, state, "powered") && self.world.has_block_tick(pos, block) {
                    self.update_neighbors_in_front(pos, set(&table, state, "powered", false));
                }
            }
            _ => {}
        }
    }

    // ---- Actions ----

    /// `useWithoutItem` of the block at `pos` by a player facing `facing`
    /// (horizontal) who may build or not.
    pub fn use_block(&mut self, pos: [i32; 3], looking: usize, may_build: bool) -> Used {
        if !self.world.owns(pos) {
            self.report.stopped += 1;
            return Used::Pass;
        }
        let state = self.world.get(pos);
        let Some((kind, sounds)) = self.kind_of(state) else {
            return Used::Pass;
        };
        let table = self.rules.table.clone();
        let block = table.block_of(state);
        match kind {
            Kind::Lever => {
                // `LeverBlock.pull`.
                let new = set(&table, state, "powered", !flag(&table, state, "powered"));
                self.set_block(pos, new, ALL, UPDATE_LIMIT);
                self.attached_neighbours(pos, new, block);
                let pitch = if flag(&table, new, "powered") {
                    0.6
                } else {
                    0.5
                };
                self.sound(centre(pos), sounds[0], 0.3, pitch, false);
            }
            Kind::Button { ticks, .. } => {
                if !flag(&table, state, "powered") {
                    self.set_block(pos, set(&table, state, "powered", true), ALL, UPDATE_LIMIT);
                    self.attached_neighbours(pos, state, block);
                    self.world.schedule_block_tick(pos, block, ticks);
                    self.sound(centre(pos), sounds[0], 1.0, 1.0, true);
                }
            }
            Kind::Door { hand } => {
                if !hand {
                    return Used::Pass;
                }
                let open = !flag(&table, state, "open");
                self.set_block(
                    pos,
                    set(&table, state, "open", open),
                    CLIENTS | IMMEDIATE,
                    UPDATE_LIMIT,
                );
                let pitch = self.random_pitch();
                self.sound(
                    centre(pos),
                    sounds[if open { 0 } else { 1 }],
                    1.0,
                    pitch,
                    true,
                );
            }
            Kind::Trapdoor { hand } => {
                if !hand {
                    return Used::Pass;
                }
                let open = !flag(&table, state, "open");
                let new = set(&table, state, "open", open);
                self.set_block(pos, new, CLIENTS, UPDATE_LIMIT);
                if flag(&table, new, "waterlogged") {
                    self.world
                        .schedule_fluid_tick(pos, FLUID_WATER, super::WATER_DELAY);
                }
                let pitch = self.random_pitch();
                self.sound(
                    centre(pos),
                    sounds[if open { 0 } else { 1 }],
                    1.0,
                    pitch,
                    true,
                );
            }
            Kind::Gate => {
                let mut new = state;
                if flag(&table, state, "open") {
                    new = set(&table, new, "open", false);
                } else {
                    if facing(&table, state) == looking ^ 1 {
                        new = table.with(new, "facing", NAMES[looking]).unwrap_or(new);
                    }
                    new = set(&table, new, "open", true);
                }
                self.set_block(pos, new, CLIENTS | IMMEDIATE, UPDATE_LIMIT);
                let open = flag(&table, new, "open");
                let pitch = self.random_pitch();
                self.sound(
                    centre(pos),
                    sounds[if open { 0 } else { 1 }],
                    1.0,
                    pitch,
                    true,
                );
            }
            Kind::Note => {
                let note = (int(&table, state, "note") + 1) % 25;
                let new = with_int(&table, state, "note", note);
                self.set_block(pos, new, ALL, UPDATE_LIMIT);
                self.play_note(pos, new);
            }
            Kind::Daylight => {
                if !may_build {
                    return Used::Pass;
                }
                let new = set(&table, state, "inverted", !flag(&table, state, "inverted"));
                self.set_block(pos, new, CLIENTS, UPDATE_LIMIT);
                self.daylight_update(pos, new);
            }
            Kind::Repeater => {
                if !may_build {
                    return Used::Pass;
                }
                // `cycle(DELAY)`: 1 to 4, then 1.
                let delay = int(&table, state, "delay") % 4 + 1;
                self.set_block(
                    pos,
                    with_int(&table, state, "delay", delay),
                    ALL,
                    UPDATE_LIMIT,
                );
            }
            Kind::Comparator => {
                if !may_build {
                    return Used::Pass;
                }
                let subtract = table.value(state, "mode") != Some("subtract");
                let new = table
                    .with(state, "mode", if subtract { "subtract" } else { "compare" })
                    .unwrap_or(state);
                let pitch = if subtract { 0.55 } else { 0.5 };
                self.sound(centre(pos), sounds[0], 0.3, pitch, true);
                self.set_block(pos, new, CLIENTS, UPDATE_LIMIT);
                if table.block_of(self.world.get(pos)) == block {
                    self.comparator_refresh(pos, new);
                }
            }
            _ => return Used::Pass,
        }
        Used::Used
    }

    /// Each entity's contacts, in order: `entityInside` of every plate,
    /// button and tripwire its box (less 1e-5 each way) touches, its cells
    /// in x, then y, then z order; tripwire only where its outline meets the
    /// box.
    pub fn contacts(&mut self) {
        if self.power_facts().is_none() {
            return;
        }
        for index in 0..self.redstone.entities.len() {
            let entity = self.redstone.entities[index];
            let lo = entity.min.map(|c| (c + 1.0e-5).floor() as i32);
            let hi = entity.max.map(|c| (c - 1.0e-5).floor() as i32);
            let deflated = EntityBox {
                min: entity.min.map(|c| c + 1.0e-5),
                max: entity.max.map(|c| c - 1.0e-5),
                kind: entity.kind,
            };
            for z in lo[2]..=hi[2] {
                for y in lo[1]..=hi[1] {
                    for x in lo[0]..=hi[0] {
                        let pos = [x, y, z];
                        if !self.world.owns(pos) {
                            continue;
                        }
                        let state = self.world.get(pos);
                        let touchable = matches!(
                            self.kind_of(state),
                            Some((
                                Kind::Plate { .. } | Kind::Weighted { .. } | Kind::Button { .. },
                                _
                            ))
                        );
                        let wire = matches!(self.kind_of(state), Some((Kind::Tripwire, _)));
                        if wire {
                            let bounds = self
                                .power_facts()
                                .map(|f| f.bounds(state, pos))
                                .unwrap_or_default();
                            if !deflated.intersects(&bounds) {
                                continue;
                            }
                        } else if !touchable {
                            continue;
                        }
                        self.entity_inside(pos);
                    }
                }
            }
        }
    }

    /// `entityInside` of the block at `pos`.
    fn entity_inside(&mut self, pos: [i32; 3]) {
        let state = self.world.get(pos);
        let Some((kind, sounds)) = self.kind_of(state) else {
            return;
        };
        let table = self.rules.table.clone();
        match kind {
            Kind::Plate { .. } | Kind::Weighted { .. } => {
                if Self::plate_signal(&table, state, kind) == 0 {
                    self.plate_check(pos, state, kind, 0, sounds);
                }
            }
            Kind::Button { ticks, arrows } => {
                if arrows && !flag(&table, state, "powered") {
                    self.button_check(pos, state, ticks, arrows, sounds);
                }
            }
            Kind::Tripwire => {
                let block = table.block_of(state);
                if !flag(&table, state, "powered") && !self.world.has_block_tick(pos, block) {
                    // The entity itself is the list; none ignores triggers.
                    self.tripwire_check(pos, true);
                }
            }
            _ => {}
        }
    }

    /// A daylight detector's block-entity tick at a twentieth game tick.
    pub fn daylight_tick(&mut self, pos: [i32; 3]) {
        if !self.world.owns(pos) {
            return;
        }
        let state = self.world.get(pos);
        if matches!(self.kind_of(state), Some((Kind::Daylight, _))) {
            self.daylight_update(pos, state);
        }
    }

    /// `LecternBlock.signalPageChange`.
    pub fn page_turned(&mut self, pos: [i32; 3]) {
        if !self.world.owns(pos) {
            return;
        }
        let state = self.world.get(pos);
        if !matches!(self.kind_of(state), Some((Kind::Lectern, _))) {
            return;
        }
        self.lectern_powered(pos, state, true);
        let block = self.rules.table.block_of(state);
        self.world.schedule_block_tick(pos, block, 2);
        self.report.events.push((pos, PAGE, 0));
    }

    /// `TargetBlock.updateRedstoneOutput` for a projectile hit of `power`
    /// (an arrow's lasts 20 ticks, others' 8).
    pub fn target_hit(&mut self, pos: [i32; 3], power: i32, arrow: bool) {
        if !self.world.owns(pos) {
            return;
        }
        let state = self.world.get(pos);
        if !matches!(self.kind_of(state), Some((Kind::Target, _))) {
            return;
        }
        let table = self.rules.table.clone();
        let block = table.block_of(state);
        if !self.world.has_block_tick(pos, block) {
            let new = with_int(&table, state, "power", power.clamp(1, 15));
            self.set_block(pos, new, ALL, UPDATE_LIMIT);
            self.world
                .schedule_block_tick(pos, block, if arrow { 20 } else { 8 });
        }
    }

    /// `setPlacedBy` of a tripwire hook (its line) or a diode (a tick if
    /// it should turn on).
    pub fn placed_by(&mut self, pos: [i32; 3]) {
        if !self.world.owns(pos) {
            return;
        }
        let state = self.world.get(pos);
        match self.kind_of(state) {
            Some((Kind::Hook, _)) => self.calculate_state(pos, state, false, false, -1, None),
            Some((kind @ (Kind::Repeater | Kind::Comparator), _))
                if self.decide(|e| e.diode_turns_on(pos, state, kind)) == Some(true) =>
            {
                let block = self.rules.table.block_of(state);
                self.world.schedule_block_tick(pos, block, 1);
            }
            _ => {}
        }
    }

    /// A block entity's `setChanged` at `pos` (a container's contents): the
    /// comparators reading it hear (`updateNeighbourForOutputSignal`).
    pub fn output_changed(&mut self, pos: [i32; 3]) {
        if !self.world.owns(pos) {
            return;
        }
        let state = self.world.get(pos);
        if !self.rules.table.is_air(state) {
            let block = self.rules.table.block_of(state);
            self.update_neighbour_for_output_signal(pos, block);
        }
    }

    /// `TripWireBlock.playerWillDestroy` with shears: disarmed before it breaks.
    pub fn disarm(&mut self, pos: [i32; 3]) {
        if !self.world.owns(pos) {
            return;
        }
        let state = self.world.get(pos);
        if matches!(self.kind_of(state), Some((Kind::Tripwire, _))) {
            let table = self.rules.table.clone();
            self.set_block(
                pos,
                set(&table, state, "disarmed", true),
                DISARM_FLAGS,
                UPDATE_LIMIT,
            );
        }
    }

    // ---- Sources ----

    /// A torch's input: below a standing torch, behind a wall torch.
    fn torch_signal(&mut self, pos: [i32; 3], state: u16, kind: Kind) -> bool {
        if kind == Kind::Torch {
            return self.has_signal(at(pos, DOWN), DOWN);
        }
        let behind = facing(&self.rules.table, state) ^ 1;
        self.has_signal(at(pos, behind), behind)
    }

    /// `isToggledTooFrequently`.
    fn toggled_too_often(&mut self, pos: [i32; 3], add: bool) -> bool {
        if add {
            self.redstone.toggles.push((pos, self.redstone.time));
        }
        self.redstone
            .toggles
            .iter()
            .filter(|&&(p, _)| p == pos)
            .count()
            >= MAX_TOGGLES
    }

    /// `willTickThisTick`.
    fn will_tick_this_tick(&self, pos: [i32; 3], block: u16) -> bool {
        self.redstone.due.contains(&(pos, block))
    }

    /// A lever's or button's `updateNeighbours`: its cell and the block it
    /// hangs on.
    fn attached_neighbours(&mut self, pos: [i32; 3], state: u16, block: u16) {
        let table = self.rules.table.as_ref();
        let attached = match table.value(state, "face") {
            Some("floor") => DOWN,
            Some("ceiling") => UP,
            _ => facing(table, state) ^ 1,
        };
        self.update_neighbors_at(pos, block, None);
        self.update_neighbors_at(at(pos, attached), block, None);
    }

    /// `ButtonBlock.checkPressed`: pressed while an arrow touches it.
    fn button_check(
        &mut self,
        pos: [i32; 3],
        state: u16,
        ticks: i32,
        arrows: bool,
        sounds: [u16; 4],
    ) {
        let table = self.rules.table.clone();
        let block = table.block_of(state);
        let pressed = arrows && {
            let bounds = self
                .power_facts()
                .map(|f| f.bounds(state, pos))
                .unwrap_or_default();
            self.redstone
                .entities
                .iter()
                .any(|e| e.kind == super::components::EntityKind::Arrow && e.intersects(&bounds))
        };
        if pressed != flag(&table, state, "powered") {
            self.set_block(
                pos,
                set(&table, state, "powered", pressed),
                ALL,
                UPDATE_LIMIT,
            );
            self.attached_neighbours(pos, state, block);
            self.sound(
                centre(pos),
                sounds[if pressed { 0 } else { 1 }],
                1.0,
                1.0,
                false,
            );
        }
        if pressed {
            self.world.schedule_block_tick(pos, block, ticks);
        }
    }

    fn plate_signal(table: &BlockTable, state: u16, kind: Kind) -> i32 {
        match kind {
            Kind::Weighted { .. } => int(table, state, "power"),
            _ => {
                if flag(table, state, "powered") {
                    15
                } else {
                    0
                }
            }
        }
    }

    /// `BasePressurePlateBlock.checkPressed`.
    fn plate_check(&mut self, pos: [i32; 3], state: u16, kind: Kind, old: i32, sounds: [u16; 4]) {
        let table = self.rules.table.clone();
        let block = table.block_of(state);
        // `TOUCH_AABB`: 14 wide, 4 high.
        let p = pos.map(f64::from);
        let touch = [
            p[0] + 1.0 / 16.0,
            p[1],
            p[2] + 1.0 / 16.0,
            p[0] + 15.0 / 16.0,
            p[1] + 0.25,
            p[2] + 15.0 / 16.0,
        ];
        let count = |living: bool| {
            self.redstone
                .entities
                .iter()
                .filter(|e| {
                    (!living || e.kind == super::components::EntityKind::Living)
                        && e.intersects(&touch)
                })
                .count() as i32
        };
        let signal = match kind {
            Kind::Plate { mobs } => {
                if count(mobs) > 0 {
                    15
                } else {
                    0
                }
            }
            Kind::Weighted { max } => {
                let n = count(false).min(max);
                if n > 0 {
                    (n.min(max) as f32 / max as f32 * 15.0).ceil() as i32
                } else {
                    0
                }
            }
            _ => 0,
        };
        if old != signal {
            let new = match kind {
                Kind::Weighted { .. } => with_int(&table, state, "power", signal),
                _ => set(&table, state, "powered", signal > 0),
            };
            self.set_block(pos, new, CLIENTS, UPDATE_LIMIT);
            self.update_neighbors_at(pos, block, None);
            self.update_neighbors_at(at(pos, DOWN), block, None);
        }
        let (was, is) = (old > 0, signal > 0);
        if !is && was {
            self.sound(centre(pos), sounds[1], 1.0, 1.0, false);
        } else if is && !was {
            self.sound(centre(pos), sounds[0], 1.0, 1.0, false);
        }
        if is {
            let delay = if matches!(kind, Kind::Weighted { .. }) {
                10
            } else {
                20
            };
            self.world.schedule_block_tick(pos, block, delay);
        }
    }

    /// `DaylightDetectorBlock.updateSignalStrength`.
    fn daylight_update(&mut self, pos: [i32; 3], state: u16) {
        let table = self.rules.table.clone();
        let sky = self.world.sky_light(pos);
        let brightness = (sky - self.redstone.sky_darken).max(0);
        let inverted = flag(&table, state, "inverted");
        let target = daylight_power(brightness, self.redstone.sun_angle, inverted);
        if int(&table, state, "power") != target {
            self.set_block(
                pos,
                with_int(&table, state, "power", target),
                ALL,
                UPDATE_LIMIT,
            );
        }
    }

    /// `LecternBlock.changePowered`.
    fn lectern_powered(&mut self, pos: [i32; 3], state: u16, powered: bool) {
        let table = self.rules.table.clone();
        self.set_block(
            pos,
            set(&table, state, "powered", powered),
            ALL,
            UPDATE_LIMIT,
        );
        self.update_below(pos, state);
    }

    /// `LecternBlock.updateBelow`.
    fn update_below(&mut self, pos: [i32; 3], state: u16) {
        let block = self.rules.table.block_of(state);
        self.update_neighbors_at(at(pos, DOWN), block, None);
    }

    // ---- Diodes and observers (VMC-048a) ----

    /// `DiodeBlock.getDelay`: a repeater's two ticks per step, a comparator's 2.
    fn diode_delay(&self, state: u16, kind: Kind) -> i32 {
        match kind {
            Kind::Repeater => int(&self.rules.table, state, "delay") * 2,
            _ => COMPARATOR_DELAY,
        }
    }

    /// `getInputSignal`: the signal from behind (wire's power at least); a
    /// comparator reads an analog output there, or behind a conductor there.
    /// Item frames do not exist yet.
    fn diode_input(&mut self, pos: [i32; 3], state: u16, kind: Kind) -> i32 {
        let table = self.rules.table.clone();
        let f = facing(&table, state);
        let target = at(pos, f);
        let mut input = self.level_signal(target, f);
        let target_state = self.world.get(target);
        if input < 15 && self.is_wire(target_state) {
            input = input.max(int(&table, target_state, "power"));
        }
        if kind == Kind::Comparator {
            let conductor = crate::worldgen::blocks::REDSTONE_CONDUCTOR;
            if self.has_analog(target_state) {
                input = self.analog_signal(target, target_state);
            } else if input < 15 && table.flag2(target_state, conductor) {
                let behind = at(target, f);
                let behind_state = self.world.get(behind);
                if self.has_analog(behind_state) {
                    input = self.analog_signal(behind, behind_state);
                }
            }
        }
        input
    }

    /// `shouldTurnOn`: a repeater's input; a comparator's input over its
    /// side's (or equal in compare mode).
    fn diode_turns_on(&mut self, pos: [i32; 3], state: u16, kind: Kind) -> bool {
        let input = self.diode_input(pos, state, kind);
        if kind == Kind::Repeater || input == 0 {
            return input > 0;
        }
        let rules = self.rules;
        let side = rules.alternate_signal(&mut self.world, pos, state, false);
        input > side || input == side && self.rules.table.value(state, "mode") == Some("compare")
    }

    /// `ComparatorBlock.calculateOutputSignal`.
    fn comparator_value(&mut self, pos: [i32; 3], state: u16) -> i32 {
        let input = self.diode_input(pos, state, Kind::Comparator);
        if input == 0 {
            return 0;
        }
        let rules = self.rules;
        let side = rules.alternate_signal(&mut self.world, pos, state, false);
        if side > input {
            0
        } else if self.rules.table.value(state, "mode") == Some("subtract") {
            input - side
        } else {
            input
        }
    }

    fn diode_locked(&mut self, pos: [i32; 3], state: u16, kind: Kind) -> bool {
        let rules = self.rules;
        kind == Kind::Repeater && rules.repeater_locked(&mut self.world, pos, state)
    }

    /// `shouldPrioritize`: a diode in front that does not face it.
    fn diode_prioritized(&mut self, pos: [i32; 3], state: u16) -> bool {
        let table = self.rules.table.clone();
        let front = facing(&table, state) ^ 1;
        let ahead = self.world.get(at(pos, front));
        self.rules.redstone.is_diode(table.block_of(ahead)) && facing(&table, ahead) != front
    }

    /// `DiodeBlock.neighborChanged` with the state it is told it holds: one
    /// without a rigid floor pops off (`dropResources`, `removeBlock`, its
    /// neighbours told), any other checks for a tick.
    fn diode_neighbor_changed(&mut self, pos: [i32; 3], state: u16, kind: Kind) {
        let table = self.rules.table.clone();
        let block = table.block_of(state);
        if table.block_of(self.world.get(pos)) != block {
            return;
        }
        let rules = self.rules;
        let Some(survives) = self.decide(|e| rules.diode_survives(&mut e.world, state, pos, None))
        else {
            return;
        };
        if !survives {
            self.report.destroyed.push(super::updater::Destroyed {
                pos,
                state,
                drops: true,
                effects: false,
            });
            self.remove_block(pos);
            for d in 0..6 {
                self.update_neighbors_at(at(pos, d), block, None);
            }
            return;
        }
        let on = flag(&table, state, "powered");
        let priority = self.decide(|e| match kind {
            Kind::Repeater => {
                if e.diode_locked(pos, state, kind) {
                    return None;
                }
                let turns_on = e.diode_turns_on(pos, state, kind);
                if on == turns_on || e.will_tick_this_tick(pos, block) {
                    return None;
                }
                Some(if e.diode_prioritized(pos, state) {
                    EXTREMELY_HIGH
                } else if on {
                    VERY_HIGH
                } else {
                    HIGH
                })
            }
            _ => {
                if e.will_tick_this_tick(pos, block) {
                    return None;
                }
                let output = e.comparator_value(pos, state);
                let old = e.world.comparator_output(pos);
                if output == old && on == e.diode_turns_on(pos, state, kind) {
                    return None;
                }
                Some(if e.diode_prioritized(pos, state) {
                    HIGH
                } else {
                    NORMAL
                })
            }
        });
        if let Some(Some(priority)) = priority {
            let delay = self.diode_delay(state, kind);
            self.world
                .schedule_block_tick_priority(pos, block, delay, priority);
        }
    }

    /// `DiodeBlock.tick` of a repeater: unless locked, it turns off, or on
    /// (then off again after its delay unless its input holds).
    fn repeater_tick(&mut self, pos: [i32; 3], state: u16) {
        let table = self.rules.table.clone();
        let Some(Some(turns_on)) = self.decide(|e| {
            (!e.diode_locked(pos, state, Kind::Repeater))
                .then(|| e.diode_turns_on(pos, state, Kind::Repeater))
        }) else {
            return;
        };
        let on = flag(&table, state, "powered");
        if on && !turns_on {
            self.set_block(
                pos,
                set(&table, state, "powered", false),
                CLIENTS,
                UPDATE_LIMIT,
            );
        } else if !on {
            self.set_block(
                pos,
                set(&table, state, "powered", true),
                CLIENTS,
                UPDATE_LIMIT,
            );
            if !turns_on {
                let delay = self.diode_delay(state, Kind::Repeater);
                let block = table.block_of(state);
                self.world
                    .schedule_block_tick_priority(pos, block, delay, VERY_HIGH);
            }
        }
    }

    /// `ComparatorBlock.refreshOutputState`: its block entity takes the new
    /// output; a change, or compare mode, sets its powered state and tells
    /// its front.
    fn comparator_refresh(&mut self, pos: [i32; 3], state: u16) {
        let table = self.rules.table.clone();
        let Some((output, turns_on)) = self.decide(|e| {
            (
                e.comparator_value(pos, state),
                e.diode_turns_on(pos, state, Kind::Comparator),
            )
        }) else {
            return;
        };
        let old = self.world.comparator_output(pos);
        self.world.set_comparator_output(pos, Some(output));
        if old != output || table.value(state, "mode") == Some("compare") {
            let on = flag(&table, state, "powered");
            if on && !turns_on {
                self.set_block(
                    pos,
                    set(&table, state, "powered", false),
                    CLIENTS,
                    UPDATE_LIMIT,
                );
            } else if !on && turns_on {
                self.set_block(
                    pos,
                    set(&table, state, "powered", true),
                    CLIENTS,
                    UPDATE_LIMIT,
                );
            }
            self.update_neighbors_in_front(pos, state);
        }
    }

    /// `ObserverBlock.tick`: a pulse of two ticks, its front told at each end.
    fn observer_tick(&mut self, pos: [i32; 3], state: u16) {
        let table = self.rules.table.clone();
        if flag(&table, state, "powered") {
            self.set_block(
                pos,
                set(&table, state, "powered", false),
                CLIENTS,
                UPDATE_LIMIT,
            );
        } else {
            self.set_block(
                pos,
                set(&table, state, "powered", true),
                CLIENTS,
                UPDATE_LIMIT,
            );
            let block = table.block_of(state);
            self.world.schedule_block_tick(pos, block, OBSERVER_DELAY);
        }
        self.update_neighbors_in_front(pos, state);
    }

    /// `updateNeighborsInFront` of a diode or observer: the cell its signal
    /// goes to, then that cell's neighbours but itself.
    fn update_neighbors_in_front(&mut self, pos: [i32; 3], state: u16) {
        let table = self.rules.table.as_ref();
        let f = facing(table, state);
        let block = table.block_of(state);
        let front = at(pos, f ^ 1);
        self.neighbor_changed_at(front, block);
        self.update_neighbors_at(front, block, Some(f));
    }

    // ---- Tripwire ----

    /// `TripWireBlock.checkPressed` with whether an entity presses it.
    fn tripwire_check(&mut self, pos: [i32; 3], pressed: bool) {
        let table = self.rules.table.clone();
        let state = self.world.get(pos);
        let block = table.block_of(state);
        let was = flag(&table, state, "powered");
        if pressed != was {
            let new = set(&table, state, "powered", pressed);
            self.set_block(pos, new, ALL, UPDATE_LIMIT);
            self.update_source(pos, new);
        }
        if pressed {
            self.world.schedule_block_tick(pos, block, TRIPWIRE_RECHECK);
        } else if was {
            self.world.schedule_block_tick(pos, block, 1);
        }
    }

    /// `TripWireBlock.updateSource`: the hooks south and west along the wire.
    fn update_source(&mut self, pos: [i32; 3], state: u16) {
        let Some(facts) = self.power_facts() else {
            return;
        };
        let (hook, tripwire) = (facts.hook, facts.tripwire);
        let table = self.rules.table.clone();
        for d in [3, 4] {
            for i in 1..HOOK_RANGE {
                let test = step(pos, d, i);
                let Some(found) = self.read_owned(test) else {
                    break;
                };
                let block = table.block_of(found);
                if block == hook {
                    if facing(&table, found) == d ^ 1 {
                        self.calculate_state(test, found, false, true, i, Some(state));
                    }
                    break;
                }
                if block != tripwire {
                    break;
                }
            }
        }
    }

    fn read_owned(&mut self, pos: [i32; 3]) -> Option<u16> {
        if self.world.owns(pos) {
            Some(self.world.get(pos))
        } else {
            self.report.stopped += 1;
            None
        }
    }

    /// `TripWireHookBlock.calculateState`.
    fn calculate_state(
        &mut self,
        pos: [i32; 3],
        state: u16,
        destroyed: bool,
        can_update: bool,
        source: i32,
        source_state: Option<u16>,
    ) {
        let Some(facts) = self.power_facts() else {
            return;
        };
        let (hook, tripwire) = (facts.hook, facts.tripwire);
        let hook_sounds = facts
            .component(&self.rules.table, state)
            .map(|c| c.sounds)
            .unwrap_or_default();
        let table = self.rules.table.clone();
        if !table.has_property(state, "facing") {
            return;
        }
        let direction = facing(&table, state);
        let was_attached = flag(&table, state, "attached");
        let was_powered = flag(&table, state, "powered");
        let block = table.block_of(state);
        let mut attached = !destroyed;
        let mut powered = false;
        let mut receiver = 0;
        let mut wires: [Option<u16>; HOOK_RANGE as usize] = [None; HOOK_RANGE as usize];
        for i in 1..HOOK_RANGE {
            let test = step(pos, direction, i);
            let Some(mut wire) = self.read_owned(test) else {
                return;
            };
            if table.block_of(wire) == hook {
                if facing(&table, wire) == direction ^ 1 {
                    receiver = i;
                }
                break;
            }
            if table.block_of(wire) != tripwire && i != source {
                wires[i as usize] = None;
                attached = false;
            } else {
                if i == source {
                    wire = source_state.unwrap_or(wire);
                }
                let armed = !flag(&table, wire, "disarmed");
                powered |= armed && flag(&table, wire, "powered");
                wires[i as usize] = Some(wire);
                if i == source {
                    self.world.schedule_block_tick(pos, block, TRIPWIRE_RECHECK);
                    attached &= armed;
                }
            }
        }
        attached &= receiver > 1;
        powered &= attached;
        let base = table.default_state_of(block);
        let new = set(
            &table,
            set(&table, base, "attached", attached),
            "powered",
            powered,
        );
        if receiver > 0 {
            let test = step(pos, direction, receiver);
            let opposite = direction ^ 1;
            let other = table.with(new, "facing", NAMES[opposite]).unwrap_or(new);
            self.set_block(test, other, ALL, UPDATE_LIMIT);
            self.hook_neighbours(block, test, opposite);
            if table.block_of(self.world.get(pos)) != hook {
                self.hook_removed(new, pos, hook_sounds);
                return;
            }
            self.emit_hook(
                test,
                attached,
                powered,
                was_attached,
                was_powered,
                hook_sounds,
            );
        }
        self.emit_hook(
            pos,
            attached,
            powered,
            was_attached,
            was_powered,
            hook_sounds,
        );
        if !destroyed {
            let own = table.with(new, "facing", NAMES[direction]).unwrap_or(new);
            self.set_block(pos, own, ALL, UPDATE_LIMIT);
            if can_update {
                self.hook_neighbours(block, pos, direction);
            }
        }
        if was_attached != attached {
            for i in 1..receiver {
                let test = step(pos, direction, i);
                let Some(wire) = wires[i as usize] else {
                    continue;
                };
                let now = table.block_of(self.world.get(test));
                if now == tripwire || now == hook {
                    let new = table
                        .with(wire, "attached", if attached { "true" } else { "false" })
                        .unwrap_or(wire);
                    self.set_block(test, new, ALL, UPDATE_LIMIT);
                }
            }
        }
    }

    /// `TripWireHookBlock.emitState`'s sounds: click on and off, attach and
    /// detach.
    fn emit_hook(
        &mut self,
        pos: [i32; 3],
        attached: bool,
        powered: bool,
        was_attached: bool,
        was_powered: bool,
        sounds: [u16; 4],
    ) {
        if powered && !was_powered {
            self.sound(centre(pos), sounds[0], 0.4, 0.6, false);
        } else if !powered && was_powered {
            self.sound(centre(pos), sounds[1], 0.4, 0.5, false);
        } else if attached && !was_attached {
            self.sound(centre(pos), sounds[2], 0.4, 0.7, false);
        } else if !attached && was_attached {
            let pitch = 1.2 / (self.world.next_float() * 0.2 + 0.9);
            self.sound(centre(pos), sounds[3], 0.4, pitch, false);
        }
    }

    /// `TripWireHookBlock.notifyNeighbors`.
    fn hook_neighbours(&mut self, block: u16, pos: [i32; 3], direction: usize) {
        let front = direction ^ 1;
        self.update_neighbors_at(pos, block, None);
        self.update_neighbors_at(at(pos, front), block, None);
    }

    /// `TripWireHookBlock.onRemoved`.
    fn hook_removed(&mut self, state: u16, pos: [i32; 3], _sounds: [u16; 4]) {
        let table = self.rules.table.clone();
        let attached = flag(&table, state, "attached");
        let powered = flag(&table, state, "powered");
        if attached || powered {
            self.calculate_state(pos, state, true, false, -1, None);
        }
        if powered {
            self.hook_neighbours(table.block_of(state), pos, facing(&table, state));
        }
    }

    // ---- Consumers ----

    /// `NoteBlock.playNote`: a block event where the note can sound.
    fn play_note(&mut self, pos: [i32; 3], state: u16) {
        let table = self.rules.table.clone();
        let above_works = self.power_facts().is_some_and(|f| {
            let name = table.value(state, "instrument").unwrap_or("harp");
            f.instruments.iter().any(|i| i.name == name && i.above)
        });
        if above_works || table.is_air(self.world.get(at(pos, UP))) {
            let block = table.block_of(state);
            self.report.block_events.push((pos, block, 0, 0));
        }
    }

    /// `TntBlock.prime`: a primed TNT at the cell's bottom centre (its
    /// constructor draws its hop's direction), with its sound.
    fn prime(&mut self, pos: [i32; 3], sound: u16) -> bool {
        if !self.redstone.tnt_explodes {
            return false;
        }
        self.world.next_double();
        self.report.primed.push(pos);
        let p = [pos[0] as f64 + 0.5, pos[1] as f64, pos[2] as f64 + 0.5];
        self.sound(p, sound, 1.0, 1.0, false);
        true
    }

    /// `Level.removeBlock`: the cell keeps its fluid.
    fn remove_block(&mut self, pos: [i32; 3]) {
        let state = self.world.get(pos);
        let remains = self.rules.table.remains[state as usize];
        self.set_block(pos, remains, ALL, UPDATE_LIMIT);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn boxes_intersect_strictly() {
        let entity = EntityBox {
            min: [0.2, 64.0, 0.2],
            max: [0.8, 65.8, 0.8],
            kind: EntityKind::Living,
        };
        assert!(entity.intersects(&[0.0625, 64.0, 0.0625, 0.9375, 64.25, 0.9375]));
        // Standing on top of a full block does not touch the block's cell.
        assert!(!entity.intersects(&[0.0, 63.0, 0.0, 1.0, 64.0, 1.0]));
    }
}
