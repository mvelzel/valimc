//! The block fact table (VMC-077d), installed once per VM by
//! `Valimc.Registry.BlockFacts.install!`: the storage flags, the light facts
//! and the per-state facts worldgen's block table reads all come from it.

use crate::{atoms, done};
use rustler::{Atom, Binary, NifMap, NifResult, Term};
use std::sync::OnceLock;
use valimc_core::light::LightFacts;
use valimc_core::physics::facts::{
    self as physics, Boundary, Climb, Fluid, Hazard, Inside, InsideKind, InsideShape, Motion,
    PlayerFacts,
};
use valimc_core::physics::player::pose::Dimensions;
use valimc_core::physics::table::Entry;
use valimc_core::physics::Aabb;
use valimc_core::physics::VoxelShape;
use valimc_core::{BlockFlags, StateFacts};

pub(crate) static FLAGS: OnceLock<BlockFlags> = OnceLock::new();
pub(crate) static LIGHT: OnceLock<LightFacts> = OnceLock::new();
pub(crate) static STATES: OnceLock<StateFacts> = OnceLock::new();
pub(crate) static PHYSICS: OnceLock<physics::Facts> = OnceLock::new();

mod kinds {
    rustler::atoms! { fixed, offset, scaffolding, powder_snow, shulker_box, moving_piston }
}

/// A shape: `{axes, sizes, bits}` (bits LSB first, cell `(x * ny + y) * nz + z`).
pub(crate) type ShapeT<'a> = (Vec<Vec<f64>>, Vec<usize>, Binary<'a>);

/// What the physics kernel reads (VMC-077l): the collision shape column with
/// its palette (`{kind, shape, full_block, max_offset}`), the shapes contexts
/// pick, scaffolding `{state, distance, bottom}`, and the motion, fluid and
/// boundary columns with their palettes.
/// A motion palette entry: `{{friction, speed_factor, jump_factor,
/// bounciness}, {suppresses_bounce, support_holds_y, speed_override}}`.
type MotionT = ((f64, f64, f64, f64), (bool, bool, bool));

#[derive(NifMap)]
struct Physics<'a> {
    shape_states: Binary<'a>,
    shapes: Vec<(Atom, ShapeT<'a>, bool, f64)>,
    scaffolding_stable: ShapeT<'a>,
    scaffolding_bottom: ShapeT<'a>,
    scaffolding_below_height: f64,
    powder_snow_falling: ShapeT<'a>,
    scaffolding: Vec<(u16, u8, bool)>,
    motion_states: Binary<'a>,
    motion: Vec<MotionT>,
    fluid_states: Binary<'a>,
    fluids: Vec<(u8, u8, f64, bool, bool)>,
    boundary_states: Binary<'a>,
    boundaries: Vec<(bool, bool, u8)>,
    climb_states: Binary<'a>,
    climbs: Vec<ClimbT>,
    inside_states: Binary<'a>,
    insides: Vec<InsideT<'a>>,
    hazard_states: Binary<'a>,
    hazards: Vec<(u8, f64)>,
    poses: Vec<(f64, f64, f64)>,
}

/// A climb palette entry: `{climbable, glide_through, scaffolding,
/// ladder_facing, trapdoor_facing, trapdoor_open}` (facings -1 for none).
type ClimbT = (bool, bool, bool, i8, i8, bool);

/// An inside palette entry: `{kind, shape}` with kind 0 none, 1 fire, 2 soul
/// fire, 3 powder snow, 4 cobweb, 5 berry bush, and shape `:full`,
/// `:context` or block-local boxes.
type InsideT<'a> = (u8, Term<'a>);

mod shapes {
    rustler::atoms! { full, context }
}

fn inside(entry: &InsideT) -> Option<Inside> {
    let (kind, shape) = entry;
    let kind = match kind {
        0 => InsideKind::None,
        1 => InsideKind::Fire,
        2 => InsideKind::SoulFire,
        3 => InsideKind::PowderSnow,
        4 => InsideKind::Cobweb,
        5 => InsideKind::BerryBush,
        _ => return None,
    };
    let shape = if let Ok(atom) = shape.decode::<Atom>() {
        if atom == shapes::full() {
            InsideShape::Full
        } else if atom == shapes::context() {
            InsideShape::Context
        } else {
            return None;
        }
    } else {
        let boxes: Vec<(f64, f64, f64, f64, f64, f64)> = shape.decode().ok()?;
        InsideShape::Boxes(
            boxes
                .into_iter()
                .map(|b| Aabb::new([b.0, b.1, b.2], [b.3, b.4, b.5]))
                .collect(),
        )
    };
    Some(Inside { kind, shape })
}

fn player_facts(p: &Physics, count: usize) -> Option<PlayerFacts> {
    let fits = |states: &[u8], palette: usize| {
        states.len() == count && states.iter().all(|&s| (s as usize) < palette)
    };
    let facts = PlayerFacts {
        climb_states: p.climb_states.as_slice().to_vec(),
        climbs: p
            .climbs
            .iter()
            .map(
                |&(
                    climbable,
                    glide_through,
                    scaffolding,
                    ladder_facing,
                    trapdoor_facing,
                    trapdoor_open,
                )| Climb {
                    climbable,
                    glide_through,
                    scaffolding,
                    ladder_facing,
                    trapdoor_facing,
                    trapdoor_open,
                },
            )
            .collect(),
        inside_states: p.inside_states.as_slice().to_vec(),
        insides: p.insides.iter().map(inside).collect::<Option<_>>()?,
        hazard_states: p.hazard_states.as_slice().to_vec(),
        hazards: p
            .hazards
            .iter()
            .map(|&(kind, value)| match kind {
                0 => Some(None),
                1 => Some(Some(Hazard::Magma)),
                2 => Some(Some(Hazard::Campfire(value))),
                3 => Some(Some(Hazard::Cactus)),
                4 => Some(Some(Hazard::Berry(value as i32))),
                _ => None,
            })
            .collect::<Option<_>>()?,
        poses: p
            .poses
            .iter()
            .map(|&(width, height, eye)| Dimensions { width, height, eye })
            .collect(),
    };
    (fits(&facts.climb_states, facts.climbs.len())
        && fits(&facts.inside_states, facts.insides.len())
        && fits(&facts.hazard_states, facts.hazards.len()))
    .then_some(facts)
}

pub(crate) fn shape(s: &ShapeT) -> Option<VoxelShape> {
    let (axes, sizes, bits) = s;
    if axes.len() != 3 || sizes.len() != 3 {
        return None;
    }
    let cells = sizes[0] * sizes[1] * sizes[2];
    if cells == 0 {
        return Some(VoxelShape::empty());
    }
    let bytes = bits.as_slice();
    let filled: Vec<bool> = (0..cells)
        .map(|i| bytes.get(i / 8).is_some_and(|b| b >> (i % 8) & 1 == 1))
        .collect();
    VoxelShape::new(
        [axes[0].clone(), axes[1].clone(), axes[2].clone()],
        [sizes[0], sizes[1], sizes[2]],
        &filled,
    )
}

fn physics_facts(p: &Physics, flags: Vec<u64>, count: usize) -> Option<physics::Facts> {
    let shape_states: Vec<u16> = p
        .shape_states
        .as_slice()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|b| u16::from_be_bytes(*b))
        .collect();
    let mut shapes = Vec::new();
    let mut entries = Vec::new();
    for (kind, geometry, full_block, max_offset) in &p.shapes {
        let entry = if *kind == kinds::fixed() || *kind == kinds::offset() {
            let mut s = shape(geometry)?;
            s.full_block = *full_block;
            shapes.push(s);
            if *kind == kinds::fixed() {
                Entry::Fixed(shapes.len() - 1)
            } else {
                Entry::Offset(shapes.len() - 1, *max_offset)
            }
        } else if *kind == kinds::scaffolding() {
            Entry::Scaffolding
        } else if *kind == kinds::powder_snow() {
            Entry::PowderSnow
        } else if *kind == kinds::shulker_box() {
            Entry::ShulkerBox
        } else if *kind == kinds::moving_piston() {
            Entry::MovingPiston
        } else {
            return None;
        };
        entries.push(entry);
    }
    let mut scaffolding = vec![(0u8, false); count];
    for &(state, distance, bottom) in &p.scaffolding {
        *scaffolding.get_mut(state as usize)? = (distance, bottom);
    }
    let table = physics::shape_table(
        shapes,
        entries,
        shape_states,
        scaffolding,
        shape(&p.scaffolding_stable)?,
        shape(&p.scaffolding_bottom)?,
        p.scaffolding_below_height,
        shape(&p.powder_snow_falling)?,
    )?;
    let motion = p
        .motion
        .iter()
        .map(
            |&((friction, speed, jump, bounce), (suppress, holds, over))| Motion {
                friction: friction as f32,
                speed_factor: speed as f32,
                jump_factor: jump as f32,
                bounciness: bounce as f32,
                suppresses_bounce: suppress,
                support_holds_y: holds,
                speed_override: over,
            },
        )
        .collect();
    let fluids = p
        .fluids
        .iter()
        .map(|&(kind, amount, height, source, falling)| Fluid {
            kind,
            amount,
            height: height as f32,
            source,
            falling,
        })
        .collect();
    let boundaries = p
        .boundaries
        .iter()
        .map(|&(blocks_flow, ice, context)| Boundary {
            blocks_flow,
            ice,
            context,
        })
        .collect();
    let player = player_facts(p, count)?;
    let mut facts = physics::Facts::new(
        table,
        flags,
        p.motion_states.as_slice().to_vec(),
        motion,
        p.fluid_states.as_slice().to_vec(),
        fluids,
        p.boundary_states.as_slice().to_vec(),
        boundaries,
    )?;
    facts.player = player;
    Some(facts)
}

/// The table's columns: `flags` and `signal` are eight big-endian bytes per
/// state, `fluid_remains` two, the others one byte per state; the light faces and sky carry their class counts
/// and pair tables.
#[derive(NifMap)]
struct Columns<'a> {
    flags: Binary<'a>,
    heightmaps: Binary<'a>,
    fluid: Binary<'a>,
    fluid_level: Binary<'a>,
    fluid_remains: Binary<'a>,
    signal: Binary<'a>,
    light: Binary<'a>,
    light_faces: Vec<Binary<'a>>,
    light_classes: Vec<usize>,
    light_occludes: Vec<Binary<'a>>,
    sky: Binary<'a>,
    sky_classes: usize,
    sky_pairs: Binary<'a>,
    physics: Physics<'a>,
}

/// Install the facts; a second install of the same table is a no-op.
#[rustler::nif]
fn block_facts_init(columns: Columns) -> NifResult<Atom> {
    done(install(&columns))
}

fn install(columns: &Columns) -> Result<(), Atom> {
    if let Some(installed) = STATES.get() {
        return if installed.state_count() == columns.heightmaps.len() {
            Ok(())
        } else {
            Err(atoms::flags_mismatch())
        };
    }
    let faces = &columns.light_faces;
    let (classes, occludes) = (&columns.light_classes, &columns.light_occludes);
    if !columns.flags.len().is_multiple_of(8)
        || !columns.signal.len().is_multiple_of(8)
        || faces.len() != 6
        || classes.len() != 6
        || occludes.len() != 6
    {
        return Err(atoms::invalid_state());
    }
    let words = |column: &Binary| {
        column
            .as_slice()
            .as_chunks::<8>()
            .0
            .iter()
            .map(|&word| u64::from_be_bytes(word))
            .collect::<Vec<u64>>()
    };
    let flags = words(&columns.flags);
    let count = flags.len();
    let physics =
        physics_facts(&columns.physics, flags.clone(), count).ok_or(atoms::invalid_state())?;
    let states = StateFacts::new(
        flags,
        columns.heightmaps.as_slice().to_vec(),
        columns.fluid.as_slice().to_vec(),
        columns.fluid_level.as_slice().to_vec(),
        columns
            .fluid_remains
            .as_slice()
            .as_chunks::<2>()
            .0
            .iter()
            .map(|&pair| u16::from_be_bytes(pair))
            .collect(),
        words(&columns.signal),
    )
    .ok_or(atoms::invalid_state())?;
    let light = LightFacts::new(
        columns.light.as_slice().to_vec(),
        std::array::from_fn(|d| faces[d].as_slice().to_vec()),
        std::array::from_fn(|d| classes[d]),
        std::array::from_fn(|d| occludes[d].as_slice().to_vec()),
        columns.sky.as_slice().to_vec(),
        columns.sky_classes,
        columns.sky_pairs.as_slice().to_vec(),
    )
    .ok_or(atoms::invalid_state())?;
    if light.state_count() != states.state_count() {
        return Err(atoms::invalid_state());
    }
    FLAGS.get_or_init(|| states.storage_flags());
    LIGHT.get_or_init(|| light);
    STATES.get_or_init(|| states);
    PHYSICS.get_or_init(|| physics);
    Ok(())
}
