//! Vanilla's path search as the AI asks for it (`Valimc.AI.Paths`): the
//! request a mob's navigation makes (`PathNavigation.createPath`'s region and
//! limits, the mob's size, footing, step, fall limit, path type malus, door
//! and fence abilities) and the search itself, run synchronously in process
//! over the level's blocks (`crate::path::find`). The search keeps the
//! random it returns (a small flier's start draws on it), as the oracles'
//! synchronous search does.

use super::fmath::{emax, f};
use super::turn::Turn;
use crate::mobs::level::Difficulty;
use crate::path::{self, types, Mob, PathNode, Request};
use crate::physics::border::Border;

/// A path being followed (`%{nodes, types, index, target, reached}`).
#[derive(Clone, Debug, PartialEq)]
pub struct NavPath {
    pub nodes: Vec<[i32; 3]>,
    /// Their path types (ordinals).
    pub types: Vec<u8>,
    /// The next node.
    pub index: usize,
    /// The block it was made for.
    pub target: [i32; 3],
    /// `Path.canReach`.
    pub reached: bool,
}

impl NavPath {
    pub fn of(path: path::Path) -> NavPath {
        let (nodes, kinds) = path
            .nodes
            .iter()
            .map(|n: &PathNode| (n.pos, n.kind))
            .unzip();
        NavPath {
            nodes,
            types: kinds,
            index: 0,
            target: path.target,
            reached: path.reached,
        }
    }

    /// `isDone`.
    pub fn done(&self) -> bool {
        self.index >= self.nodes.len()
    }
}

/// `PathNavigation.canCutCorner` of a node's type.
pub fn cut_corner(kind: u8) -> bool {
    !matches!(
        kind,
        types::FIRE_IN_NEIGHBOR | types::DAMAGING_IN_NEIGHBOR | types::WALKABLE_DOOR
    )
}

/// `Paths.request/5`: the search `createPath(targets, offset, above,
/// reach)` makes for the mob.
pub fn request(t: &Turn, targets: Vec<[i32; 3]>, offset: i32, above: bool, reach: i32) -> Request {
    let nav = &t.mind.navigation;
    let follow = t.attribute("minecraft:follow_range");
    // `getMaxPathLength`: the follow range, at least the required length.
    let length = emax(f(follow), nav.required_length);
    let radius = (length + offset as f64) as i32;
    let [bx, by, bz] = t.block();
    let from = if above {
        [bx, by + 1, bz]
    } else {
        [bx, by, bz]
    };
    let level = &*t.level;
    let mut malus = [0.0f32; types::COUNT];
    for (m, v) in malus.iter_mut().zip(&t.facts.malus) {
        *m = *v as f32;
    }
    Request {
        evaluator: nav.evaluator,
        mob: Mob {
            position: t.pos(),
            width: t.width as f32,
            height: t.height as f32,
            on_ground: t.on_ground(),
            in_water: t.in_water(),
            step: f(t.attribute("minecraft:step_height")) as f32,
            max_fall: max_fall(t),
            fall_distance: t.mob.body.mob.motion.fall_distance,
            malus,
            can_pass_doors: nav.can_pass_doors,
            can_open_doors: nav.can_open_doors,
            can_float: nav.can_float,
            can_walk_over_fences: nav.can_walk_over_fences,
            random: t.random.seed,
        },
        targets,
        max_path_length: length as f32,
        reach,
        max_visited: (length * 16.0).floor() as i32,
        multiplier: 1.0,
        region: (
            [from[0] - radius, from[1] - radius, from[2] - radius],
            [from[0] + radius, from[1] + radius, from[2] + radius],
        ),
        min_y: level.min_y,
        height: level.max_y - level.min_y + 1,
        sea_level: level.sea_level,
        border: level.border.map(|[min_x, min_z, max_x, max_z]| Border {
            min_x,
            min_z,
            max_x,
            max_z,
        }),
    }
}

// `Mob.getMaxFallDistance`: three blocks, more for a chasing mob with
// health to spare.
fn max_fall(t: &Turn) -> i32 {
    if t.entity(t.mind.target.as_ref()).is_none() {
        return 3;
    }
    let health = t.mob.body.mob.living.health.value;
    let max = f(t.attribute("minecraft:max_health"));
    let sacrifice = f(health - f(max * f(0.33))) as i64;
    let id = match t.level.difficulty {
        Difficulty::Peaceful => 0,
        Difficulty::Easy => 1,
        Difficulty::Normal => 2,
        Difficulty::Hard => 3,
    };
    let sacrifice = (sacrifice - (3 - id) * 4).max(0);
    (sacrifice as f64 + 3.0).floor() as i32
}

/// The search of `request` over the level's blocks: the path (none found)
/// and the mob's random after it.
pub fn find(t: &Turn, request: &Request) -> (Option<NavPath>, u64) {
    let found = path::find(t.level.blocks, t.level.physics, t.paths, request);
    (found.path.map(NavPath::of), found.random)
}

/// `bottom_center` of a node.
pub fn bottom_center(n: [i32; 3]) -> [f64; 3] {
    [n[0] as f64 + 0.5, n[1] as f64, n[2] as f64 + 0.5]
}
