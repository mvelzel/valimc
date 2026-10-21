//! Block rules shared by decoration and live play (VMC-077m): vanilla's
//! `canSurvive` and `updateShape`, from the generated facts and, for the
//! blocks whose rules read too much to tabulate, from code (fire, chorus,
//! connections, redstone wire, vines, speleothems, mossy carpets, corals).
//! Rules see the world through `BlockAccess`, which decoration's region and
//! the live region's store both implement.

pub mod connect;
pub mod fire;
pub mod redstone;
pub mod shapes;
pub mod support;

use std::sync::Arc;

use crate::worldgen::blocks::{
    BlockSet, BlockTable, FLUID_FLOWING_WATER, FLUID_WATER, MOSSY_CARPET, STURDY,
};
use crate::worldgen::end::Chorus;
use connect::Connections;
use fire::Fire;
use redstone::RedstoneWire;
use shapes::Shapes;
use support::Support;

/// Water's tick delay (`WaterFluid.getTickDelay`).
pub const WATER_DELAY: i32 = 5;

/// What a rule may read and schedule: block states, scheduled ticks and the
/// level's random. Delays are vanilla's; decoration's proto chunks keep none.
pub trait BlockAccess {
    fn get(&mut self, pos: [i32; 3]) -> u16;
    fn schedule_block_tick(&mut self, pos: [i32; 3], block: u16, delay: i32);
    fn schedule_fluid_tick(&mut self, pos: [i32; 3], fluid: u8, delay: i32);
    fn has_block_tick(&mut self, pos: [i32; 3], block: u16) -> bool;
    /// The level random's `nextInt(bound)`.
    fn next_int(&mut self, bound: i32) -> i32;
}

/// `Direction` steps in vanilla order: down, up, north, south, west, east.
pub const STEP: [[i32; 3]; 6] = [
    [0, -1, 0],
    [0, 1, 0],
    [0, 0, -1],
    [0, 0, 1],
    [-1, 0, 0],
    [1, 0, 0],
];

pub fn at(pos: [i32; 3], d: usize) -> [i32; 3] {
    [
        pos[0] + STEP[d][0],
        pos[1] + STEP[d][1],
        pos[2] + STEP[d][2],
    ]
}

pub struct Rules {
    pub table: Arc<BlockTable>,
    pub support: Arc<Support>,
    pub shapes: Option<Arc<Shapes>>,
    pub fire: Fire,
    pub chorus: Chorus,
    pub redstone: RedstoneWire,
    pub connections: Connections,
    vine_block: u16,
    speleothems: BlockSet,
}

impl std::fmt::Debug for Rules {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Rules")
    }
}

impl Rules {
    pub fn new(
        table: Arc<BlockTable>,
        support: Arc<Support>,
        shapes: Option<Arc<Shapes>>,
    ) -> Result<Rules, String> {
        Ok(Rules {
            fire: Fire::new(&table)?,
            chorus: Chorus::new(&table)?,
            redstone: RedstoneWire::new(&table)?,
            connections: Connections::new(&table)?,
            vine_block: table.block("vine")?,
            speleothems: table.tag("minecraft:speleothems")?.clone(),
            table,
            support,
            shapes,
        })
    }

    /// `state.canSurvive(level, pos)`, as decoration checks it.
    pub fn survives(&self, access: &mut dyn BlockAccess, state: u16, pos: [i32; 3]) -> bool {
        self.support.survives(state, pos, &mut |p| access.get(p))
    }

    /// `state.updateShape(level, level, pos, d, …)` (the cell at `replaced`
    /// reads as its given state): the new state; ticks go to `access`.
    pub fn update_shape(
        &self,
        access: &mut dyn BlockAccess,
        state: u16,
        pos: [i32; 3],
        d: usize,
        replaced: Option<([i32; 3], u16)>,
    ) -> Result<u16, String> {
        let table = self.table.as_ref();
        let class = table.class_name(state);
        if class.contains("Coral") {
            if let Some(new_state) = self.coral_update(access, replaced, class, state, pos, d) {
                return Ok(new_state);
            }
        }
        let mut read = |p: [i32; 3]| match replaced {
            Some((at, s)) if at == p => s,
            _ => access.get(p),
        };
        if let Some(new_state) = self.fire.update_shape(table, &mut read, state, pos) {
            return Ok(new_state);
        }
        if let Some((new_state, tick)) = self.chorus.update_shape(table, &mut read, state, pos, d) {
            if let Some(block) = tick {
                access.schedule_block_tick(pos, block, 1);
            }
            return Ok(new_state);
        }
        if self.connections.handles(table, state) {
            let (new_state, waterlogged) = self
                .connections
                .update_shape(table, &mut read, state, pos, d);
            if waterlogged {
                access.schedule_fluid_tick(pos, FLUID_WATER, WATER_DELAY);
            }
            return Ok(new_state);
        }
        if table.block_of(state) == self.redstone.wire {
            return Ok(self.redstone.update_shape(table, &mut read, state, pos, d));
        }
        if table.block_of(state) == self.vine_block {
            return Ok(crate::worldgen::multiface::vine_update(
                table, &mut read, state, pos, d,
            ));
        }
        if table.in_tag(state, &self.speleothems) {
            return crate::worldgen::speleothem::update_shape(table, access, state, pos, d);
        }
        if table.flag(state, MOSSY_CARPET) {
            let carpet = crate::worldgen::multiface::MossyCarpet::new(table)?;
            let air = table.default_state("air")?;
            return Ok(carpet.update_shape(&self.support, &mut read, state, pos, air));
        }
        let shapes = self.shapes.as_ref().ok_or("no shape update facts")?;
        let (new_state, ticks) = shapes.update(state, d, pos, &mut read)?;
        for tick in ticks {
            let tick_pos = [
                pos[0] + tick.offset[0],
                pos[1] + tick.offset[1],
                pos[2] + tick.offset[2],
            ];
            if tick.fluid {
                access.schedule_fluid_tick(tick_pos, tick.id as u8, tick.delay);
            } else {
                access.schedule_block_tick(tick_pos, tick.id, tick.delay);
            }
        }
        Ok(new_state)
    }

    /// The corals' `updateShape` (VMC-025f): a live coral without water
    /// beside it (or, for plants and fans, in it) schedules its death 60–99
    /// ticks out, the delay from the level's random; waterlogged plants and
    /// fans schedule water; plants and fans need a sturdy floor, wall fans
    /// the face they hang on.
    fn coral_update(
        &self,
        access: &mut dyn BlockAccess,
        replaced: Option<([i32; 3], u16)>,
        class: &str,
        state: u16,
        pos: [i32; 3],
        d: usize,
    ) -> Option<u16> {
        const NAMES: [&str; 6] = ["down", "up", "north", "south", "west", "east"];
        let neighbours: [u16; 6] = std::array::from_fn(|d| match replaced {
            Some((p, s)) if p == at(pos, d) => s,
            _ => access.get(at(pos, d)),
        });
        let table = self.table.as_ref();
        let water = |s: u16| {
            let fluid = table.fluid(s);
            fluid == FLUID_WATER || fluid == FLUID_FLOWING_WATER
        };
        let die_unless_wet = |access: &mut dyn BlockAccess| {
            if !(0..6).any(|d| water(neighbours[d])) {
                let delay = 60 + access.next_int(40);
                access.schedule_block_tick(pos, table.block_of(state), delay);
            }
        };
        let waterlogged = table.value(state, "waterlogged") == Some("true");
        let (live, wall) = match class {
            "CoralBlock" => {
                die_unless_wet(access);
                return Some(state);
            }
            "CoralPlantBlock" | "CoralFanBlock" => (true, false),
            "CoralWallFanBlock" => (true, true),
            "BaseCoralPlantBlock" | "BaseCoralFanBlock" => (false, false),
            "BaseCoralWallFanBlock" => (false, true),
            _ => return None,
        };
        // `canSurvive`: a sturdy top below, or the face behind a wall fan.
        let facing = if wall {
            NAMES
                .iter()
                .position(|n| Some(*n) == table.value(state, "facing"))
                .unwrap_or(2)
        } else {
            1
        };
        let support = if wall { facing ^ 1 } else { 0 };
        let breaks = d == support && !table.flag(neighbours[support], STURDY << facing);
        // Live corals break before anything else; dead ones schedule water
        // first.
        if breaks && live {
            return table.default_state("air").ok();
        }
        if live && !waterlogged {
            die_unless_wet(access);
        }
        if waterlogged {
            access.schedule_fluid_tick(pos, FLUID_WATER, WATER_DELAY);
        }
        if breaks {
            return table.default_state("air").ok();
        }
        Some(state)
    }
}
