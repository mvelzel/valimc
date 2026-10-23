//! Bubble columns (VMC-031a): water sources over soul sand or a magma block
//! fill with a column (`BubbleColumnBlock`) that pushes up or drags down. A
//! water source whose floor enables a column schedules its block tick
//! (`LiquidBlock.tryScheduleBubbleBlockColumn`, 20 ticks), which fills the
//! column upward (`BubbleColumnBlock.updateColumn`, flags 2); a column
//! checks itself 5 ticks after its floor or the source above it changes, or
//! when it can no longer stand, and turns back into water.

use super::at;
use super::updater::{Engine, World, UPDATE_LIMIT};
use crate::worldgen::blocks::{BlockSet, BlockTable, LIQUID_BLOCK};
use crate::worldgen::json::Json;

const DOWN: usize = 0;
const UP: usize = 1;
/// `Block.UPDATE_CLIENTS`: the column is set without neighbour updates.
const CLIENTS: i32 = 2;

/// The blocks and tags bubble columns read.
#[derive(Debug)]
pub struct Bubbles {
    column: u16,
    /// The column's states: pushing up, dragging down.
    push: u16,
    drag: u16,
    water: u16,
    water_block: u16,
    push_up: BlockSet,
    drag_down: BlockSet,
    /// `FluidTags.BUBBLE_COLUMN_CAN_OCCUPY`, as fluid ids.
    occupy: Vec<u8>,
}

impl Bubbles {
    pub fn new(table: &BlockTable) -> Result<Bubbles, String> {
        let column = table.block("bubble_column")?;
        let default = table.default_state_of(column);
        Ok(Bubbles {
            column,
            push: table
                .with(default, "drag", "false")
                .ok_or("bubble column")?,
            drag: table.with(default, "drag", "true").ok_or("bubble column")?,
            water: table.default_state("water")?,
            water_block: table.block("water")?,
            push_up: table
                .tag("minecraft:enables_bubble_column_push_up")?
                .clone(),
            drag_down: table
                .tag("minecraft:enables_bubble_column_drag_down")?
                .clone(),
            occupy: table.fluid_set(&Json::String("#minecraft:bubble_column_can_occupy".into()))?,
        })
    }

    pub fn is_column(&self, table: &BlockTable, state: u16) -> bool {
        table.block_of(state) == self.column
    }

    fn floor(&self, table: &BlockTable, state: u16) -> bool {
        table.in_tag(state, &self.push_up) || table.in_tag(state, &self.drag_down)
    }

    /// `LiquidBlock.shouldBubbleColumnOccupy`: a full source of a fluid
    /// columns may occupy.
    pub fn occupiable_source(&self, table: &BlockTable, state: u16) -> bool {
        let fluid = table.fluid(state);
        let level = table.fluid_level[state as usize];
        self.occupy.contains(&fluid) && (fluid == 2 || fluid == 4) && level & 15 >= 8
    }

    /// `BubbleColumnBlock.canOccupy`.
    fn can_occupy(&self, table: &BlockTable, state: u16) -> bool {
        self.is_column(table, state)
            || (table.flag(state, LIQUID_BLOCK) && self.occupiable_source(table, state))
    }

    /// `BubbleColumnBlock.getColumnState`.
    fn column_state(&self, table: &BlockTable, below: u16, occupy: u16) -> u16 {
        if self.is_column(table, below) {
            below
        } else if table.in_tag(below, &self.push_up) {
            self.push
        } else if table.in_tag(below, &self.drag_down) {
            self.drag
        } else if self.is_column(table, occupy) {
            self.water
        } else {
            occupy
        }
    }
}

impl<'r, W: World> Engine<'r, W> {
    fn bubbles(&self) -> Option<&'r Bubbles> {
        let rules = self.rules;
        rules.fluids.as_ref().map(|f| &f.bubbles)
    }

    /// `LiquidBlock.tryScheduleBubbleBlockColumn` for a water source at
    /// `pos` over `below`.
    pub(super) fn schedule_column(&mut self, pos: [i32; 3], state: u16, below: u16) {
        let table = self.rules.table.clone();
        let Some(bubbles) = self.bubbles() else {
            return;
        };
        if bubbles.occupiable_source(&table, state) && bubbles.floor(&table, below) {
            let block = table.block_of(state);
            self.world.schedule_block_tick(pos, block, 20);
        }
    }

    /// A block tick of a bubble column or of a water source over a column's
    /// floor (`BubbleColumnBlock.tick`, `LiquidBlock.tick`); whether it was
    /// one.
    pub(super) fn bubble_tick(&mut self, pos: [i32; 3], state: u16) -> bool {
        let table = self.rules.table.clone();
        let Some(bubbles) = self.bubbles() else {
            return false;
        };
        let column = bubbles.is_column(&table, state);
        if !column
            && !(table.block_of(state) == bubbles.water_block
                && bubbles.occupiable_source(&table, state))
        {
            return false;
        }
        let below = self.world.get(at(pos, DOWN));
        self.update_column(pos, state, below);
        true
    }

    /// `BubbleColumnBlock.updateColumn`: the column's state at `pos` and up
    /// through every cell a column may occupy.
    fn update_column(&mut self, pos: [i32; 3], occupy: u16, below: u16) {
        let table = self.rules.table.clone();
        let Some(bubbles) = self.bubbles() else {
            return;
        };
        if !bubbles.can_occupy(&table, occupy) {
            return;
        }
        let state = bubbles.column_state(&table, below, occupy);
        self.set_block(pos, state, CLIENTS, UPDATE_LIMIT);
        let mut up = at(pos, UP);
        loop {
            let current = self.world.get(up);
            let Some(bubbles) = self.bubbles() else {
                return;
            };
            if !self.world.owns(up) || !bubbles.can_occupy(&table, current) {
                return;
            }
            if !self.set_block(up, state, CLIENTS, UPDATE_LIMIT) {
                return;
            }
            up = at(up, UP);
        }
    }

    /// `BubbleColumnBlock.updateShape`: it schedules its water, and its own
    /// check when it cannot stand, its floor changed or a source to fill
    /// appeared above; the state stays.
    pub(super) fn column_shape(&mut self, pos: [i32; 3], d: usize, neighbor: u16) {
        let table = self.rules.table.clone();
        let Some(bubbles) = self.bubbles() else {
            return;
        };
        let below = self.world.get(at(pos, DOWN));
        let stands = bubbles.is_column(&table, below) || bubbles.floor(&table, below);
        let fill_above =
            d == UP && !bubbles.is_column(&table, neighbor) && bubbles.can_occupy(&table, neighbor);
        let column = bubbles.column;
        let delay = self.tick_delay(2);
        self.world.schedule_fluid_tick(pos, 2, delay);
        if !stands || d == DOWN || fill_above {
            self.world.schedule_block_tick(pos, column, 5);
        }
    }
}
