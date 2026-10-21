//! Fire and soul fire as decoration places and updates them (VMC-026a):
//! `BaseFireBlock.getState` (the End spikes' fire), survival and
//! `updateShape`, which read the six neighbours' flammability
//! (`FireBlock.canBurn`, from the block facts).

use crate::worldgen::blocks::{BlockSet, BlockTable, STURDY};
use crate::worldgen::predicate::offset;

/// `Direction.values()` after down, with fire's property names.
const SIDES: [([i32; 3], &str); 5] = [
    ([0, 1, 0], "up"),
    ([0, 0, -1], "north"),
    ([0, 0, 1], "south"),
    ([-1, 0, 0], "west"),
    ([1, 0, 0], "east"),
];

#[derive(Debug)]
pub struct Fire {
    fire_block: u16,
    soul_fire_block: u16,
    fire: u16,
    soul_fire: u16,
    air: u16,
    soul_base: BlockSet,
}

impl Fire {
    pub fn new(table: &BlockTable) -> Result<Fire, String> {
        Ok(Fire {
            fire_block: table.block("fire")?,
            soul_fire_block: table.block("soul_fire")?,
            fire: table.default_state("fire")?,
            soul_fire: table.default_state("soul_fire")?,
            air: table.default_state("air")?,
            soul_base: table.tag("minecraft:soul_fire_base_blocks")?.clone(),
        })
    }

    /// `BaseFireBlock.getState`: soul fire on its base blocks, else fire
    /// (`FireBlock.getStateForPlacement`: burning toward flammable sides when
    /// what is below neither burns nor holds it).
    pub fn state_at(
        &self,
        table: &BlockTable,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        pos: [i32; 3],
    ) -> u16 {
        let below = read(offset(pos, [0, -1, 0]));
        if table.in_tag(below, &self.soul_base) {
            return self.soul_fire;
        }
        if table.flammable(below) || table.flag(below, STURDY << 1) {
            return self.fire;
        }
        let mut state = self.fire;
        for (step, property) in SIDES {
            let burns = table.flammable(read(offset(pos, step)));
            state = table
                .with(state, property, if burns { "true" } else { "false" })
                .unwrap_or(state);
        }
        state
    }

    /// `FireBlock.canSurvive`.
    fn fire_survives(
        &self,
        table: &BlockTable,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        pos: [i32; 3],
    ) -> bool {
        if table.flag(read(offset(pos, [0, -1, 0])), STURDY << 1) {
            return true;
        }
        std::iter::once([0, -1, 0])
            .chain(SIDES.iter().map(|(step, _)| *step))
            .any(|step| table.flammable(read(offset(pos, step))))
    }

    /// `updateShape` of fire or soul fire; `None` for other states.
    pub fn update_shape(
        &self,
        table: &BlockTable,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        state: u16,
        pos: [i32; 3],
    ) -> Option<u16> {
        let block = table.block_of(state);
        if block == self.soul_fire_block {
            let base = table.in_tag(read(offset(pos, [0, -1, 0])), &self.soul_base);
            return Some(if base { self.soul_fire } else { self.air });
        }
        if block != self.fire_block {
            return None;
        }
        if !self.fire_survives(table, read, pos) {
            return Some(self.air);
        }
        let placed = self.state_at(table, read, pos);
        if table.block_of(placed) != self.fire_block {
            return Some(placed);
        }
        let age = table.value(state, "age")?;
        Some(table.with(placed, "age", age).unwrap_or(placed))
    }
}
