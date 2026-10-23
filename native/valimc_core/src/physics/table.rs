//! Collision shapes per block state from the block fact table (VMC-077d's
//! `shape` column), and the contexts that pick a dynamic one (vanilla's
//! `getCollisionShape` overrides the table names).

use super::shape::VoxelShape;

/// What a state's collision shape is.
#[derive(Clone, Debug)]
pub enum Entry {
    /// A fixed block-local shape (an index into the palette).
    Fixed(usize),
    /// A fixed shape moved by the position's horizontal offset (bamboo,
    /// pointed dripstone): the shape and the largest offset.
    Offset(usize, f64),
    Scaffolding,
    PowderSnow,
    /// A shulker box: without its block entity's openness, a full block.
    ShulkerBox,
    /// A moving piston: without its block entity, empty.
    MovingPiston,
}

/// The installed shapes.
#[derive(Debug)]
pub struct ShapeTable {
    pub shapes: Vec<VoxelShape>,
    pub entries: Vec<Entry>,
    /// Per state: its entry.
    pub states: Vec<u16>,
    /// Per state, flags the scan needs: bit 0 large collision shape, bit 1
    /// moving piston.
    pub special: Vec<u8>,
    /// Scaffolding `(distance, bottom)` per state (other states unused).
    pub scaffolding: Vec<(u8, bool)>,
    pub scaffolding_stable: VoxelShape,
    pub scaffolding_bottom: VoxelShape,
    pub scaffolding_below_height: f64,
    pub powder_snow_falling: VoxelShape,
    pub empty: VoxelShape,
    pub block: VoxelShape,
    /// Piston heads (VMC-048b) at `sticky * 12 + short * 6 + facing`.
    pub piston_heads: Vec<u16>,
    /// Piston bases: state => its extended state, sticky or not, facing.
    pub piston_bases: std::collections::HashMap<u16, (u16, bool, u8)>,
    /// Per state: 0 no lava, 1 lava, 2 a lava source block (VMC-043d).
    pub lava: Vec<u8>,
    /// `LiquidBlock.STABLE_SHAPE`: the half block a lava walker stands on.
    pub lava_stable: VoxelShape,
}

pub const LARGE: u8 = 1;
pub const MOVING_PISTON: u8 = 2;

/// What vanilla's `CollisionContext` knows about the entity a scan is for.
#[derive(Clone, Copy, Debug, Default)]
pub struct Context {
    /// An entity context (`CollisionContext.of(entity)`) rather than empty.
    pub entity: bool,
    pub bottom: f64,
    pub descending: bool,
    pub placement: bool,
    /// The entity reference is present (scaffolding and powder snow read it).
    pub entity_present: bool,
    pub fall_distance: f64,
    pub falling_block: bool,
    pub powder_snow_walkable: bool,
    /// It stands on lava (`canStandOnFluid`: a strider, VMC-043d).
    pub lava_walker: bool,
    /// The direction a piston moves the entity in (`PistonMovingBlockEntity.NOCLIP`):
    /// moving blocks headed that way do not collide with it.
    pub noclip: Option<u8>,
}

impl Context {
    /// `isAbove`: the entity's bottom lies above the shape's top at `y`; an
    /// empty context answers `fallback`.
    pub fn above(&self, shape_top: f64, y: i32, fallback: bool) -> bool {
        if !self.entity {
            return fallback;
        }
        self.bottom > y as f64 + shape_top - 9.999999747378752e-6
    }
}

/// A block-local shape and the horizontal offset it is placed with.
pub struct Picked<'a> {
    pub shape: &'a VoxelShape,
    pub offset: [f64; 3],
}

impl ShapeTable {
    /// 0 no lava, 1 lava, 2 a lava source block.
    pub fn lava(&self, state: u16) -> u8 {
        self.lava.get(state as usize).copied().unwrap_or(0)
    }

    pub fn special(&self, state: u16) -> u8 {
        self.special.get(state as usize).copied().unwrap_or(0)
    }

    /// The collision shape of `state` at `pos` for `ctx`.
    pub fn shape(&self, state: u16, pos: [i32; 3], ctx: &Context) -> Picked<'_> {
        let fixed = |shape| Picked {
            shape,
            offset: [0.0; 3],
        };
        let entry = self
            .states
            .get(state as usize)
            .and_then(|&e| self.entries.get(e as usize));
        match entry {
            None => fixed(&self.empty),
            Some(Entry::Fixed(i)) => fixed(&self.shapes[*i]),
            Some(Entry::Offset(i, limit)) => Picked {
                shape: &self.shapes[*i],
                offset: horizontal_offset(pos, *limit),
            },
            Some(Entry::ShulkerBox) => fixed(&self.block),
            Some(Entry::MovingPiston) => fixed(&self.empty),
            Some(Entry::PowderSnow) => fixed(self.powder_snow(pos[1], ctx)),
            Some(Entry::Scaffolding) => fixed(self.scaffolding(state, pos[1], ctx)),
        }
    }

    /// The piston head facing `facing` (normal, not sticky) for a moving
    /// source, short or not.
    pub fn piston_head(&self, sticky: bool, short: bool, facing: u8) -> Option<u16> {
        self.piston_heads
            .get(usize::from(sticky) * 12 + usize::from(short) * 6 + facing as usize)
            .copied()
    }

    /// `PistonMovingBlockEntity.getCollisionShape` of `moving` at `pos`
    /// (VMC-048b), for an entity a piston moves toward `ctx.noclip` (or
    /// none): the retracting base's extended shape joined with the head or
    /// carried block lagging its cell by the progress, as `Shapes.or` joins
    /// them.
    pub fn moving_shape(
        &self,
        moving: &crate::piston::Moving,
        pos: [i32; 3],
        ctx: &Context,
    ) -> VoxelShape {
        use super::join::{join_or, Grid};
        let empty = Context::default();
        let head = match self.piston_bases.get(&moving.moved) {
            Some(&(extended, _, _)) if !moving.extending && moving.source => {
                self.shape(extended, pos, &empty).shape
            }
            _ => &self.empty,
        };
        if moving.progress < 1.0 && ctx.noclip == Some(moving.movement() as u8) {
            return head.clone();
        }
        let state = if moving.source {
            let short = moving.extending != (1.0 - moving.progress < 0.25);
            self.piston_head(false, short, moving.direction)
        } else {
            Some(moving.moved)
        };
        let carried = match state {
            Some(state) => {
                let picked = self.shape(state, pos, &empty);
                let ext = moving.extended_progress(moving.progress);
                let step = crate::rules::STEP[moving.direction as usize];
                let d: [f64; 3] = std::array::from_fn(|a| (step[a] as f32 * ext) as f64);
                // `getCollisionShape` places an offset shape first, `move` then.
                if picked.offset == [0.0; 3] {
                    Grid::of(picked.shape, Some(d))
                } else {
                    let placed = Grid::of(picked.shape, Some(picked.offset)).shape();
                    Grid::of(&placed, Some(d))
                }
            }
            None => Grid::empty(),
        };
        join_or(&Grid::of(head, None), &carried).optimize().shape()
    }

    fn powder_snow(&self, y: i32, ctx: &Context) -> &VoxelShape {
        if ctx.placement || !ctx.entity_present {
            &self.empty
        } else if ctx.fall_distance > 2.5 {
            &self.powder_snow_falling
        } else if ctx.falling_block
            || (ctx.powder_snow_walkable && !ctx.descending && ctx.above(1.0, y, false))
        {
            &self.block
        } else {
            &self.empty
        }
    }

    fn scaffolding(&self, state: u16, y: i32, ctx: &Context) -> &VoxelShape {
        let (distance, bottom) = self
            .scaffolding
            .get(state as usize)
            .copied()
            .unwrap_or((0, false));
        if ctx.placement {
            &self.empty
        } else if ctx.above(1.0, y, true) && !ctx.descending {
            &self.scaffolding_stable
        } else if distance != 0 && bottom && ctx.above(self.scaffolding_below_height, y, true) {
            &self.scaffolding_bottom
        } else {
            &self.empty
        }
    }
}

/// Vanilla's `BlockState.getOffset` for blocks with a horizontal offset: a
/// position hash picks each component in sixteenths, clamped to `limit`.
pub fn horizontal_offset(pos: [i32; 3], limit: f64) -> [f64; 3] {
    let (x, z) = (pos[0], pos[2]);
    let mut seed = (x.wrapping_mul(3_129_871) as i64) ^ (z as i64).wrapping_mul(116_129_781);
    seed = seed
        .wrapping_mul(seed)
        .wrapping_mul(42_317_861)
        .wrapping_add(seed.wrapping_mul(11));
    let seed = seed >> 16;
    let component = |n: i64| {
        let fraction = (n as f32) / 15.0f32;
        ((fraction as f64 - 0.5) * 0.5).clamp(-limit, limit)
    };
    [component(seed & 15), 0.0, component(seed >> 8 & 15)]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offsets_follow_the_position_hash() {
        // `Mth.getSeed(0, 0, 0)` is 0: both components are the lowest fraction.
        assert_eq!(horizontal_offset([0, 64, 0], 0.25), [-0.25, 0.0, -0.25]);
        let o = horizontal_offset([12, 70, -5], 0.125);
        assert!(o[0].abs() <= 0.125 && o[2].abs() <= 0.125 && o[1] == 0.0);
    }
}
