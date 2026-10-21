//! Redstone wire's shape update (VMC-025f): its connections to its
//! neighbours, as `RedstoneWireBlock.updateShape` makes them when a
//! structure template places wire (a woodland mansion's rooms) or live play
//! changes a block beside it. Wire reads up to twelve cells, too many to
//! tabulate as the shape facts do. Its power is `wire.rs`.

use crate::worldgen::blocks::{BlockTable, REDSTONE_CONDUCTOR, SIGNAL_SOURCE, STURDY};

/// `Direction` indices (down, up, north, south, west, east) and the
/// horizontal ones in `Plane.HORIZONTAL` order.
const UP: usize = 1;
const HORIZONTAL: [usize; 4] = [2, 5, 3, 4];
const STEP: [[i32; 3]; 6] = [
    [0, -1, 0],
    [0, 1, 0],
    [0, 0, -1],
    [0, 0, 1],
    [-1, 0, 0],
    [1, 0, 0],
];
const NAMES: [&str; 6] = ["down", "up", "north", "south", "west", "east"];

fn opposite(d: usize) -> usize {
    d ^ 1
}

fn at(pos: [i32; 3], d: usize) -> [i32; 3] {
    [
        pos[0] + STEP[d][0],
        pos[1] + STEP[d][1],
        pos[2] + STEP[d][2],
    ]
}

/// The blocks wire's connections look for.
#[derive(Debug)]
pub struct RedstoneWire {
    pub wire: u16,
    repeater: u16,
    observer: u16,
    hopper: u16,
    air: u16,
}

impl RedstoneWire {
    pub fn new(table: &BlockTable) -> Result<RedstoneWire, String> {
        Ok(RedstoneWire {
            wire: table.block("redstone_wire")?,
            repeater: table.block("repeater")?,
            observer: table.block("observer")?,
            hopper: table.block("hopper")?,
            air: table.default_state("air")?,
        })
    }

    fn side(table: &BlockTable, state: u16, d: usize) -> &str {
        table.value(state, NAMES[d]).unwrap_or("none")
    }

    pub(crate) fn connected(table: &BlockTable, state: u16, d: usize) -> bool {
        Self::side(table, state, d) != "none"
    }

    fn sturdy(table: &BlockTable, state: u16, d: usize) -> bool {
        table.flag(state, STURDY << d)
    }

    /// `canSurviveOn`: a sturdy top, or a hopper.
    pub(crate) fn can_survive_on(&self, table: &BlockTable, state: u16) -> bool {
        Self::sturdy(table, state, UP) || table.block_of(state) == self.hopper
    }

    /// `shouldConnectTo(state, direction)`.
    fn should_connect_to(&self, table: &BlockTable, state: u16, d: Option<usize>) -> bool {
        let block = table.block_of(state);
        let facing = || {
            table
                .value(state, "facing")
                .and_then(|f| NAMES.iter().position(|n| *n == f))
        };
        if block == self.wire {
            true
        } else if block == self.repeater {
            let f = facing();
            d.is_some() && (f == d || f.map(opposite) == d)
        } else if block == self.observer {
            d.is_some() && facing() == d
        } else {
            table.flag2(state, SIGNAL_SOURCE) && d.is_some()
        }
    }

    /// `getConnectingSide(level, pos, direction, canConnectUp)`.
    fn connecting_side(
        &self,
        table: &BlockTable,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        pos: [i32; 3],
        d: usize,
        can_connect_up: bool,
    ) -> &'static str {
        let relative = at(pos, d);
        let relative_state = read(relative);
        if can_connect_up {
            let placeable = table.class_name(relative_state) == "TrapDoorBlock"
                || self.can_survive_on(table, relative_state);
            if placeable && self.should_connect_to(table, read(at(relative, UP)), None) {
                return if Self::sturdy(table, relative_state, opposite(d)) {
                    "up"
                } else {
                    "side"
                };
            }
        }
        let below = at(relative, 0);
        if !self.should_connect_to(table, relative_state, Some(d))
            && (table.flag2(relative_state, REDSTONE_CONDUCTOR)
                || !self.should_connect_to(table, read(below), None))
        {
            "none"
        } else {
            "side"
        }
    }

    /// `getMissingConnections`.
    fn missing_connections(
        &self,
        table: &BlockTable,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        mut state: u16,
        pos: [i32; 3],
    ) -> u16 {
        let can_connect_up = !table.flag2(read(at(pos, UP)), REDSTONE_CONDUCTOR);
        for d in HORIZONTAL {
            if !Self::connected(table, state, d) {
                let side = self.connecting_side(table, read, pos, d, can_connect_up);
                state = table.with(state, NAMES[d], side).unwrap_or(state);
            }
        }
        state
    }

    fn is_dot(table: &BlockTable, state: u16) -> bool {
        HORIZONTAL
            .iter()
            .all(|&d| !Self::connected(table, state, d))
    }

    fn is_cross(table: &BlockTable, state: u16) -> bool {
        HORIZONTAL.iter().all(|&d| Self::connected(table, state, d))
    }

    /// `getConnectionState`.
    fn connection_state(
        &self,
        table: &BlockTable,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        state: u16,
        pos: [i32; 3],
    ) -> u16 {
        let was_dot = Self::is_dot(table, state);
        let power = table.value(state, "power").unwrap_or("0");
        let base = table.default_state_of(self.wire);
        let base = table.with(base, "power", power).unwrap_or(base);
        let mut state = self.missing_connections(table, read, base, pos);
        if was_dot && Self::is_dot(table, state) {
            return state;
        }
        let [north, east, south, west] = HORIZONTAL.map(|d| Self::connected(table, state, d));
        let north_south_empty = !north && !south;
        let east_west_empty = !east && !west;
        let set = |state: u16, d: usize| table.with(state, NAMES[d], "side").unwrap_or(state);
        if !west && north_south_empty {
            state = set(state, 4);
        }
        if !east && north_south_empty {
            state = set(state, 5);
        }
        if !north && east_west_empty {
            state = set(state, 2);
        }
        if !south && east_west_empty {
            state = set(state, 3);
        }
        state
    }

    /// `RedstoneWireBlock.updateShape` toward direction `d`.
    pub fn update_shape(
        &self,
        table: &BlockTable,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        state: u16,
        pos: [i32; 3],
        d: usize,
    ) -> u16 {
        if d == 0 {
            return if self.can_survive_on(table, read(at(pos, 0))) {
                state
            } else {
                self.air
            };
        }
        if d == UP {
            return self.connection_state(table, read, state, pos);
        }
        let can_connect_up = !table.flag2(read(at(pos, UP)), REDSTONE_CONDUCTOR);
        let side = self.connecting_side(table, read, pos, d, can_connect_up);
        if (side != "none") == Self::connected(table, state, d) && !Self::is_cross(table, state) {
            table.with(state, NAMES[d], side).unwrap_or(state)
        } else {
            // `crossState` with the power kept and this side set.
            let power = table.value(state, "power").unwrap_or("0");
            let mut cross = table.default_state_of(self.wire);
            for h in HORIZONTAL {
                cross = table.with(cross, NAMES[h], "side").unwrap_or(cross);
            }
            let cross = table.with(cross, "power", power).unwrap_or(cross);
            let cross = table.with(cross, NAMES[d], side).unwrap_or(cross);
            self.connection_state(table, read, cross, pos)
        }
    }
}
