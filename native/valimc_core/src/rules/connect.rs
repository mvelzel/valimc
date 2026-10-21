//! Shape updates of the blocks that connect to their neighbours (VMC-025f):
//! stairs (`StairBlock`), fences (`FenceBlock`), bars and panes
//! (`IronBarsBlock`) and walls (`WallBlock`), whose states are too many to
//! tabulate as the shape facts do once structures place dozens of them; and
//! doors (`DoorBlock`), whose halves take the other half's state.
//! Each returns the new state and whether the block is waterlogged (vanilla
//! schedules a water tick at the block then).

use crate::worldgen::blocks::{
    BlockSet, BlockTable, CONNECTION_EXCEPTION, COVERS_WALL_POST, COVERS_WALL_SIDE, DOOR, FENCE,
    FENCE_GATE, IRON_BARS, STAIRS, STURDY, WALL,
};

/// `Direction` indices: down, up, north, south, west, east.
const NAMES: [&str; 6] = ["down", "up", "north", "south", "west", "east"];
const STEP: [[i32; 3]; 6] = [
    [0, -1, 0],
    [0, 1, 0],
    [0, 0, -1],
    [0, 0, 1],
    [-1, 0, 0],
    [1, 0, 0],
];
/// North, east, south, west.
const SIDES: [usize; 4] = [2, 5, 3, 4];

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

fn counter_clockwise(d: usize) -> usize {
    match d {
        2 => 4,
        4 => 3,
        3 => 5,
        _ => 2,
    }
}

fn clockwise(d: usize) -> usize {
    match d {
        2 => 5,
        5 => 3,
        3 => 4,
        _ => 2,
    }
}

fn is_z(d: usize) -> bool {
    d == 2 || d == 3
}

fn facing(table: &BlockTable, state: u16) -> usize {
    table
        .value(state, "facing")
        .and_then(|f| NAMES.iter().position(|n| *n == f))
        .unwrap_or(2)
}

/// The tags connections read.
#[derive(Debug)]
pub struct Connections {
    fences: BlockSet,
    wooden_fences: BlockSet,
    walls: BlockSet,
    wall_post_override: BlockSet,
    air: u16,
}

impl Connections {
    pub fn new(table: &BlockTable) -> Result<Connections, String> {
        Ok(Connections {
            fences: table.tag("minecraft:fences")?.clone(),
            wooden_fences: table.tag("minecraft:wooden_fences")?.clone(),
            walls: table.tag("minecraft:walls")?.clone(),
            wall_post_override: table.tag("minecraft:wall_post_override")?.clone(),
            air: table.default_state("air")?,
        })
    }

    /// Whether these updates cover the state.
    pub fn handles(&self, table: &BlockTable, state: u16) -> bool {
        table.flag2(state, STAIRS | FENCE | IRON_BARS | WALL | DOOR)
    }

    /// The state's `updateShape` toward direction `d`.
    pub fn update_shape(
        &self,
        table: &BlockTable,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        state: u16,
        pos: [i32; 3],
        d: usize,
    ) -> (u16, bool) {
        let waterlogged = table.value(state, "waterlogged") == Some("true");
        let new_state = if table.flag2(state, STAIRS) {
            if d < 2 {
                state
            } else {
                let shape = stairs_shape(table, read, state, pos);
                table.with(state, "shape", shape).unwrap_or(state)
            }
        } else if table.flag2(state, FENCE) {
            if d < 2 {
                state
            } else {
                let neighbour = read(at(pos, d));
                let solid = table.flag(neighbour, STURDY << opposite(d));
                let connects = self.fence_connects(table, state, neighbour, solid, opposite(d));
                table
                    .with(state, NAMES[d], if connects { "true" } else { "false" })
                    .unwrap_or(state)
            }
        } else if table.flag2(state, IRON_BARS) {
            if d < 2 {
                state
            } else {
                let neighbour = read(at(pos, d));
                let solid = table.flag(neighbour, STURDY << opposite(d));
                let attaches = (!table.flag2(neighbour, CONNECTION_EXCEPTION) && solid)
                    || table.flag2(neighbour, IRON_BARS)
                    || table.in_tag(neighbour, &self.walls);
                table
                    .with(state, NAMES[d], if attaches { "true" } else { "false" })
                    .unwrap_or(state)
            }
        } else if table.flag2(state, WALL) {
            self.wall(table, read, state, pos, d)
        } else if table.flag2(state, DOOR) {
            self.door(table, read, state, pos, d)
        } else {
            state
        };
        (new_state, waterlogged)
    }

    /// `DoorBlock.updateShape`: toward its other half a door becomes that
    /// half's door (any door, with this half) or air; a lower half without a
    /// sturdy floor breaks.
    fn door(
        &self,
        table: &BlockTable,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        state: u16,
        pos: [i32; 3],
        d: usize,
    ) -> u16 {
        let half = table.value(state, "half").unwrap_or("lower");
        let lower = half == "lower";
        if d < 2 && lower == (d == 1) {
            let neighbour = read(at(pos, d));
            if table.flag2(neighbour, DOOR) && table.value(neighbour, "half") != Some(half) {
                table.with(neighbour, "half", half).unwrap_or(neighbour)
            } else {
                self.air
            }
        } else if lower && d == 0 && !table.flag(read(at(pos, 0)), STURDY << 1) {
            self.air
        } else {
            state
        }
    }

    /// `FenceBlock.connectsTo`.
    fn fence_connects(
        &self,
        table: &BlockTable,
        fence: u16,
        state: u16,
        solid: bool,
        d: usize,
    ) -> bool {
        let same_fence = table.in_tag(state, &self.fences)
            && table.in_tag(state, &self.wooden_fences) == table.in_tag(fence, &self.wooden_fences);
        (!table.flag2(state, CONNECTION_EXCEPTION) && solid)
            || same_fence
            || gate_connects(table, state, d)
    }

    /// `WallBlock.connectsTo`.
    fn wall_connects(&self, table: &BlockTable, state: u16, solid: bool, d: usize) -> bool {
        table.in_tag(state, &self.walls)
            || (!table.flag2(state, CONNECTION_EXCEPTION) && solid)
            || table.flag2(state, IRON_BARS)
            || gate_connects(table, state, d)
    }

    /// `WallBlock.updateShape`.
    fn wall(
        &self,
        table: &BlockTable,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        state: u16,
        pos: [i32; 3],
        d: usize,
    ) -> u16 {
        if d == 0 {
            return state;
        }
        let connected = |side: usize| table.value(state, NAMES[side]).is_some_and(|v| v != "none");
        let mut sides = SIDES.map(connected);
        let above = if d == 1 {
            read(at(pos, 1))
        } else {
            let neighbour = read(at(pos, d));
            let solid = table.flag(neighbour, STURDY << opposite(d));
            let i = SIDES.iter().position(|&s| s == d).unwrap_or(0);
            sides[i] = self.wall_connects(table, neighbour, solid, opposite(d));
            read(at(pos, 1))
        };
        // `updateSides`: tall where the block above covers the side.
        let mut new_state = state;
        for (i, &side) in SIDES.iter().enumerate() {
            let value = if !sides[i] {
                "none"
            } else if table.flag2(above, COVERS_WALL_SIDE << i) {
                "tall"
            } else {
                "low"
            };
            new_state = table
                .with(new_state, NAMES[side], value)
                .unwrap_or(new_state);
        }
        let up = self.raise_post(table, new_state, above);
        table
            .with(new_state, "up", if up { "true" } else { "false" })
            .unwrap_or(new_state)
    }

    /// `WallBlock.shouldRaisePost`.
    fn raise_post(&self, table: &BlockTable, state: u16, above: u16) -> bool {
        if table.flag2(above, WALL) && table.value(above, "up") == Some("true") {
            return true;
        }
        let side = |d: usize| table.value(state, NAMES[d]).unwrap_or("none");
        let [north, east, south, west] = SIDES.map(side);
        let (north_none, east_none, south_none, west_none) = (
            north == "none",
            east == "none",
            south == "none",
            west == "none",
        );
        let corner = (north_none && south_none && west_none && east_none)
            || north_none != south_none
            || west_none != east_none;
        if corner {
            return true;
        }
        let high = (north == "tall" && south == "tall") || (east == "tall" && west == "tall");
        if high {
            return false;
        }
        table.in_tag(above, &self.wall_post_override) || table.flag2(above, COVERS_WALL_POST)
    }
}

/// `FenceGateBlock.connectsToDirection`.
fn gate_connects(table: &BlockTable, state: u16, d: usize) -> bool {
    table.flag2(state, FENCE_GATE) && is_z(facing(table, state)) == is_z(clockwise(d))
}

/// `StairBlock.getStairsShape`.
fn stairs_shape(
    table: &BlockTable,
    read: &mut dyn FnMut([i32; 3]) -> u16,
    state: u16,
    pos: [i32; 3],
) -> &'static str {
    let f = facing(table, state);
    let half = table.value(state, "half");
    let stairs = |s: u16| table.flag2(s, STAIRS);
    // `canTakeShape`.
    let can_take = |read: &mut dyn FnMut([i32; 3]) -> u16, side: usize| {
        let n = read(at(pos, side));
        !stairs(n) || facing(table, n) != f || table.value(n, "half") != half
    };
    let behind = read(at(pos, f));
    if stairs(behind) && table.value(behind, "half") == half {
        let bf = facing(table, behind);
        if is_z(bf) != is_z(f) && can_take(read, opposite(bf)) {
            return if bf == counter_clockwise(f) {
                "outer_left"
            } else {
                "outer_right"
            };
        }
    }
    let front = read(at(pos, opposite(f)));
    if stairs(front) && table.value(front, "half") == half {
        let ff = facing(table, front);
        if is_z(ff) != is_z(f) && can_take(read, ff) {
            return if ff == counter_clockwise(f) {
                "inner_left"
            } else {
                "inner_right"
            };
        }
    }
    "straight"
}
