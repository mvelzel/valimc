//! The per-state facts the kernel reads, from the block fact table (VMC-077d)
//! as `Valimc.Registry.BlockFacts.install!` hands them over: collision shapes,
//! movement materials, contained fluids and flow boundaries, beside the flag
//! bits the table already installs.

use super::shape::VoxelShape;
use super::table::{Entry, ShapeTable, LARGE, MOVING_PISTON};

/// `large_collision` (flag bit 50): the shape reaches outside its block.
pub const LARGE_COLLISION: u64 = 1 << 50;
/// The sturdy faces (flag bits 5..10, `Direction` order).
pub const STURDY_SHIFT: u32 = 5;

/// How a block moves what stands on or in it (vanilla's per-block floats).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Motion {
    pub friction: f32,
    pub speed_factor: f32,
    pub jump_factor: f32,
    pub bounciness: f32,
    pub suppresses_bounce: bool,
    /// `getOnPosLegacy` keeps the support's own Y (fences, walls).
    pub support_holds_y: bool,
    /// The block overrides the speed factor below the feet (soul sand).
    pub speed_override: bool,
}

/// The fluid a state holds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Fluid {
    /// 0 empty, 1 water, 2 lava.
    pub kind: u8,
    pub amount: u8,
    pub height: f32,
    pub source: bool,
    pub falling: bool,
}

pub const EMPTY: u8 = 0;
pub const WATER: u8 = 1;
pub const LAVA: u8 = 2;

/// What a state does to flowing fluid next to it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Boundary {
    pub blocks_flow: bool,
    pub ice: bool,
    /// 0 none, 1 piston, 2 shulker box: its sturdy faces need its block
    /// entity (absent: the table's faces).
    pub context: u8,
}

/// What a state offers a climber (`isClimbable`, trapdoors over ladders).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Climb {
    pub climbable: bool,
    pub glide_through: bool,
    pub scaffolding: bool,
    /// The ladder's facing (`Direction` index), -1 for none.
    pub ladder_facing: i8,
    pub trapdoor_facing: i8,
    pub trapdoor_open: bool,
}

/// What standing inside a state does to an entity.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum InsideKind {
    #[default]
    None,
    Fire,
    SoulFire,
    PowderSnow,
    Cobweb,
    BerryBush,
}

/// The shape an entity must be inside for the state's effect
/// (`getEntityInsideCollisionShape`): the whole block, the collision shape
/// for the entity's context, or fixed block-local boxes.
#[derive(Clone, Debug, Default, PartialEq)]
pub enum InsideShape {
    #[default]
    Full,
    Context,
    Boxes(Vec<super::aabb::Aabb>),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Inside {
    pub kind: InsideKind,
    pub shape: InsideShape,
}

/// The immediate harm a state does to a player touching it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Hazard {
    Magma,
    /// A lit campfire's damage (0 unlit).
    Campfire(f64),
    Cactus,
    /// A sweet berry bush's age.
    Berry(i32),
}

/// The player's facts beside the collision ones: climbing, inside
/// behaviour, hazards and the pose catalog.
#[derive(Clone, Debug, Default)]
pub struct PlayerFacts {
    pub climb_states: Vec<u8>,
    pub climbs: Vec<Climb>,
    pub inside_states: Vec<u8>,
    pub insides: Vec<Inside>,
    pub hazard_states: Vec<u8>,
    pub hazards: Vec<Option<Hazard>>,
    pub poses: Vec<super::player::pose::Dimensions>,
}

impl PlayerFacts {
    pub fn climb(&self, state: u16) -> Climb {
        self.climb_states
            .get(state as usize)
            .and_then(|&i| self.climbs.get(i as usize))
            .copied()
            .unwrap_or_default()
    }

    pub fn inside(&self, state: u16) -> &Inside {
        static NONE: Inside = Inside {
            kind: InsideKind::None,
            shape: InsideShape::Full,
        };
        self.inside_states
            .get(state as usize)
            .and_then(|&i| self.insides.get(i as usize))
            .unwrap_or(&NONE)
    }

    pub fn hazard(&self, state: u16) -> Option<Hazard> {
        self.hazard_states
            .get(state as usize)
            .and_then(|&i| self.hazards.get(i as usize))
            .copied()
            .flatten()
    }
}

/// Everything the kernel reads per state.
#[derive(Debug)]
pub struct Facts {
    pub shapes: ShapeTable,
    pub flags: Vec<u64>,
    pub motion_states: Vec<u8>,
    pub motion: Vec<Motion>,
    pub fluid_states: Vec<u8>,
    pub fluids: Vec<Fluid>,
    pub boundary_states: Vec<u8>,
    pub boundaries: Vec<Boundary>,
    pub player: PlayerFacts,
    /// The resistance an explosion's ray meets per state (NaN: none, air
    /// without fluid), VMC-050a.
    pub explosion: Vec<f32>,
}

const NO_MOTION: Motion = Motion {
    friction: 0.6,
    speed_factor: 1.0,
    jump_factor: 1.0,
    bounciness: 0.0,
    suppresses_bounce: false,
    support_holds_y: false,
    speed_override: false,
};

const NO_FLUID: Fluid = Fluid {
    kind: EMPTY,
    amount: 0,
    height: 0.0,
    source: false,
    falling: false,
};

const NO_BOUNDARY: Boundary = Boundary {
    blocks_flow: false,
    ice: false,
    context: 0,
};

impl Facts {
    /// Assemble the facts; `None` when the columns disagree in length or name
    /// entries that do not exist.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        mut shapes: ShapeTable,
        flags: Vec<u64>,
        motion_states: Vec<u8>,
        motion: Vec<Motion>,
        fluid_states: Vec<u8>,
        fluids: Vec<Fluid>,
        boundary_states: Vec<u8>,
        boundaries: Vec<Boundary>,
    ) -> Option<Facts> {
        let n = flags.len();
        let fits = |states: &[u8], palette: usize| {
            states.len() == n && states.iter().all(|&s| (s as usize) < palette)
        };
        if shapes.states.len() != n
            || shapes
                .states
                .iter()
                .any(|&e| e as usize >= shapes.entries.len())
            || !fits(&motion_states, motion.len())
            || !fits(&fluid_states, fluids.len())
            || !fits(&boundary_states, boundaries.len())
        {
            return None;
        }
        shapes.special = (0..n)
            .map(|s| {
                let large = if flags[s] & LARGE_COLLISION != 0 {
                    LARGE
                } else {
                    0
                };
                let piston = match shapes.entries[shapes.states[s] as usize] {
                    Entry::MovingPiston => MOVING_PISTON,
                    _ => 0,
                };
                large | piston
            })
            .collect();
        Some(Facts {
            shapes,
            flags,
            motion_states,
            motion,
            fluid_states,
            fluids,
            boundary_states,
            boundaries,
            player: PlayerFacts::default(),
            explosion: Vec::new(),
        })
    }

    pub fn motion(&self, state: u16) -> &Motion {
        self.motion_states
            .get(state as usize)
            .and_then(|&i| self.motion.get(i as usize))
            .unwrap_or(&NO_MOTION)
    }

    pub fn fluid(&self, state: u16) -> &Fluid {
        self.fluid_states
            .get(state as usize)
            .and_then(|&i| self.fluids.get(i as usize))
            .unwrap_or(&NO_FLUID)
    }

    pub fn boundary(&self, state: u16) -> &Boundary {
        self.boundary_states
            .get(state as usize)
            .and_then(|&i| self.boundaries.get(i as usize))
            .unwrap_or(&NO_BOUNDARY)
    }

    /// The resistance an explosion's ray meets in `state`, or `None` (air
    /// without fluid). A table without the column reads every state as none.
    pub fn explosion_resistance(&self, state: u16) -> Option<f32> {
        self.explosion
            .get(state as usize)
            .copied()
            .filter(|r| !r.is_nan())
    }

    pub fn flags(&self, state: u16) -> u64 {
        self.flags.get(state as usize).copied().unwrap_or(0)
    }

    /// Whether face `direction` (`Direction` order) is sturdy (FULL).
    pub fn sturdy(&self, state: u16, direction: usize) -> bool {
        self.flags(state) >> (STURDY_SHIFT + direction as u32) & 1 == 1
    }

    pub fn shape_count(&self) -> usize {
        self.shapes.shapes.len()
    }
}

/// A shape table from its parts, the dynamic entries' shapes included.
#[allow(clippy::too_many_arguments)]
pub fn shape_table(
    shapes: Vec<VoxelShape>,
    entries: Vec<Entry>,
    states: Vec<u16>,
    scaffolding: Vec<(u8, bool)>,
    scaffolding_stable: VoxelShape,
    scaffolding_bottom: VoxelShape,
    scaffolding_below_height: f64,
    powder_snow_falling: VoxelShape,
) -> Option<ShapeTable> {
    if entries.iter().any(|e| match e {
        Entry::Fixed(i) | Entry::Offset(i, _) => *i >= shapes.len(),
        _ => false,
    }) {
        return None;
    }
    Some(ShapeTable {
        shapes,
        entries,
        states,
        special: Vec::new(),
        scaffolding,
        scaffolding_stable,
        scaffolding_bottom,
        scaffolding_below_height,
        powder_snow_falling,
        empty: VoxelShape::empty(),
        block: VoxelShape::block(),
        piston_heads: Vec::new(),
        piston_bases: std::collections::HashMap::new(),
    })
}
