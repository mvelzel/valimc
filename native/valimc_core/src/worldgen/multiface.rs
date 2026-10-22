//! Blocks that hang on the faces of their neighbours and whose updates read
//! too many cells for the generated shape facts (VMC-025b): the pale moss
//! carpet (`MossyCarpetBlock`) and vines (`VineBlock`). A face holds when the
//! neighbour's support or collision shape is full towards it
//! (`MultifaceBlock.canAttachTo`).

use super::blocks::{BlockTable, COLLISION_FULL, REPLACEABLE, STURDY};
use super::predicate::offset;
use super::region::Region;
use crate::rules::support::Support;

const DIRECTIONS: [[i32; 3]; 6] = [
    [0, -1, 0],
    [0, 1, 0],
    [0, 0, -1],
    [0, 0, 1],
    [-1, 0, 0],
    [1, 0, 0],
];

/// `MultifaceBlock.canAttachTo(level, d, neighbour)`: the neighbour's face
/// opposite `d` is full.
pub(crate) fn attaches(table: &BlockTable, neighbour: u16, d: usize) -> bool {
    let face = d ^ 1;
    table.flag(neighbour, STURDY << face) || table.flag(neighbour, COLLISION_FULL << face)
}

/// `VineBlock.updateShape` toward `d`: a face stays while its neighbour
/// holds it or the vine above has it; no faces left is air.
pub fn vine_update(
    table: &BlockTable,
    read: &mut dyn FnMut([i32; 3]) -> u16,
    mut state: u16,
    pos: [i32; 3],
    d: usize,
) -> u16 {
    if d == 0 {
        return state;
    }
    let vine = table.block_of(state);
    let above = offset(pos, [0, 1, 0]);
    let set = |s: u16, face: &str, on: bool| {
        table
            .with(s, face, if on { "true" } else { "false" })
            .unwrap_or(s)
    };
    let has = |s: u16, face: &str| table.value(s, face) == Some("true");
    if has(state, "up") {
        // `isAcceptableNeighbour(level, above, DOWN)`: the face it tests is
        // the one opposite DOWN.
        let a = read(above);
        state = set(state, "up", attaches(table, a, 0));
    }
    for (dir, face) in CARPET_SIDES {
        if !has(state, face) {
            continue;
        }
        let neighbour = read(offset(pos, DIRECTIONS[dir]));
        let mut supported = attaches(table, neighbour, dir);
        if !supported {
            let a = read(above);
            supported = table.block_of(a) == vine && has(a, face);
        }
        state = set(state, face, supported);
    }
    let faces = ["up", "north", "east", "south", "west"];
    if faces.iter().any(|f| has(state, f)) {
        state
    } else {
        table.default_state("air").unwrap_or(0)
    }
}

/// `MossyCarpetBlock` (the pale moss carpet): a base layer with walls on
/// the sides it can attach to, and a topper above them.
pub struct MossyCarpet<'t> {
    table: &'t BlockTable,
    block: u16,
    default: u16,
}

/// `Direction.Plane.HORIZONTAL` with each face's property.
const CARPET_SIDES: [(usize, &str); 4] = [(2, "north"), (5, "east"), (3, "south"), (4, "west")];

impl<'t> MossyCarpet<'t> {
    pub fn new(table: &'t BlockTable) -> Result<MossyCarpet<'t>, String> {
        Ok(MossyCarpet {
            table,
            block: table.block("pale_moss_carpet")?,
            default: table.default_state("pale_moss_carpet")?,
        })
    }

    fn is_carpet(&self, state: u16) -> bool {
        self.table.block_of(state) == self.block
    }

    fn base(&self, state: u16) -> bool {
        self.table.value(state, "bottom") == Some("true")
    }

    fn side<'a>(&'a self, state: u16, face: &str) -> &'a str {
        self.table.value(state, face).unwrap_or("none")
    }

    fn with(&self, state: u16, property: &str, value: &str) -> u16 {
        self.table.with(state, property, value).unwrap_or(state)
    }

    /// `canSupportAtFace` for a horizontal face: `MultifaceBlock.canAttachTo`,
    /// a full support or collision face towards the carpet.
    fn can_support(&self, read: &mut dyn FnMut([i32; 3]) -> u16, pos: [i32; 3], d: usize) -> bool {
        let neighbour = read(offset(pos, DIRECTIONS[d]));
        let face = d ^ 1;
        self.table.flag(neighbour, STURDY << face)
            || self.table.flag(neighbour, COLLISION_FULL << face)
    }

    /// `getUpdatedState`.
    fn updated(
        &self,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        mut state: u16,
        pos: [i32; 3],
        create_sides: bool,
    ) -> u16 {
        let create_sides = create_sides || self.base(state);
        let above = read(offset(pos, [0, 1, 0]));
        let below = read(offset(pos, [0, -1, 0]));
        for (d, face) in CARPET_SIDES {
            let mut side = if !self.can_support(read, pos, d) {
                "none"
            } else if create_sides {
                "low"
            } else {
                self.side(state, face)
            };
            if side == "low" {
                if self.is_carpet(above) && self.side(above, face) != "none" && !self.base(above) {
                    side = "tall";
                }
                if !self.base(state) && self.is_carpet(below) && self.side(below, face) == "none" {
                    side = "none";
                }
            }
            state = self.with(state, face, side);
        }
        state
    }

    fn has_faces(&self, state: u16) -> bool {
        self.base(state)
            || CARPET_SIDES
                .iter()
                .any(|(_, face)| self.side(state, face) != "none")
    }

    /// `createTopperWithSideChance` with the region's random.
    fn topper(&self, region: &mut Region, pos: [i32; 3]) -> Option<u16> {
        let above = offset(pos, [0, 1, 0]);
        let previous = region.get(above);
        let carpet_above = self.is_carpet(previous);
        if (carpet_above && self.base(previous))
            || (!carpet_above && !self.table.flag(previous, REPLACEABLE))
        {
            return None;
        }
        let no_base = self.with(self.default, "bottom", "false");
        let mut state = self.updated(&mut |p| region.get(p), no_base, above, true);
        for (_, face) in CARPET_SIDES {
            if self.side(state, face) != "none" && !region.random.next_bool() {
                state = self.with(state, face, "none");
            }
        }
        (self.has_faces(state) && state != previous).then_some(state)
    }

    /// `updateShape`: air when it cannot stay, else its sides updated.
    pub fn update_shape(
        &self,
        support: &Support,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        state: u16,
        pos: [i32; 3],
        air: u16,
    ) -> u16 {
        if !support.survives(state, pos, read) {
            return air;
        }
        let updated = self.updated(read, state, pos, false);
        if self.has_faces(updated) {
            updated
        } else {
            air
        }
    }

    /// A player's placement (`getStateForPlacement`, then `setPlacedBy`): the
    /// carpet with every side it can attach to, and the topper drawn over it
    /// (`next_bool` the level random's), which sees the carpet below it.
    pub fn place(
        &self,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        pos: [i32; 3],
        next_bool: &mut dyn FnMut() -> bool,
    ) -> (u16, Option<u16>) {
        let base = self.updated(read, self.default, pos, true);
        let above = offset(pos, [0, 1, 0]);
        let previous = read(above);
        let carpet_above = self.is_carpet(previous);
        if (carpet_above && self.base(previous))
            || (!carpet_above && !self.table.flag(previous, REPLACEABLE))
        {
            return (base, None);
        }
        let no_base = self.with(self.default, "bottom", "false");
        let mut read_placed = |p: [i32; 3]| if p == pos { base } else { read(p) };
        let mut state = self.updated(&mut read_placed, no_base, above, true);
        for (_, face) in CARPET_SIDES {
            if self.side(state, face) != "none" && !next_bool() {
                state = self.with(state, face, "none");
            }
        }
        (
            base,
            (self.has_faces(state) && state != previous).then_some(state),
        )
    }

    /// `placeAt`.
    pub fn place_at(&self, region: &mut Region, pos: [i32; 3]) {
        let adjusted = self.updated(&mut |p| region.get(p), self.default, pos, true);
        region.set(pos, adjusted, 2);
        if let Some(topper) = self.topper(region, pos) {
            region.set(offset(pos, [0, 1, 0]), topper, 2);
            let bottom = self.updated(&mut |p| region.get(p), adjusted, pos, true);
            region.set(pos, bottom, 2);
        }
    }
}
