//! Redstone wire's power (VMC-077m), as `RedstoneWireBlock` and vanilla's
//! default `DefaultRedstoneWireEvaluator` run it: a wire's power is the
//! strongest signal its neighbours give it, or the strongest wire beside it
//! (also one step up or down) less one. A change re-evaluates the wire and
//! notifies the wire and its six neighbours in `HashSet` order; placing or
//! removing wire also reaches the wires around corners. The signals of the
//! other blocks come from the block facts (`BlockTable::signal`); while a
//! wire evaluates no wire signals (vanilla's `shouldSignal`). A comparator's,
//! trapped chest's or jukebox's signal reads its block entity and is 0 here.
//! The sources' own placement and removal hooks notify the cells their
//! signal reaches; the other components' are `components.rs`'s.

use super::at;
use super::updater::{Destroyed, Engine, Update, World, ALL, CLIENTS, UPDATE_LIMIT};
use crate::worldgen::blocks::REDSTONE_CONDUCTOR;
use crate::worldgen::javahash::JavaHashSet;

const DOWN: usize = 0;
const UP: usize = 1;
/// `Direction.Plane.HORIZONTAL`: north, east, south, west.
const HORIZONTAL: [usize; 4] = [2, 5, 3, 4];
const NAMES: [&str; 6] = ["down", "up", "north", "south", "west", "east"];
const POWERS: [&str; 16] = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15",
];

/// The direction a `facing` value names (north if none).
fn facing(value: Option<&str>) -> usize {
    NAMES.iter().position(|n| Some(*n) == value).unwrap_or(2)
}

impl<W: World> Engine<'_, W> {
    pub(super) fn is_wire(&self, state: u16) -> bool {
        self.rules.table.block_of(state) == self.rules.redstone.wire
    }

    fn conductor(&self, state: u16) -> bool {
        self.rules.table.flag2(state, REDSTONE_CONDUCTOR)
    }

    fn power(&self, state: u16) -> i32 {
        if !self.is_wire(state) {
            return 0;
        }
        let power = self.rules.table.value(state, "power");
        power.and_then(|p| p.parse().ok()).unwrap_or(0)
    }

    /// The state at `pos`, or `None` (an update stopped at the border) where
    /// the owner does not hold it.
    fn read(&mut self, pos: [i32; 3]) -> Option<u16> {
        if self.world.owns(pos) {
            Some(self.world.get(pos))
        } else {
            self.report.stopped += 1;
            None
        }
    }

    /// `onPlace` of the state now at `pos` (`old` was there).
    pub(super) fn placed(&mut self, pos: [i32; 3], old: u16, state: u16) {
        let table = self.rules.table.as_ref();
        if self.is_wire(state) && !self.is_wire(old) {
            self.wire_placed(pos, state);
        } else if matches!(
            table.class_name(state),
            "RedstoneTorchBlock" | "RedstoneWallTorchBlock"
        ) {
            self.notify_around(pos, table.block_of(state));
        } else {
            self.component_placed(pos, old, state);
        }
    }

    /// `affectNeighborsAfterRemoval` of the block `state` that left `pos`.
    pub(super) fn removed(&mut self, pos: [i32; 3], state: u16) {
        let table = self.rules.table.as_ref();
        let block = table.block_of(state);
        // Levers, buttons and plates give the same signal toward every side.
        let powered = table.signal(state, UP) > 0;
        match table.class_name(state) {
            _ if self.is_wire(state) => self.wire_removed(pos, state),
            "RedstoneTorchBlock" | "RedstoneWallTorchBlock" => self.notify_around(pos, block),
            // `updateNeighbours`: the lever's or button's cell and the block it
            // is attached to.
            "LeverBlock" | "ButtonBlock" if powered => {
                let attached = match table.value(state, "face") {
                    Some("floor") => DOWN,
                    Some("ceiling") => UP,
                    _ => facing(table.value(state, "facing")) ^ 1,
                };
                self.update_neighbors_at(pos, block, None);
                self.update_neighbors_at(at(pos, attached), block, None);
            }
            "PressurePlateBlock" | "WeightedPressurePlateBlock" if powered => {
                self.update_neighbors_at(pos, block, None);
                self.update_neighbors_at(at(pos, DOWN), block, None);
            }
            _ => self.component_removed(pos, state),
        }
    }

    /// A redstone torch's `notifyNeighbors`: every neighbour's neighbours.
    fn notify_around(&mut self, pos: [i32; 3], block: u16) {
        for d in 0..6 {
            self.update_neighbors_at(at(pos, d), block, None);
        }
    }

    /// `RedstoneWireBlock.onPlace`: wire is new at `pos`.
    fn wire_placed(&mut self, pos: [i32; 3], state: u16) {
        let wire = self.rules.redstone.wire;
        self.update_power(pos, state);
        for d in [UP, DOWN] {
            self.update_neighbors_at(at(pos, d), wire, None);
        }
        self.update_neighboring_wires(pos);
    }

    /// `RedstoneWireBlock.affectNeighborsAfterRemoval`: the wire `state` left
    /// `pos`.
    fn wire_removed(&mut self, pos: [i32; 3], state: u16) {
        let wire = self.rules.redstone.wire;
        for d in 0..6 {
            self.update_neighbors_at(at(pos, d), wire, None);
        }
        self.update_power(pos, state);
        self.update_neighboring_wires(pos);
    }

    /// `RedstoneWireBlock.neighborChanged`: wire without a floor pops off
    /// (`dropResources`, `removeBlock`), any other re-evaluates its power.
    pub(super) fn wire_neighbor_changed(&mut self, pos: [i32; 3], state: u16) {
        let Some(below) = self.read(at(pos, DOWN)) else {
            return;
        };
        let table = self.rules.table.as_ref();
        if self.rules.redstone.can_survive_on(table, below) {
            self.update_power(pos, state);
        } else {
            self.report.destroyed.push(Destroyed {
                pos,
                state,
                drops: true,
                effects: false,
            });
            let remains = table.remains[state as usize];
            self.set_block(pos, remains, ALL, UPDATE_LIMIT);
        }
    }

    /// `RedstoneWireBlock.updateIndirectNeighbourShapes`: a wire's sides
    /// that run up or down a block update the wire there.
    pub(super) fn indirect_shapes(&mut self, state: u16, pos: [i32; 3], flags: i32, limit: i32) {
        if !self.is_wire(state) {
            return;
        }
        for d in HORIZONTAL {
            let table = self.rules.table.as_ref();
            if !super::redstone::RedstoneWire::connected(table, state, d) {
                continue;
            }
            let beside = at(pos, d);
            match self.read(beside) {
                Some(s) if !self.is_wire(s) => {}
                _ => continue,
            }
            for v in [DOWN, UP] {
                let corner = at(beside, v);
                if !self.read(corner).is_some_and(|s| self.is_wire(s)) {
                    continue;
                }
                let neighbor_pos = at(corner, d ^ 1);
                let Some(neighbor_state) = self.read(neighbor_pos) else {
                    continue;
                };
                self.add(Update::Shape {
                    direction: d ^ 1,
                    neighbor_state,
                    pos: corner,
                    neighbor_pos,
                    flags,
                    limit,
                });
            }
        }
    }

    /// `DefaultRedstoneWireEvaluator.updatePowerStrength`; an evaluation
    /// that reads past the owner's border stops there.
    fn update_power(&mut self, pos: [i32; 3], state: u16) {
        let mark = self.world.begin();
        let target = self.target_strength(pos);
        if self.world.crossed(mark) {
            self.report.stopped += 1;
            return;
        }
        if self.power(state) == target {
            return;
        }
        if self.world.get(pos) == state {
            let table = self.rules.table.as_ref();
            let powered = table.with(state, "power", POWERS[target as usize]);
            self.set_block(pos, powered.unwrap_or(state), CLIENTS, UPDATE_LIMIT);
        }
        let mut notified = JavaHashSet::new();
        notified.insert(pos);
        for d in 0..6 {
            notified.insert(at(pos, d));
        }
        let wire = self.rules.redstone.wire;
        for p in notified.iter().collect::<Vec<_>>() {
            self.update_neighbors_at(p, wire, None);
        }
    }

    /// `calculateTargetStrength`.
    fn target_strength(&mut self, pos: [i32; 3]) -> i32 {
        let block = self.best_neighbor_signal(pos);
        if block == 15 {
            15
        } else {
            block.max(self.incoming_wire_signal(pos))
        }
    }

    /// `getBestNeighborSignal`, while no wire signals.
    fn best_neighbor_signal(&mut self, pos: [i32; 3]) -> i32 {
        let mut best = 0;
        for d in 0..6 {
            let signal = self.signal(at(pos, d), d);
            if signal >= 15 {
                return 15;
            }
            best = best.max(signal);
        }
        best
    }

    /// `SignalGetter.getSignal`: a conductor also passes on the strongest
    /// direct signal into it.
    fn signal(&mut self, pos: [i32; 3], d: usize) -> i32 {
        let state = self.world.get(pos);
        let signal = self.rules.table.signal(state, d);
        if self.conductor(state) {
            signal.max(self.direct_signal_to(pos))
        } else {
            signal
        }
    }

    /// `getDirectSignalTo`: below, above, north, south, west, east.
    fn direct_signal_to(&mut self, pos: [i32; 3]) -> i32 {
        let mut result = 0;
        for d in 0..6 {
            let state = self.world.get(at(pos, d));
            result = result.max(self.rules.table.direct_signal(state, d));
            if result >= 15 {
                break;
            }
        }
        result
    }

    /// `getIncomingWireSignal`.
    fn incoming_wire_signal(&mut self, pos: [i32; 3]) -> i32 {
        let mut wire = 0;
        for d in HORIZONTAL {
            let neighbor = at(pos, d);
            let state = self.world.get(neighbor);
            wire = wire.max(self.power(state));
            let above = self.world.get(at(pos, UP));
            if self.conductor(state) && !self.conductor(above) {
                let s = self.world.get(at(neighbor, UP));
                wire = wire.max(self.power(s));
            } else if !self.conductor(state) {
                let s = self.world.get(at(neighbor, DOWN));
                wire = wire.max(self.power(s));
            }
        }
        (wire - 1).max(0)
    }

    /// `updateNeighborsOfNeighboringWires`.
    fn update_neighboring_wires(&mut self, pos: [i32; 3]) {
        for d in HORIZONTAL {
            self.check_corner(at(pos, d));
        }
        for d in HORIZONTAL {
            let target = at(pos, d);
            let Some(state) = self.read(target) else {
                continue;
            };
            let v = if self.conductor(state) { UP } else { DOWN };
            self.check_corner(at(target, v));
        }
    }

    /// `checkCornerChangeAt`.
    fn check_corner(&mut self, pos: [i32; 3]) {
        if !self.read(pos).is_some_and(|s| self.is_wire(s)) {
            return;
        }
        let wire = self.rules.redstone.wire;
        self.update_neighbors_at(pos, wire, None);
        for d in 0..6 {
            self.update_neighbors_at(at(pos, d), wire, None);
        }
    }
}
