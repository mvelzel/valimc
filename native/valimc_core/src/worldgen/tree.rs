//! Vanilla's tree feature (VMC-025b): trunk, foliage and root placers, feature
//! sizes, tree decorators, leaf distances and the shape updates at the tree's
//! edge, from the decompiled `TreeFeature` and its placers. Positions collect
//! in Java-ordered hash sets (`javahash`), since decorators and the leaf
//! distance walk follow their iteration order.

use std::sync::Arc;

use super::blocks::{
    BlockSet, BlockTable, Heightmap, FLUID_FLOWING_WATER, FLUID_WATER, SOLID_RENDER, STURDY,
};
use super::feature::Decoration;
use super::javahash::JavaHashSet;
use super::json::Json;
use super::predicate::offset;
use super::providers::IntProvider;
use super::random::Random;
use super::region::Region;
use super::state_provider::StateProvider;

/// Directions in vanilla's order, and the horizontal plane's (north, east,
/// south, west).
pub const DOWN: usize = 0;
pub const UP: usize = 1;
pub const NORTH: usize = 2;
pub const SOUTH: usize = 3;
pub const WEST: usize = 4;
pub const EAST: usize = 5;
pub const STEP: [[i32; 3]; 6] = [
    [0, -1, 0],
    [0, 1, 0],
    [0, 0, -1],
    [0, 0, 1],
    [-1, 0, 0],
    [1, 0, 0],
];
pub const HORIZONTAL: [usize; 4] = [NORTH, EAST, SOUTH, WEST];
pub const NAMES: [&str; 6] = ["down", "up", "north", "south", "west", "east"];

pub fn opposite(d: usize) -> usize {
    d ^ 1
}

pub fn clockwise(d: usize) -> usize {
    match d {
        NORTH => EAST,
        EAST => SOUTH,
        SOUTH => WEST,
        WEST => NORTH,
        other => other,
    }
}

fn axis_name(d: usize) -> &'static str {
    match d {
        DOWN | UP => "y",
        NORTH | SOUTH => "z",
        _ => "x",
    }
}

fn moved(pos: [i32; 3], d: usize, n: i32) -> [i32; 3] {
    [
        pos[0] + STEP[d][0] * n,
        pos[1] + STEP[d][1] * n,
        pos[2] + STEP[d][2] * n,
    ]
}

fn manhattan(a: [i32; 3], b: [i32; 3]) -> i32 {
    (a[0] - b[0]).abs() + (a[1] - b[1]).abs() + (a[2] - b[2]).abs()
}

/// `Mth.floor` of a float.
fn floor_f(v: f32) -> i32 {
    v.floor() as i32
}

#[derive(Debug)]
pub enum TrunkKind {
    Straight,
    Forking,
    Giant,
    MegaJungle,
    DarkOak,
    Fancy,
    Bending {
        min_height_for_leaves: i32,
        bend_length: IntProvider,
    },
    Cherry {
        branch_count: IntProvider,
        branch_horizontal_length: IntProvider,
        branch_start: (i32, i32),
        branch_end: IntProvider,
    },
    Poplar {
        above_branches: IntProvider,
        branch_amount: IntProvider,
    },
    UpwardsBranching {
        extra_branch_steps: IntProvider,
        branch_probability: f32,
        extra_branch_length: IntProvider,
        can_grow_through: BlockSet,
    },
}

#[derive(Debug)]
pub struct TrunkPlacer {
    base_height: i32,
    rand_a: i32,
    rand_b: i32,
    kind: TrunkKind,
}

#[derive(Debug)]
pub enum FoliageKind {
    Blob(i32),
    Fancy(i32),
    Bush(i32),
    Jungle(i32),
    Spruce(IntProvider),
    Pine(IntProvider),
    Acacia,
    DarkOak,
    MegaPine(IntProvider),
    RandomSpread {
        height: IntProvider,
        attempts: i32,
    },
    Cherry {
        height: IntProvider,
        wide_hole: f32,
        corner_hole: f32,
        hanging: f32,
        hanging_extension: f32,
    },
    Poplar {
        height: IntProvider,
        side_hole: f32,
    },
}

#[derive(Debug)]
pub struct FoliagePlacer {
    radius: IntProvider,
    offset: IntProvider,
    kind: FoliageKind,
}

#[derive(Debug)]
pub enum FeatureSize {
    Two {
        limit: i32,
        lower: i32,
        upper: i32,
        min_clipped: Option<i32>,
    },
    Three {
        limit: i32,
        upper_limit: i32,
        lower: i32,
        middle: i32,
        upper: i32,
        min_clipped: Option<i32>,
    },
}

#[derive(Debug)]
pub struct MangroveRoots {
    trunk_offset_y: IntProvider,
    provider: Arc<StateProvider>,
    above: Option<(Arc<StateProvider>, f32)>,
    can_grow_through: BlockSet,
    muddy_roots_in: BlockSet,
    muddy_provider: Arc<StateProvider>,
    max_width: i32,
    max_length: i32,
    skew: f32,
}

#[derive(Debug)]
pub enum Decorator {
    Beehive(f32),
    PlaceOnGround {
        tries: i32,
        radius: i32,
        height: i32,
        provider: Arc<StateProvider>,
    },
    AlterGround(Arc<StateProvider>),
    TrunkVine,
    LeaveVine(f32),
    Cocoa(f32),
    AttachedToLeaves {
        probability: f32,
        exclusion_xz: i32,
        exclusion_y: i32,
        provider: Arc<StateProvider>,
        required_empty: i32,
        directions: Vec<usize>,
    },
    AttachedToLogs {
        probability: f32,
        provider: Arc<StateProvider>,
        directions: Vec<usize>,
    },
    ShelfMushroom(f32),
    CreakingHeart(f32),
    PaleMoss {
        leaves: f32,
        trunk: f32,
        ground: f32,
    },
}

#[derive(Debug)]
pub struct Tree {
    trunk_provider: Arc<StateProvider>,
    trunk: TrunkPlacer,
    foliage_provider: Arc<StateProvider>,
    foliage: FoliagePlacer,
    roots: Option<MangroveRoots>,
    size: FeatureSize,
    decorators: Vec<Decorator>,
    ignore_vines: bool,
    below_trunk_provider: Arc<StateProvider>,
}

type Provider<'a> = &'a mut dyn FnMut(&Json) -> Result<Arc<StateProvider>, String>;

fn int(json: &Json, key: &str) -> Result<IntProvider, String> {
    IntProvider::parse(json.field(key)?)
}

fn float(json: &Json, key: &str) -> Result<f32, String> {
    Ok(json.field(key)?.as_f64()? as f32)
}

fn opt_int(json: &Json, key: &str, default: i32) -> Result<i32, String> {
    json.get(key).map_or(Ok(default), Json::as_i32)
}

fn parse_decorators(json: &Json, provider: Provider) -> Result<Vec<Decorator>, String> {
    let mut decorators = Vec::new();
    for d in json.as_array()? {
        decorators.push(match d.field("type")?.as_str()? {
            "minecraft:beehive" => Decorator::Beehive(float(d, "probability")?),
            "minecraft:place_on_ground" => Decorator::PlaceOnGround {
                tries: opt_int(d, "tries", 128)?,
                radius: opt_int(d, "radius", 2)?,
                height: opt_int(d, "height", 1)?,
                provider: provider(d.field("block_state_provider")?)?,
            },
            "minecraft:alter_ground" => Decorator::AlterGround(provider(d.field("provider")?)?),
            "minecraft:trunk_vine" => Decorator::TrunkVine,
            "minecraft:leave_vine" => Decorator::LeaveVine(float(d, "probability")?),
            "minecraft:cocoa" => Decorator::Cocoa(float(d, "probability")?),
            "minecraft:attached_to_leaves" => Decorator::AttachedToLeaves {
                probability: float(d, "probability")?,
                exclusion_xz: d.field("exclusion_radius_xz")?.as_i32()?,
                exclusion_y: d.field("exclusion_radius_y")?.as_i32()?,
                provider: provider(d.field("block_provider")?)?,
                required_empty: d.field("required_empty_blocks")?.as_i32()?,
                directions: d
                    .field("directions")?
                    .as_array()?
                    .iter()
                    .map(|x| super::predicate::direction(x.as_str()?).map(|d| d.0))
                    .collect::<Result<_, _>>()?,
            },
            "minecraft:shelf_mushroom" => Decorator::ShelfMushroom(float(d, "probability")?),
            "minecraft:creaking_heart" => Decorator::CreakingHeart(float(d, "probability")?),
            "minecraft:attached_to_logs" => Decorator::AttachedToLogs {
                probability: float(d, "probability")?,
                provider: provider(d.field("block_provider")?)?,
                directions: d
                    .field("directions")?
                    .as_array()?
                    .iter()
                    .map(|x| super::predicate::direction(x.as_str()?).map(|d| d.0))
                    .collect::<Result<_, _>>()?,
            },
            "minecraft:pale_moss" => Decorator::PaleMoss {
                leaves: float(d, "leaves_probability")?,
                trunk: float(d, "trunk_probability")?,
                ground: float(d, "ground_probability")?,
            },
            other => return Err(format!("unknown tree decorator {other}")),
        });
    }
    Ok(decorators)
}

impl Tree {
    pub fn parse(json: &Json, table: &BlockTable, provider: Provider) -> Result<Tree, String> {
        let t = json.field("trunk_placer")?;
        let trunk = TrunkPlacer {
            base_height: t.field("base_height")?.as_i32()?,
            rand_a: t.field("height_rand_a")?.as_i32()?,
            rand_b: t.field("height_rand_b")?.as_i32()?,
            kind: match t.field("type")?.as_str()? {
                "minecraft:straight_trunk_placer" => TrunkKind::Straight,
                "minecraft:forking_trunk_placer" => TrunkKind::Forking,
                "minecraft:giant_trunk_placer" => TrunkKind::Giant,
                "minecraft:mega_jungle_trunk_placer" => TrunkKind::MegaJungle,
                "minecraft:dark_oak_trunk_placer" => TrunkKind::DarkOak,
                "minecraft:fancy_trunk_placer" => TrunkKind::Fancy,
                "minecraft:bending_trunk_placer" => TrunkKind::Bending {
                    min_height_for_leaves: opt_int(t, "min_height_for_leaves", 1)?,
                    bend_length: int(t, "bend_length")?,
                },
                "minecraft:cherry_trunk_placer" => {
                    let start = t.field("branch_start_offset_from_top")?;
                    TrunkKind::Cherry {
                        branch_count: int(t, "branch_count")?,
                        branch_horizontal_length: int(t, "branch_horizontal_length")?,
                        branch_start: (
                            start.field("min_inclusive")?.as_i32()?,
                            start.field("max_inclusive")?.as_i32()?,
                        ),
                        branch_end: int(t, "branch_end_offset_from_top")?,
                    }
                }
                "minecraft:poplar_trunk_placer" => TrunkKind::Poplar {
                    above_branches: int(t, "trunk_height_above_branches")?,
                    branch_amount: int(t, "branch_amount")?,
                },
                "minecraft:upwards_branching_trunk_placer" => TrunkKind::UpwardsBranching {
                    extra_branch_steps: int(t, "extra_branch_steps")?,
                    branch_probability: float(t, "place_branch_per_log_probability")?,
                    extra_branch_length: int(t, "extra_branch_length")?,
                    can_grow_through: table.block_set(t.field("can_grow_through")?)?,
                },
                other => return Err(format!("unknown trunk placer {other}")),
            },
        };
        let f = json.field("foliage_placer")?;
        let height = |key: &str| f.field(key)?.as_i32();
        let foliage = FoliagePlacer {
            radius: int(f, "radius")?,
            offset: int(f, "offset")?,
            kind: match f.field("type")?.as_str()? {
                "minecraft:blob_foliage_placer" => FoliageKind::Blob(height("height")?),
                "minecraft:fancy_foliage_placer" => FoliageKind::Fancy(height("height")?),
                "minecraft:bush_foliage_placer" => FoliageKind::Bush(height("height")?),
                "minecraft:jungle_foliage_placer" => FoliageKind::Jungle(height("height")?),
                "minecraft:spruce_foliage_placer" => FoliageKind::Spruce(int(f, "trunk_height")?),
                "minecraft:pine_foliage_placer" => FoliageKind::Pine(int(f, "height")?),
                "minecraft:acacia_foliage_placer" => FoliageKind::Acacia,
                "minecraft:dark_oak_foliage_placer" => FoliageKind::DarkOak,
                "minecraft:mega_pine_foliage_placer" => {
                    FoliageKind::MegaPine(int(f, "crown_height")?)
                }
                "minecraft:random_spread_foliage_placer" => FoliageKind::RandomSpread {
                    height: int(f, "foliage_height")?,
                    attempts: f.field("leaf_placement_attempts")?.as_i32()?,
                },
                "minecraft:cherry_foliage_placer" => FoliageKind::Cherry {
                    height: int(f, "height")?,
                    wide_hole: float(f, "wide_bottom_layer_hole_chance")?,
                    corner_hole: float(f, "corner_hole_chance")?,
                    hanging: float(f, "hanging_leaves_chance")?,
                    hanging_extension: float(f, "hanging_leaves_extension_chance")?,
                },
                "minecraft:poplar_foliage_placer" => FoliageKind::Poplar {
                    height: int(f, "height")?,
                    side_hole: float(f, "side_hole_chance")?,
                },
                other => return Err(format!("unknown foliage placer {other}")),
            },
        };
        let s = json.field("minimum_size")?;
        let min_clipped = s.get("min_clipped_height").map(Json::as_i32).transpose()?;
        let size = match s.field("type")?.as_str()? {
            "minecraft:two_layers_feature_size" => FeatureSize::Two {
                limit: opt_int(s, "limit", 1)?,
                lower: opt_int(s, "lower_size", 0)?,
                upper: opt_int(s, "upper_size", 1)?,
                min_clipped,
            },
            "minecraft:three_layers_feature_size" => FeatureSize::Three {
                limit: opt_int(s, "limit", 1)?,
                upper_limit: opt_int(s, "upper_limit", 1)?,
                lower: opt_int(s, "lower_size", 0)?,
                middle: opt_int(s, "middle_size", 1)?,
                upper: opt_int(s, "upper_size", 1)?,
                min_clipped,
            },
            other => return Err(format!("unknown feature size {other}")),
        };
        let roots = match json.get("root_placer") {
            None => None,
            Some(r) => {
                if r.field("type")?.as_str()? != "minecraft:mangrove_root_placer" {
                    return Err("unknown root placer".into());
                }
                let m = r.field("mangrove_root_placement")?;
                Some(MangroveRoots {
                    trunk_offset_y: int(r, "trunk_offset_y")?,
                    provider: provider(r.field("root_provider")?)?,
                    above: match r.get("above_root_placement") {
                        Some(a) => Some((
                            provider(a.field("above_root_provider")?)?,
                            float(a, "above_root_placement_chance")?,
                        )),
                        None => None,
                    },
                    can_grow_through: table.block_set(m.field("can_grow_through")?)?,
                    muddy_roots_in: table.block_set(m.field("muddy_roots_in")?)?,
                    muddy_provider: provider(m.field("muddy_roots_provider")?)?,
                    max_width: m.field("max_root_width")?.as_i32()?,
                    max_length: m.field("max_root_length")?.as_i32()?,
                    skew: float(m, "random_skew_chance")?,
                })
            }
        };
        let decorators = parse_decorators(json.field("decorators")?, provider)?;
        Ok(Tree {
            trunk_provider: provider(json.field("trunk_provider")?)?,
            trunk,
            foliage_provider: provider(json.field("foliage_provider")?)?,
            foliage,
            roots,
            size,
            decorators,
            ignore_vines: json.get("ignore_vines").map_or(Ok(false), Json::as_bool)?,
            below_trunk_provider: provider(json.field("below_trunk_provider")?)?,
        })
    }
}

/// A foliage attachment: position, radius offset and whether it sits on a
/// 2 × 2 trunk.
#[derive(Clone, Copy, Debug)]
struct Attachment {
    pos: [i32; 3],
    radius_offset: i32,
    double_trunk: bool,
}

/// The tree being placed: its sets, in Java's order, and its writes.
struct Placing<'a, 'r> {
    d: &'a Decoration,
    region: &'a mut Region<'r>,
    random: &'a mut Random,
    /// The tree being placed; none for a fallen tree's logs.
    tree: Option<&'a Tree>,
    roots: JavaHashSet,
    trunks: JavaHashSet,
    foliage: JavaHashSet,
    decorations: JavaHashSet,
}

impl<'a> Placing<'a, '_> {
    fn tree(&self) -> &'a Tree {
        self.tree.expect("a tree")
    }

    fn table(&self) -> &BlockTable {
        self.d.table.as_ref()
    }

    fn get(&mut self, pos: [i32; 3]) -> u16 {
        self.region.get(pos)
    }

    fn is(&mut self, pos: [i32; 3], set: &BlockSet) -> bool {
        let s = self.get(pos);
        self.d.table.in_tag(s, set)
    }

    fn tag(&mut self, pos: [i32; 3], tag: &str) -> bool {
        let s = self.get(pos);
        let table = self.d.table.clone();
        table.tag(tag).is_ok_and(|t| table.in_tag(s, t))
    }

    fn is_air(&mut self, pos: [i32; 3]) -> bool {
        let s = self.get(pos);
        self.d.table.is_air(s)
    }

    /// `TreeFeature.validTreePos`.
    fn valid_tree_pos(&mut self, pos: [i32; 3]) -> bool {
        self.is_air(pos) || self.tag(pos, "minecraft:replaceable_by_trees")
    }

    /// The trunk placer's `validTreePos`.
    fn trunk_valid(&mut self, pos: [i32; 3]) -> bool {
        if self.valid_tree_pos(pos) {
            return true;
        }
        match &self.tree().trunk.kind {
            TrunkKind::UpwardsBranching {
                can_grow_through, ..
            } => self.is(pos, can_grow_through),
            _ => false,
        }
    }

    /// `TrunkPlacer.isFree`.
    fn is_free(&mut self, pos: [i32; 3]) -> bool {
        self.trunk_valid(pos) || self.tag(pos, "minecraft:logs")
    }

    fn state(&mut self, provider: &StateProvider, pos: [i32; 3]) -> u16 {
        provider.state(self.d, self.region, self.random, pos)
    }

    fn set_trunk(&mut self, pos: [i32; 3], state: u16) {
        self.trunks.insert(pos);
        self.region.set(pos, state, 19);
    }

    fn set_root(&mut self, pos: [i32; 3], state: u16) {
        self.roots.insert(pos);
        self.region.set(pos, state, 19);
    }

    fn set_foliage(&mut self, pos: [i32; 3], state: u16) {
        self.foliage.insert(pos);
        self.region.set(pos, state, 19);
    }

    fn set_decoration(&mut self, pos: [i32; 3], state: u16) {
        self.decorations.insert(pos);
        self.region.set(pos, state, 19);
    }

    fn below_trunk(&mut self, pos: [i32; 3]) {
        let provider = self.tree().below_trunk_provider.clone();
        if let Some(state) = provider.optional_state(self.d, self.region, self.random, pos) {
            self.set_trunk(pos, state);
        }
    }

    /// `placeLog` with an axis for sideways logs.
    fn place_log(&mut self, pos: [i32; 3], axis: Option<&str>) -> bool {
        if !self.trunk_valid(pos) {
            return false;
        }
        let provider = self.tree().trunk_provider.clone();
        let mut state = self.state(&provider, pos);
        if let Some(axis) = axis {
            state = self.table().with(state, "axis", axis).unwrap_or(state);
        }
        self.set_trunk(pos, state);
        true
    }

    fn place_log_if_free(&mut self, pos: [i32; 3]) {
        if self.is_free(pos) {
            self.place_log(pos, None);
        }
    }

    fn horizontal_random(&mut self) -> usize {
        HORIZONTAL[self.random.next_int_bounded(4) as usize]
    }

    // ------------------------------------------------------------ trunks

    fn tree_height(&mut self) -> i32 {
        let t = &self.tree().trunk;
        t.base_height
            + self.random.next_int_bounded(t.rand_a + 1)
            + self.random.next_int_bounded(t.rand_b + 1)
    }

    fn place_trunk(&mut self, height: i32, origin: [i32; 3]) -> Vec<Attachment> {
        let tree = self.tree();
        let at = |pos, radius_offset, double_trunk| Attachment {
            pos,
            radius_offset,
            double_trunk,
        };
        match &tree.trunk.kind {
            TrunkKind::Straight => {
                self.below_trunk(offset(origin, [0, -1, 0]));
                for y in 0..height {
                    self.place_log(offset(origin, [0, y, 0]), None);
                }
                vec![at(offset(origin, [0, height, 0]), 0, false)]
            }
            TrunkKind::Forking => {
                self.below_trunk(offset(origin, [0, -1, 0]));
                let mut out = Vec::new();
                let lean = self.horizontal_random();
                let lean_height = height - self.random.next_int_bounded(4) - 1;
                let mut lean_steps = 3 - self.random.next_int_bounded(3);
                let (mut tx, mut tz) = (origin[0], origin[2]);
                let mut ey = None;
                for yo in 0..height {
                    let yy = origin[1] + yo;
                    if yo >= lean_height && lean_steps > 0 {
                        tx += STEP[lean][0];
                        tz += STEP[lean][2];
                        lean_steps -= 1;
                    }
                    if self.place_log([tx, yy, tz], None) {
                        ey = Some(yy + 1);
                    }
                }
                if let Some(ey) = ey {
                    out.push(at([tx, ey, tz], 1, false));
                }
                let (mut tx, mut tz) = (origin[0], origin[2]);
                let branch = self.horizontal_random();
                if branch != lean {
                    let branch_pos = lean_height - self.random.next_int_bounded(2) - 1;
                    let mut steps = 1 + self.random.next_int_bounded(3);
                    let mut ey = None;
                    let mut yo = branch_pos;
                    while yo < height && steps > 0 {
                        if yo >= 1 {
                            let yy = origin[1] + yo;
                            tx += STEP[branch][0];
                            tz += STEP[branch][2];
                            if self.place_log([tx, yy, tz], None) {
                                ey = Some(yy + 1);
                            }
                        }
                        yo += 1;
                        steps -= 1;
                    }
                    if let Some(ey) = ey {
                        out.push(at([tx, ey, tz], 0, false));
                    }
                }
                out
            }
            TrunkKind::Giant => {
                self.giant_trunk(height, origin);
                vec![at(offset(origin, [0, height, 0]), 0, true)]
            }
            TrunkKind::MegaJungle => {
                self.giant_trunk(height, origin);
                let mut out = vec![at(offset(origin, [0, height, 0]), 0, true)];
                let mut branch_height = height - 2 - self.random.next_int_bounded(4);
                while branch_height > height / 2 {
                    let angle = self.random.next_float() * (std::f64::consts::PI * 2.0) as f32;
                    let (mut bx, mut bz) = (0, 0);
                    for b in 0..5 {
                        bx = (1.5f32 + super::carver::cos(angle as f64) * b as f32) as i32;
                        bz = (1.5f32 + super::carver::sin(angle as f64) * b as f32) as i32;
                        let pos = offset(origin, [bx, branch_height - 3 + b / 2, bz]);
                        self.place_log(pos, None);
                    }
                    out.push(at(offset(origin, [bx, branch_height, bz]), -2, false));
                    branch_height -= 2 + self.random.next_int_bounded(4);
                }
                out
            }
            TrunkKind::DarkOak => {
                let below = offset(origin, [0, -1, 0]);
                for o in [[0, 0, 0], [1, 0, 0], [0, 0, 1], [1, 0, 1]] {
                    self.below_trunk(offset(below, o));
                }
                let lean = self.horizontal_random();
                let lean_height = height - self.random.next_int_bounded(4);
                let mut lean_steps = 2 - self.random.next_int_bounded(3);
                let [x, y, z] = origin;
                let (mut tx, mut tz) = (x, z);
                let ey = y + height - 1;
                for dy in 0..height {
                    if dy >= lean_height && lean_steps > 0 {
                        tx += STEP[lean][0];
                        tz += STEP[lean][2];
                        lean_steps -= 1;
                    }
                    let pos = [tx, y + dy, tz];
                    let s = self.get(pos);
                    let air_or_leaves = self.table().is_air(s) || self.tag(pos, "minecraft:leaves");
                    if air_or_leaves {
                        for o in [[0, 0, 0], [1, 0, 0], [0, 0, 1], [1, 0, 1]] {
                            self.place_log(offset(pos, o), None);
                        }
                    }
                }
                let mut out = vec![at([tx, ey, tz], 0, true)];
                for ox in -1..=2 {
                    for oz in -1..=2 {
                        if (!(0..=1).contains(&ox) || !(0..=1).contains(&oz))
                            && self.random.next_int_bounded(3) <= 0
                        {
                            let length = self.random.next_int_bounded(3) + 2;
                            for branch_y in 0..length {
                                self.place_log([x + ox, ey - branch_y - 1, z + oz], None);
                            }
                            out.push(at([x + ox, ey, z + oz], 0, false));
                        }
                    }
                }
                out
            }
            TrunkKind::Fancy => self.fancy_trunk(height, origin),
            TrunkKind::Bending {
                min_height_for_leaves,
                bend_length,
            } => {
                let direction = self.horizontal_random();
                let log_height = height - 1;
                let mut pos = origin;
                self.below_trunk(offset(pos, [0, -1, 0]));
                let mut out = Vec::new();
                for i in 0..=log_height {
                    if i + 1 >= log_height + self.random.next_int_bounded(2) {
                        pos = moved(pos, direction, 1);
                    }
                    if self.valid_tree_pos(pos) {
                        self.place_log(pos, None);
                    }
                    if i >= *min_height_for_leaves {
                        out.push(at(pos, 0, false));
                    }
                    pos = moved(pos, UP, 1);
                }
                let length = bend_length.sample(self.random);
                for _ in 0..=length {
                    if self.valid_tree_pos(pos) {
                        self.place_log(pos, None);
                    }
                    out.push(at(pos, 0, false));
                    pos = moved(pos, direction, 1);
                }
                out
            }
            TrunkKind::Cherry {
                branch_count,
                branch_horizontal_length,
                branch_start,
                branch_end,
            } => {
                self.below_trunk(offset(origin, [0, -1, 0]));
                let first = 0.max(
                    height - 1
                        + super::providers::between_inclusive(
                            self.random,
                            branch_start.0,
                            branch_start.1,
                        ),
                );
                let mut second = 0.max(
                    height - 1
                        + super::providers::between_inclusive(
                            self.random,
                            branch_start.0,
                            branch_start.1 - 1,
                        ),
                );
                if second >= first {
                    second += 1;
                }
                let count = branch_count.sample(self.random);
                let middle = count == 3;
                let both = count >= 2;
                let trunk_height = if middle {
                    height
                } else if both {
                    first.max(second) + 1
                } else {
                    first + 1
                };
                for y in 0..trunk_height {
                    self.place_log(offset(origin, [0, y, 0]), None);
                }
                let mut out = Vec::new();
                if middle {
                    out.push(at(offset(origin, [0, trunk_height, 0]), 0, false));
                }
                let direction = self.horizontal_random();
                out.push(self.cherry_branch(
                    height,
                    origin,
                    direction,
                    first,
                    first < trunk_height - 1,
                    branch_horizontal_length,
                    branch_end,
                ));
                if both {
                    out.push(self.cherry_branch(
                        height,
                        origin,
                        opposite(direction),
                        second,
                        second < trunk_height - 1,
                        branch_horizontal_length,
                        branch_end,
                    ));
                }
                out
            }
            TrunkKind::Poplar {
                above_branches,
                branch_amount,
            } => {
                self.below_trunk(offset(origin, [0, -1, 0]));
                let up_to_branches = height - above_branches.sample(self.random);
                for y in 0..height {
                    self.place_log(offset(origin, [0, y, 0]), None);
                    // `Direction.allShuffled`, then the horizontal ones.
                    let mut all = [DOWN, UP, NORTH, SOUTH, WEST, EAST];
                    for i in (2..=6usize).rev() {
                        let swap = self.random.next_int_bounded(i as i32) as usize;
                        all.swap(i - 1, swap);
                    }
                    let directions: Vec<usize> = all.into_iter().filter(|d| *d >= NORTH).collect();
                    if up_to_branches - 1 == y {
                        let branches = branch_amount.sample(self.random);
                        for &dir in directions.iter().take(branches.max(0) as usize) {
                            self.place_log(
                                moved(offset(origin, [0, y, 0]), dir, 1),
                                Some(axis_name(dir)),
                            );
                        }
                    }
                }
                vec![at(offset(origin, [0, up_to_branches, 0]), 0, false)]
            }
            TrunkKind::UpwardsBranching {
                extra_branch_steps,
                branch_probability,
                extra_branch_length,
                ..
            } => {
                let mut out = Vec::new();
                for height_pos in 0..height {
                    let current = origin[1] + height_pos;
                    let log = [origin[0], current, origin[2]];
                    if self.place_log(log, None)
                        && height_pos < height - 1
                        && self.random.next_float() < *branch_probability
                    {
                        let dir = self.horizontal_random();
                        let length = extra_branch_length.sample(self.random);
                        let branch_pos =
                            0.max(length - extra_branch_length.sample(self.random) - 1);
                        let steps = extra_branch_steps.sample(self.random);
                        self.upwards_branch(height, &mut out, log, current, dir, branch_pos, steps);
                    }
                    if height_pos == height - 1 {
                        out.push(at([origin[0], current + 1, origin[2]], 0, false));
                    }
                }
                out
            }
        }
    }

    fn giant_trunk(&mut self, height: i32, origin: [i32; 3]) {
        let below = offset(origin, [0, -1, 0]);
        for o in [[0, 0, 0], [1, 0, 0], [0, 0, 1], [1, 0, 1]] {
            self.below_trunk(offset(below, o));
        }
        for hh in 0..height {
            self.place_log_if_free(offset(origin, [0, hh, 0]));
            if hh < height - 1 {
                self.place_log_if_free(offset(origin, [1, hh, 0]));
                self.place_log_if_free(offset(origin, [1, hh, 1]));
                self.place_log_if_free(offset(origin, [0, hh, 1]));
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn cherry_branch(
        &mut self,
        height: i32,
        origin: [i32; 3],
        dir: usize,
        offset_from_origin: i32,
        middle_continues: bool,
        horizontal_length: &IntProvider,
        branch_end: &IntProvider,
    ) -> Attachment {
        let mut log = offset(origin, [0, offset_from_origin, 0]);
        let end_offset = height - 1 + branch_end.sample(self.random);
        let extend = middle_continues || end_offset < offset_from_origin;
        let distance = horizontal_length.sample(self.random) + if extend { 1 } else { 0 };
        let end = offset(moved(origin, dir, distance), [0, end_offset, 0]);
        let steps = if extend { 2 } else { 1 };
        let sideways = axis_name(dir);
        for _ in 0..steps {
            log = moved(log, dir, 1);
            self.place_log(log, Some(sideways));
        }
        let vertical = if end[1] > log[1] { UP } else { DOWN };
        loop {
            let distance = manhattan(log, end);
            if distance == 0 {
                return Attachment {
                    pos: offset(end, [0, 1, 0]),
                    radius_offset: 0,
                    double_trunk: false,
                };
            }
            let chance = (end[1] - log[1]).abs() as f32 / distance as f32;
            let grow_vertically = self.random.next_float() < chance;
            log = moved(log, if grow_vertically { vertical } else { dir }, 1);
            self.place_log(
                log,
                if grow_vertically {
                    None
                } else {
                    Some(sideways)
                },
            );
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn upwards_branch(
        &mut self,
        height: i32,
        out: &mut Vec<Attachment>,
        log: [i32; 3],
        current: i32,
        dir: usize,
        branch_pos: i32,
        mut steps: i32,
    ) {
        let mut height_along = current + branch_pos;
        let (mut lx, mut lz) = (log[0], log[2]);
        let mut index = branch_pos;
        while index < height && steps > 0 {
            if index >= 1 {
                let y = current + index;
                lx += STEP[dir][0];
                lz += STEP[dir][2];
                height_along = y;
                if self.place_log([lx, y, lz], None) {
                    height_along += 1;
                }
                out.push(Attachment {
                    pos: [lx, y, lz],
                    radius_offset: 0,
                    double_trunk: false,
                });
            }
            index += 1;
            steps -= 1;
        }
        if height_along - current > 1 {
            let pos = [lx, height_along, lz];
            out.push(Attachment {
                pos,
                radius_offset: 0,
                double_trunk: false,
            });
            out.push(Attachment {
                pos: offset(pos, [0, -2, 0]),
                radius_offset: 0,
                double_trunk: false,
            });
        }
    }

    fn fancy_trunk(&mut self, tree_height: i32, origin: [i32; 3]) -> Vec<Attachment> {
        let height = tree_height + 2;
        let trunk_height = (height as f64 * 0.618).floor() as i32;
        self.below_trunk(offset(origin, [0, -1, 0]));
        let base = 1.0 * height as f64 / 13.0;
        let clusters_per_y = 1.min((1.382 + base * base).floor() as i32);
        let trunk_top = origin[1] + trunk_height;
        let mut relative_y = height - 5;
        // (attachment position, branch base Y)
        let mut coords: Vec<([i32; 3], i32)> =
            vec![(offset(origin, [0, relative_y, 0]), trunk_top)];
        while relative_y >= 0 {
            let shape = tree_shape(height, relative_y);
            if shape >= 0.0 {
                for _ in 0..clusters_per_y {
                    let radius = 1.0 * shape as f64 * (self.random.next_float() as f64 + 0.328);
                    let angle = (self.random.next_float() * 2.0f32) as f64 * std::f64::consts::PI;
                    let x = radius * angle.sin() + 0.5;
                    let z = radius * angle.cos() + 0.5;
                    let start =
                        offset(origin, [x.floor() as i32, relative_y - 1, z.floor() as i32]);
                    let end = offset(start, [0, 5, 0]);
                    if self.make_limb(start, end, false) {
                        let dx = origin[0] - start[0];
                        let dz = origin[2] - start[2];
                        let branch_height =
                            start[1] as f64 - ((dx * dx + dz * dz) as f64).sqrt() * 0.381;
                        let branch_top = if branch_height > trunk_top as f64 {
                            trunk_top
                        } else {
                            branch_height as i32
                        };
                        let branch_base = [origin[0], branch_top, origin[2]];
                        if self.make_limb(branch_base, start, false) {
                            coords.push((start, branch_base[1]));
                        }
                    }
                }
            }
            relative_y -= 1;
        }
        self.make_limb(origin, offset(origin, [0, trunk_height, 0]), true);
        for &(pos, branch_base) in &coords {
            let base = [origin[0], branch_base, origin[2]];
            if base != pos && (branch_base - origin[1]) as f64 >= height as f64 * 0.2 {
                self.make_limb(base, pos, true);
            }
        }
        coords
            .into_iter()
            .filter(|&(_, branch_base)| (branch_base - origin[1]) as f64 >= height as f64 * 0.2)
            .map(|(pos, _)| Attachment {
                pos,
                radius_offset: 0,
                double_trunk: false,
            })
            .collect()
    }

    fn make_limb(&mut self, start: [i32; 3], end: [i32; 3], place: bool) -> bool {
        if !place && start == end {
            return true;
        }
        let delta = [end[0] - start[0], end[1] - start[1], end[2] - start[2]];
        let steps = delta[0].abs().max(delta[1].abs().max(delta[2].abs()));
        let (dx, dy, dz) = (
            delta[0] as f32 / steps as f32,
            delta[1] as f32 / steps as f32,
            delta[2] as f32 / steps as f32,
        );
        for i in 0..=steps {
            let pos = offset(
                start,
                [
                    floor_f(0.5 + i as f32 * dx),
                    floor_f(0.5 + i as f32 * dy),
                    floor_f(0.5 + i as f32 * dz),
                ],
            );
            if place {
                let xd = (pos[0] - start[0]).abs();
                let zd = (pos[2] - start[2]).abs();
                let max = xd.max(zd);
                let axis = if max > 0 {
                    if xd == max {
                        "x"
                    } else {
                        "z"
                    }
                } else {
                    "y"
                };
                self.place_log(pos, Some(axis));
            } else if !self.is_free(pos) {
                return false;
            }
        }
        true
    }

    // ------------------------------------------------------------ roots

    fn place_roots(&mut self, origin: [i32; 3], trunk_origin: [i32; 3]) -> bool {
        let roots = self.tree().roots.as_ref().expect("a root placer");
        let mut column = origin;
        while column[1] < trunk_origin[1] {
            if !self.can_place_root(column) {
                return false;
            }
            column[1] += 1;
        }
        let mut positions = vec![offset(trunk_origin, [0, -1, 0])];
        for dir in HORIZONTAL {
            let pos = moved(trunk_origin, dir, 1);
            let mut in_direction = Vec::new();
            if !self.simulate_roots(pos, dir, trunk_origin, &mut in_direction, 0) {
                return false;
            }
            positions.extend(in_direction);
            positions.push(moved(trunk_origin, dir, 1));
        }
        let _ = roots;
        for pos in positions {
            self.place_root(pos);
        }
        true
    }

    fn can_place_root(&mut self, pos: [i32; 3]) -> bool {
        let roots = self.tree().roots.as_ref().expect("a root placer");
        self.valid_tree_pos(pos) || self.is(pos, &roots.can_grow_through)
    }

    fn simulate_roots(
        &mut self,
        pos: [i32; 3],
        dir: usize,
        origin: [i32; 3],
        out: &mut Vec<[i32; 3]>,
        layer: i32,
    ) -> bool {
        let roots = self.tree().roots.as_ref().expect("a root placer");
        if layer == roots.max_length || out.len() as i32 > roots.max_length {
            return false;
        }
        for p in self.potential_roots(pos, dir, origin) {
            if self.can_place_root(p) {
                out.push(p);
                if !self.simulate_roots(p, dir, origin, out, layer + 1) {
                    return false;
                }
            }
        }
        true
    }

    fn potential_roots(&mut self, pos: [i32; 3], dir: usize, origin: [i32; 3]) -> Vec<[i32; 3]> {
        let roots = self.tree().roots.as_ref().expect("a root placer");
        let below = offset(pos, [0, -1, 0]);
        let next = moved(pos, dir, 1);
        let width = manhattan(pos, origin);
        let (max_width, skew) = (roots.max_width, roots.skew);
        if width > max_width - 3 && width <= max_width {
            if self.random.next_float() < skew {
                vec![below, offset(next, [0, -1, 0])]
            } else {
                vec![below]
            }
        } else if width > max_width || self.random.next_float() < skew {
            vec![below]
        } else if self.random.next_bool() {
            vec![next]
        } else {
            vec![below]
        }
    }

    fn waterlogged(&mut self, pos: [i32; 3], state: u16) -> u16 {
        if !self.table().has_property(state, "waterlogged") {
            return state;
        }
        let s = self.get(pos);
        let fluid = self.table().fluid(s);
        let water = fluid == FLUID_WATER || fluid == FLUID_FLOWING_WATER;
        self.table()
            .with(state, "waterlogged", if water { "true" } else { "false" })
            .unwrap_or(state)
    }

    fn place_root(&mut self, pos: [i32; 3]) {
        let tree = self.tree();
        let roots = tree.roots.as_ref().expect("a root placer");
        if self.is(pos, &roots.muddy_roots_in) {
            let state = self.state(&roots.muddy_provider, pos);
            let state = self.waterlogged(pos, state);
            self.set_root(pos, state);
            return;
        }
        if !self.can_place_root(pos) {
            return;
        }
        let state = self.state(&roots.provider, pos);
        let state = self.waterlogged(pos, state);
        self.set_root(pos, state);
        if let Some((provider, chance)) = &roots.above {
            let above = offset(pos, [0, 1, 0]);
            if self.random.next_float() < *chance && self.is_air(above) {
                let state = self.state(provider, above);
                let state = self.waterlogged(above, state);
                self.set_root(above, state);
            }
        }
    }

    // ------------------------------------------------------------ foliage

    fn foliage_height(&mut self, tree_height: i32) -> i32 {
        match &self.tree().foliage.kind {
            FoliageKind::Blob(h)
            | FoliageKind::Fancy(h)
            | FoliageKind::Bush(h)
            | FoliageKind::Jungle(h) => *h,
            FoliageKind::Spruce(trunk_height) => {
                4.max(tree_height - trunk_height.sample(self.random))
            }
            FoliageKind::Pine(h) | FoliageKind::MegaPine(h) => h.sample(self.random),
            FoliageKind::Acacia => 0,
            FoliageKind::DarkOak => 4,
            FoliageKind::RandomSpread { height, .. }
            | FoliageKind::Cherry { height, .. }
            | FoliageKind::Poplar { height, .. } => height.sample(self.random),
        }
    }

    fn foliage_radius(&mut self, trunk_height: i32) -> i32 {
        let base = self.tree().foliage.radius.sample(self.random);
        match self.tree().foliage.kind {
            FoliageKind::Pine(_) => base + self.random.next_int_bounded((trunk_height + 1).max(1)),
            _ => base,
        }
    }

    /// `FoliagePlacer.shouldSkipLocation` (unsigned distances).
    fn skip(&mut self, dx: i32, y: i32, dz: i32, r: i32, double_trunk: bool) -> bool {
        match self.tree().foliage.kind {
            FoliageKind::Blob(_) => {
                dx == r && dz == r && (self.random.next_int_bounded(2) == 0 || y == 0)
            }
            FoliageKind::Fancy(_) => {
                let sq = |v: f32| v * v;
                sq(dx as f32 + 0.5) + sq(dz as f32 + 0.5) > (r * r) as f32
            }
            FoliageKind::Bush(_) => dx == r && dz == r && self.random.next_int_bounded(2) == 0,
            FoliageKind::Jungle(_) | FoliageKind::MegaPine(_) => {
                if dx + dz >= 7 {
                    true
                } else {
                    dx * dx + dz * dz > r * r
                }
            }
            FoliageKind::Spruce(_) | FoliageKind::Pine(_) => dx == r && dz == r && r > 0,
            FoliageKind::Acacia => {
                if y == 0 {
                    (dx > 1 || dz > 1) && dx != 0 && dz != 0
                } else {
                    dx == r && dz == r && r > 0
                }
            }
            FoliageKind::DarkOak => {
                if y == -1 && !double_trunk {
                    dx == r && dz == r
                } else {
                    y == 1 && dx + dz > r * 2 - 2
                }
            }
            FoliageKind::RandomSpread { .. } => false,
            FoliageKind::Cherry {
                wide_hole,
                corner_hole,
                ..
            } => {
                if y == -1 && (dx == r || dz == r) && self.random.next_float() < wide_hole {
                    return true;
                }
                let corner = dx == r && dz == r;
                if r > 2 {
                    corner || dx + dz > r * 2 - 2 && self.random.next_float() < corner_hole
                } else {
                    corner && self.random.next_float() < corner_hole
                }
            }
            FoliageKind::Poplar { .. } => unreachable!("poplar rows skip with their own shape"),
        }
    }

    /// `shouldSkipLocationSigned`.
    fn skip_signed(&mut self, dx: i32, y: i32, dz: i32, r: i32, double_trunk: bool) -> bool {
        if let FoliageKind::DarkOak = self.tree().foliage.kind {
            let edge = (dx == -r || dx >= r) && (dz == -r || dz >= r);
            if y == 0 && double_trunk && edge {
                return true;
            }
        }
        let (mdx, mdz) = if double_trunk {
            (dx.abs().min((dx - 1).abs()), dz.abs().min((dz - 1).abs()))
        } else {
            (dx.abs(), dz.abs())
        };
        self.skip(mdx, y, mdz, r, double_trunk)
    }

    fn leaves_row(&mut self, origin: [i32; 3], r: i32, y: i32, double_trunk: bool) {
        let extra = if double_trunk { 1 } else { 0 };
        for dx in -r..=r + extra {
            for dz in -r..=r + extra {
                if !self.skip_signed(dx, y, dz, r, double_trunk) {
                    self.try_place_leaf(offset(origin, [dx, y, dz]));
                }
            }
        }
    }

    /// `tryPlaceLeaf`.
    fn try_place_leaf(&mut self, pos: [i32; 3]) -> bool {
        let s = self.get(pos);
        let persistent = self.table().value(s, "persistent") == Some("true");
        if persistent || !self.valid_tree_pos(pos) {
            return false;
        }
        let provider = self.tree().foliage_provider.clone();
        let mut state = self.state(&provider, pos);
        if self.table().has_property(state, "waterlogged") {
            let here = self.get(pos);
            let source = self.table().fluid(here) == FLUID_WATER;
            state = self
                .table()
                .with(state, "waterlogged", if source { "true" } else { "false" })
                .unwrap_or(state);
        }
        self.set_foliage(pos, state);
        true
    }

    fn try_place_extension(&mut self, chance: f32, log: [i32; 3], pos: [i32; 3]) -> bool {
        if manhattan(pos, log) >= 7 {
            return false;
        }
        if self.random.next_float() > chance {
            return false;
        }
        self.try_place_leaf(pos)
    }

    #[allow(clippy::too_many_arguments)]
    fn leaves_row_hanging(
        &mut self,
        origin: [i32; 3],
        r: i32,
        y: i32,
        double_trunk: bool,
        chance: f32,
        extension: f32,
    ) {
        self.leaves_row(origin, r, y, double_trunk);
        let extra = if double_trunk { 1 } else { 0 };
        let log = offset(origin, [0, -1, 0]);
        for along in HORIZONTAL {
            let to_edge = clockwise(along);
            let positive = to_edge == SOUTH || to_edge == EAST;
            let to_edge_offset = if positive { r + extra } else { r };
            let mut pos = moved(
                moved(offset(origin, [0, y - 1, 0]), to_edge, to_edge_offset),
                along,
                -r,
            );
            let mut along_offset = -r;
            while along_offset < r + extra {
                let above = offset(pos, [0, 1, 0]);
                let leaves_above = self.foliage.contains(above);
                if leaves_above && self.try_place_extension(chance, log, pos) {
                    let below = offset(pos, [0, -1, 0]);
                    self.try_place_extension(extension, log, below);
                }
                along_offset += 1;
                pos = moved(pos, along, 1);
            }
        }
    }

    fn create_foliage(
        &mut self,
        tree_height: i32,
        a: Attachment,
        foliage_height: i32,
        leaf_radius: i32,
    ) {
        let offset_y = self.tree().foliage.offset.sample(self.random);
        let tree = self.tree();
        let dt = a.double_trunk;
        match &tree.foliage.kind {
            FoliageKind::Blob(_) => {
                for yo in (offset_y - foliage_height..=offset_y).rev() {
                    let r = (leaf_radius + a.radius_offset - 1 - yo / 2).max(0);
                    self.leaves_row(a.pos, r, yo, dt);
                }
            }
            FoliageKind::Fancy(_) => {
                for yo in (offset_y - foliage_height..=offset_y).rev() {
                    let r = leaf_radius
                        + if yo != offset_y && yo != offset_y - foliage_height {
                            1
                        } else {
                            0
                        };
                    self.leaves_row(a.pos, r, yo, dt);
                }
            }
            FoliageKind::Bush(_) => {
                for yo in (offset_y - foliage_height..=offset_y).rev() {
                    let r = leaf_radius + a.radius_offset - 1 - yo;
                    self.leaves_row(a.pos, r, yo, dt);
                }
            }
            FoliageKind::Jungle(_) => {
                let leaf_height = if dt {
                    foliage_height
                } else {
                    1 + self.random.next_int_bounded(2)
                };
                for yo in (offset_y - leaf_height..=offset_y).rev() {
                    let r = leaf_radius + a.radius_offset + 1 - yo;
                    self.leaves_row(a.pos, r, yo, dt);
                }
            }
            FoliageKind::Spruce(_) => {
                let mut r = self.random.next_int_bounded(2);
                let (mut max_r, mut min_r) = (1, 0);
                for yo in (-foliage_height..=offset_y).rev() {
                    self.leaves_row(a.pos, r, yo, dt);
                    if r >= max_r {
                        r = min_r;
                        min_r = 1;
                        max_r = (max_r + 1).min(leaf_radius + a.radius_offset);
                    } else {
                        r += 1;
                    }
                }
            }
            FoliageKind::Pine(_) => {
                let mut r = 0;
                for yo in (offset_y - foliage_height..=offset_y).rev() {
                    self.leaves_row(a.pos, r, yo, dt);
                    if r >= 1 && yo == offset_y - foliage_height + 1 {
                        r -= 1;
                    } else if r < leaf_radius + a.radius_offset {
                        r += 1;
                    }
                }
            }
            FoliageKind::Acacia => {
                let pos = offset(a.pos, [0, offset_y, 0]);
                self.leaves_row(pos, leaf_radius + a.radius_offset, -1 - foliage_height, dt);
                self.leaves_row(pos, leaf_radius - 1, -foliage_height, dt);
                self.leaves_row(pos, leaf_radius + a.radius_offset - 1, 0, dt);
            }
            FoliageKind::DarkOak => {
                let pos = offset(a.pos, [0, offset_y, 0]);
                if dt {
                    self.leaves_row(pos, leaf_radius + 2, -1, dt);
                    self.leaves_row(pos, leaf_radius + 3, 0, dt);
                    self.leaves_row(pos, leaf_radius + 2, 1, dt);
                    if self.random.next_bool() {
                        self.leaves_row(pos, leaf_radius, 2, dt);
                    }
                } else {
                    self.leaves_row(pos, leaf_radius + 2, -1, dt);
                    self.leaves_row(pos, leaf_radius + 1, 0, dt);
                }
            }
            FoliageKind::MegaPine(_) => {
                let pos = a.pos;
                let mut prev = 0;
                for yy in pos[1] - foliage_height + offset_y..=pos[1] + offset_y {
                    let yo = pos[1] - yy;
                    let smooth = leaf_radius
                        + a.radius_offset
                        + floor_f(yo as f32 / foliage_height as f32 * 3.5);
                    let jagged = if yo > 0 && smooth == prev && yy & 1 == 0 {
                        smooth + 1
                    } else {
                        smooth
                    };
                    self.leaves_row([pos[0], yy, pos[2]], jagged, 0, dt);
                    prev = smooth;
                }
            }
            FoliageKind::RandomSpread { attempts, .. } => {
                for _ in 0..*attempts {
                    let dx = self.random.next_int_bounded(leaf_radius)
                        - self.random.next_int_bounded(leaf_radius);
                    let dy = self.random.next_int_bounded(foliage_height)
                        - self.random.next_int_bounded(foliage_height);
                    let dz = self.random.next_int_bounded(leaf_radius)
                        - self.random.next_int_bounded(leaf_radius);
                    self.try_place_leaf(offset(a.pos, [dx, dy, dz]));
                }
            }
            FoliageKind::Cherry {
                hanging,
                hanging_extension,
                ..
            } => {
                let pos = offset(a.pos, [0, offset_y, 0]);
                let r = leaf_radius + a.radius_offset - 1;
                self.leaves_row(pos, r - 2, foliage_height - 3, dt);
                self.leaves_row(pos, r - 1, foliage_height - 4, dt);
                for y in (0..=foliage_height - 5).rev() {
                    self.leaves_row(pos, r, y, dt);
                }
                self.leaves_row_hanging(pos, r, -1, dt, *hanging, *hanging_extension);
                self.leaves_row_hanging(pos, r - 1, -2, dt, *hanging, *hanging_extension);
            }
            FoliageKind::Poplar { side_hole, .. } => {
                self.poplar_foliage(a, foliage_height, leaf_radius, offset_y, *side_hole)
            }
        }
        let _ = tree_height;
    }

    fn poplar_foliage(
        &mut self,
        a: Attachment,
        foliage_height: i32,
        leaf_radius: i32,
        offset_y: i32,
        side_hole: f32,
    ) {
        let dt = a.double_trunk;
        let pos = offset(a.pos, [0, offset_y, 0]);
        let r = leaf_radius + a.radius_offset - 1;
        let flip = self.random.next_bool();
        let h = foliage_height;
        self.poplar_row(pos, r - 2, h - 1, dt, h, flip, side_hole);
        self.poplar_row(pos, r - 1, h - 2, dt, h, flip, side_hole);
        self.poplar_row(pos, r - 1, h - 3, dt, h, flip, side_hole);
        for y in (1..=h - 4).rev() {
            self.poplar_row(pos, r, y, dt, h, flip, side_hole);
        }
        self.poplar_logs(pos, r, h - 4, dt, h, flip);
        self.poplar_row(pos, r - 1, 0, dt, h, flip, side_hole);
        self.poplar_row(pos, (r - 2).clamp(1, 2), -1, dt, h, flip, side_hole);
    }

    fn poplar_corner(dx: i32, dz: i32, r: i32, partial: bool, flip: bool) -> i32 {
        let small = if flip {
            dx > 0 && dz > 0 || dz < 0 && dx < 0
        } else {
            dx > 0 && dz < 0 || dz > 0 && dx < 0
        };
        if small {
            r - 1
        } else if partial {
            r + 1
        } else {
            r
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn poplar_row(
        &mut self,
        origin: [i32; 3],
        r: i32,
        y: i32,
        dt: bool,
        h: i32,
        flip: bool,
        side_hole: f32,
    ) {
        let extra = if dt { 1 } else { 0 };
        for dx in -r..=r + extra {
            for dz in -r..=r + extra {
                let partial = h - 1 == y || h - 2 == y;
                let corner = Self::poplar_corner(dx, dz, r, partial, flip);
                let (adx, adz) = (dx.abs(), dz.abs());
                let edge = adx == r || adz == r;
                let skip = if partial && edge {
                    true
                } else {
                    let side = if self.random.next_float() <= side_hole {
                        1
                    } else {
                        0
                    };
                    adx + adz > r * 2 - (corner + side)
                };
                if !skip {
                    self.try_place_leaf(offset(origin, [dx, y, dz]));
                }
            }
        }
    }

    fn poplar_logs(&mut self, origin: [i32; 3], r: i32, y: i32, dt: bool, h: i32, flip: bool) {
        let extra = if dt { 1 } else { 0 };
        for dx in -r..=r + extra {
            for dz in -r..=r + extra {
                let (adx, adz) = (dx.abs(), dz.abs());
                let partial = h - 1 == y || h - 2 == y;
                let within =
                    adx + adz <= r * 2 - (Self::poplar_corner(dx, dz, r, partial, flip) + 2);
                if within && (adz == 0 && r - adx >= 4 || adx == 0 && r - adz >= 4) {
                    let pos = offset(origin, [dx, y, dz]);
                    let axis = if adz == 0 { "x" } else { "z" };
                    let foliage_provider = self.tree().foliage_provider.clone();
                    let leaf = self.state(&foliage_provider, pos);
                    if self.get(pos) == leaf {
                        let trunk_provider = self.tree().trunk_provider.clone();
                        let log = self.state(&trunk_provider, pos);
                        let log = self.table().with(log, "axis", axis).unwrap_or(log);
                        self.set_foliage(pos, log);
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ decorators

    fn sorted(set: &JavaHashSet) -> Vec<[i32; 3]> {
        let mut list: Vec<[i32; 3]> = set.iter().collect();
        list.sort_by_key(|p| p[1]);
        list
    }

    /// `getLowestTrunkOrRootOfTree`.
    fn lowest(logs: &[[i32; 3]], roots: &[[i32; 3]]) -> Vec<[i32; 3]> {
        if roots.is_empty() {
            logs.to_vec()
        } else if !logs.is_empty() && roots[0][1] == logs[0][1] {
            logs.iter().chain(roots.iter()).copied().collect()
        } else {
            roots.to_vec()
        }
    }

    fn vine(&mut self, pos: [i32; 3], face: usize) -> Result<(), String> {
        let state = self.table().default_state("vine")?;
        let state = self
            .table()
            .with(state, NAMES[face], "true")
            .ok_or("vine face")?;
        self.set_decoration(pos, state);
        Ok(())
    }

    fn decorate(
        &mut self,
        decorators: &[Decorator],
        logs: &[[i32; 3]],
        leaves: &[[i32; 3]],
        roots: &[[i32; 3]],
    ) -> Result<(), String> {
        for decorator in decorators {
            match decorator {
                Decorator::Beehive(probability) => {
                    if logs.is_empty() {
                        continue;
                    }
                    if self.random.next_float() >= *probability {
                        continue;
                    }
                    let hive_y = if !leaves.is_empty() {
                        (leaves[0][1] - 1).max(logs[0][1] + 1)
                    } else {
                        (logs[0][1] + 1 + self.random.next_int_bounded(3))
                            .min(logs[logs.len() - 1][1])
                    };
                    let mut places: Vec<[i32; 3]> = logs
                        .iter()
                        .filter(|p| p[1] == hive_y)
                        .flat_map(|p| [EAST, SOUTH, WEST].map(|d| moved(*p, d, 1)))
                        .collect();
                    if places.is_empty() {
                        continue;
                    }
                    for i in (2..=places.len()).rev() {
                        let swap = self.random.next_int_bounded(i as i32) as usize;
                        places.swap(i - 1, swap);
                    }
                    let mut chosen = None;
                    for p in places {
                        if self.is_air(p) && self.is_air(moved(p, SOUTH, 1)) {
                            chosen = Some(p);
                            break;
                        }
                    }
                    if let Some(p) = chosen {
                        let nest = self.table().default_state("bee_nest")?;
                        let nest = self
                            .table()
                            .with(nest, "facing", "south")
                            .ok_or("bee nest facing")?;
                        self.set_decoration(p, nest);
                        // The hive's block entity, there only if the nest
                        // was written, takes 2 or 3 bees.
                        if self.region.can_write(p) {
                            let bees = 2 + self.random.next_int_bounded(2);
                            for _ in 0..bees {
                                self.random.next_int_bounded(599);
                            }
                        }
                    }
                }
                Decorator::PlaceOnGround {
                    tries,
                    radius,
                    height,
                    provider,
                } => {
                    let positions = Self::lowest(logs, roots);
                    if positions.is_empty() {
                        continue;
                    }
                    let first = positions[0];
                    let min_y = first[1];
                    let (mut min_x, mut max_x, mut min_z, mut max_z) =
                        (first[0], first[0], first[2], first[2]);
                    for p in &positions {
                        if p[1] == min_y {
                            min_x = min_x.min(p[0]);
                            max_x = max_x.max(p[0]);
                            min_z = min_z.min(p[2]);
                            max_z = max_z.max(p[2]);
                        }
                    }
                    let (bx0, bx1) = (min_x - radius, max_x + radius);
                    let (by0, by1) = (min_y - height, min_y + height);
                    let (bz0, bz1) = (min_z - radius, max_z + radius);
                    for _ in 0..*tries {
                        let x = super::providers::between_inclusive(self.random, bx0, bx1);
                        let y = super::providers::between_inclusive(self.random, by0, by1);
                        let z = super::providers::between_inclusive(self.random, bz0, bz1);
                        let pos = [x, y, z];
                        let above = offset(pos, [0, 1, 0]);
                        let a = self.get(above);
                        let air_or_vine = self.table().is_air(a)
                            || self.table().block_of(a) == self.table().block("vine")?;
                        if !air_or_vine {
                            continue;
                        }
                        let s = self.get(pos);
                        if !self.table().flag(s, SOLID_RENDER) {
                            continue;
                        }
                        if self
                            .region
                            .height_at(Heightmap::MotionBlockingNoLeaves, x, z)
                            <= above[1]
                        {
                            let state = self.state(provider, above);
                            self.set_decoration(above, state);
                        }
                    }
                }
                Decorator::AlterGround(provider) => {
                    let positions = Self::lowest(logs, roots);
                    if positions.is_empty() {
                        continue;
                    }
                    let min_y = positions[0][1];
                    for pos in positions.iter().filter(|p| p[1] == min_y) {
                        for corner in [[-1, 0, -1], [2, 0, -1], [-1, 0, 2], [2, 0, 2]] {
                            self.alter_circle(provider, offset(*pos, corner));
                        }
                        for _ in 0..5 {
                            let placement = self.random.next_int_bounded(64);
                            let (xx, zz) = (placement % 8, placement / 8);
                            if xx == 0 || xx == 7 || zz == 0 || zz == 7 {
                                self.alter_circle(provider, offset(*pos, [-3 + xx, 0, -3 + zz]));
                            }
                        }
                    }
                }
                Decorator::TrunkVine => {
                    for &pos in logs {
                        for (side, face) in
                            [(WEST, EAST), (EAST, WEST), (NORTH, SOUTH), (SOUTH, NORTH)]
                        {
                            if self.random.next_int_bounded(3) > 0 {
                                let p = moved(pos, side, 1);
                                if self.is_air(p) {
                                    self.vine(p, face)?;
                                }
                            }
                        }
                    }
                }
                Decorator::LeaveVine(probability) => {
                    for &pos in leaves {
                        for (side, face) in
                            [(WEST, EAST), (EAST, WEST), (NORTH, SOUTH), (SOUTH, NORTH)]
                        {
                            if self.random.next_float() < *probability {
                                let p = moved(pos, side, 1);
                                if self.is_air(p) {
                                    self.vine(p, face)?;
                                    let mut below = offset(p, [0, -1, 0]);
                                    let mut left = 4;
                                    while self.is_air(below) && left > 0 {
                                        self.vine(below, face)?;
                                        below = offset(below, [0, -1, 0]);
                                        left -= 1;
                                    }
                                }
                            }
                        }
                    }
                }
                Decorator::Cocoa(probability) => {
                    if self.random.next_float() >= *probability || logs.is_empty() {
                        continue;
                    }
                    let tree_y = logs[0][1];
                    for &pos in logs.iter().filter(|p| p[1] - tree_y <= 2) {
                        for direction in HORIZONTAL {
                            if self.random.next_float() <= 0.25 {
                                let p = moved(pos, opposite(direction), 1);
                                if self.is_air(p) {
                                    let age = self.random.next_int_bounded(3);
                                    let cocoa = self.table().default_state("cocoa")?;
                                    let cocoa = self
                                        .table()
                                        .with(cocoa, "age", &age.to_string())
                                        .ok_or("cocoa age")?;
                                    let cocoa = self
                                        .table()
                                        .with(cocoa, "facing", NAMES[direction])
                                        .ok_or("cocoa facing")?;
                                    self.set_decoration(p, cocoa);
                                }
                            }
                        }
                    }
                }
                Decorator::AttachedToLeaves {
                    probability,
                    exclusion_xz,
                    exclusion_y,
                    provider,
                    required_empty,
                    directions,
                } => {
                    let mut blacklist = std::collections::HashSet::new();
                    let mut shuffled = leaves.to_vec();
                    for i in (2..=shuffled.len()).rev() {
                        let swap = self.random.next_int_bounded(i as i32) as usize;
                        shuffled.swap(i - 1, swap);
                    }
                    for leaf in shuffled {
                        let direction = directions
                            [self.random.next_int_bounded(directions.len() as i32) as usize];
                        let placement = moved(leaf, direction, 1);
                        if blacklist.contains(&placement)
                            || self.random.next_float() >= *probability
                        {
                            continue;
                        }
                        if !(1..=*required_empty).all(|i| self.is_air(moved(leaf, direction, i))) {
                            continue;
                        }
                        for x in -exclusion_xz..=*exclusion_xz {
                            for y in -exclusion_y..=*exclusion_y {
                                for z in -exclusion_xz..=*exclusion_xz {
                                    blacklist.insert(offset(placement, [x, y, z]));
                                }
                            }
                        }
                        let state = self.state(provider, placement);
                        self.set_decoration(placement, state);
                    }
                }
                Decorator::AttachedToLogs {
                    probability,
                    provider,
                    directions,
                } => {
                    let mut shuffled = logs.to_vec();
                    for i in (2..=shuffled.len()).rev() {
                        let swap = self.random.next_int_bounded(i as i32) as usize;
                        shuffled.swap(i - 1, swap);
                    }
                    for pos in shuffled {
                        let direction = directions
                            [self.random.next_int_bounded(directions.len() as i32) as usize];
                        let p = moved(pos, direction, 1);
                        if self.random.next_float() <= *probability && self.is_air(p) {
                            let state = self.state(provider, p);
                            self.set_decoration(p, state);
                        }
                    }
                }
                Decorator::ShelfMushroom(probability) => {
                    if self.random.next_float() >= *probability || logs.is_empty() {
                        continue;
                    }
                    if logs[0][1] == logs[logs.len() - 1][1] {
                        let (first, last) = (logs[0], logs[logs.len() - 1]);
                        let faces = if first[0] != last[0] {
                            [NORTH, SOUTH]
                        } else {
                            [EAST, WEST]
                        };
                        for &pos in logs {
                            for facing in faces {
                                if self.random.next_float() <= 0.25 {
                                    let p = moved(pos, facing, 1);
                                    if self.shelf_replaceable(p)?
                                        && !self.shelf_adjacent(p)?
                                        && !self.shelf_adjacent(pos)?
                                    {
                                        self.place_shelf(p, facing)?;
                                    }
                                }
                            }
                        }
                    } else {
                        let first = self.horizontal_random();
                        let faces = [first, clockwise(first)];
                        let base = logs[0][1];
                        for &pos in logs {
                            let dy = pos[1] - base;
                            if !(1..=4).contains(&dy) {
                                continue;
                            }
                            for facing in faces {
                                if self.random.next_float() <= 0.25 {
                                    let p = moved(pos, facing, 1);
                                    if !self.shelf_replaceable(p)? {
                                        continue;
                                    }
                                    let below = offset(p, [0, -1, 0]);
                                    let b = self.get(below);
                                    if self.table().block_of(b)
                                        == self.table().block("shelf_mushroom")?
                                    {
                                        continue;
                                    }
                                    self.place_shelf(p, facing)?;
                                    break;
                                }
                            }
                        }
                    }
                }
                Decorator::CreakingHeart(probability) => {
                    if logs.is_empty() || self.random.next_float() >= *probability {
                        continue;
                    }
                    let mut places = logs.to_vec();
                    for i in (2..=places.len()).rev() {
                        let swap = self.random.next_int_bounded(i as i32) as usize;
                        places.swap(i - 1, swap);
                    }
                    let mut target = None;
                    'outer: for p in places {
                        for d in 0..6 {
                            if !self.tag(moved(p, d, 1), "minecraft:logs") {
                                continue 'outer;
                            }
                        }
                        target = Some(p);
                        break;
                    }
                    if let Some(p) = target {
                        let heart = self.table().default_state("creaking_heart")?;
                        let heart = self
                            .table()
                            .with(heart, "creaking_heart_state", "dormant")
                            .ok_or("heart state")?;
                        let heart = self
                            .table()
                            .with(heart, "natural", "true")
                            .ok_or("heart natural")?;
                        self.set_decoration(p, heart);
                    }
                }
                Decorator::PaleMoss {
                    leaves: on_leaves,
                    trunk,
                    ground,
                } => {
                    let mut shuffled = logs.to_vec();
                    for i in (2..=shuffled.len()).rev() {
                        let swap = self.random.next_int_bounded(i as i32) as usize;
                        shuffled.swap(i - 1, swap);
                    }
                    // The first lowest log of the shuffled copy.
                    let Some(&origin) = shuffled.iter().min_by_key(|p| p[1]) else {
                        continue;
                    };
                    if self.random.next_float() < *ground {
                        // The feature itself, without placement.
                        let patch = self
                            .d
                            .features
                            .get("minecraft:pale_moss_patch")
                            .ok_or("no feature minecraft:pale_moss_patch")?
                            .clone();
                        patch.place(self.d, self.region, self.random, offset(origin, [0, 1, 0]))?;
                    }
                    for (positions, probability) in [(logs, *trunk), (leaves, *on_leaves)] {
                        for &pos in positions {
                            if self.random.next_float() < probability {
                                let down = offset(pos, [0, -1, 0]);
                                if self.is_air(down) {
                                    self.moss_hanger(down)?;
                                }
                            }
                        }
                    }
                }
            }
        }
        Ok(())
    }

    /// `PaleMossDecorator.addMossHanger`.
    fn moss_hanger(&mut self, mut pos: [i32; 3]) -> Result<(), String> {
        let moss = self.table().default_state("pale_hanging_moss")?;
        let hanging = self.table().with(moss, "tip", "false").ok_or("moss tip")?;
        let tip = self.table().with(moss, "tip", "true").ok_or("moss tip")?;
        while self.is_air(offset(pos, [0, -1, 0])) && self.random.next_float() >= 0.5 {
            self.set_decoration(pos, hanging);
            pos = offset(pos, [0, -1, 0]);
        }
        self.set_decoration(pos, tip);
        Ok(())
    }

    fn alter_circle(&mut self, provider: &StateProvider, center: [i32; 3]) {
        for xx in -2i32..=2 {
            for zz in -2i32..=2 {
                if xx.abs() != 2 || zz.abs() != 2 {
                    let pos = offset(center, [xx, 0, zz]);
                    for dy in (-3..=2).rev() {
                        let cursor = offset(pos, [0, dy, 0]);
                        if let Some(state) =
                            provider.optional_state(self.d, self.region, self.random, cursor)
                        {
                            self.set_decoration(cursor, state);
                            break;
                        }
                        if !self.is_air(cursor) && dy < 0 {
                            break;
                        }
                    }
                }
            }
        }
    }

    fn shelf_replaceable(&mut self, pos: [i32; 3]) -> Result<bool, String> {
        let s = self.get(pos);
        if !self.table().flag(s, super::blocks::REPLACEABLE) {
            return Ok(false);
        }
        let water = self.table().block("water")?;
        for o in [[0, 0, 0], [1, 0, 0], [-1, 0, 0], [0, 0, -1], [0, 0, 1]] {
            let s = self.get(offset(pos, o));
            if self.table().block_of(s) == water {
                return Ok(false);
            }
        }
        Ok(true)
    }

    fn shelf_adjacent(&mut self, pos: [i32; 3]) -> Result<bool, String> {
        let shelf = self.table().block("shelf_mushroom")?;
        for d in HORIZONTAL {
            let s = self.get(moved(pos, d, 1));
            if self.table().block_of(s) == shelf {
                return Ok(true);
            }
        }
        Ok(false)
    }

    fn place_shelf(&mut self, pos: [i32; 3], facing: usize) -> Result<(), String> {
        let age = self.random.next_int_bounded(2);
        let state = self.table().default_state("shelf_mushroom")?;
        let state = self
            .table()
            .with(state, "age", &age.to_string())
            .ok_or("shelf age")?;
        let state = self
            .table()
            .with(state, "facing", NAMES[facing])
            .ok_or("shelf facing")?;
        self.set_decoration(pos, state);
        Ok(())
    }
}

/// `FancyTrunkPlacer.treeShape`.
fn tree_shape(height: i32, y: i32) -> f32 {
    if (y as f32) < height as f32 * 0.3 {
        return -1.0;
    }
    let radius = height as f32 / 2.0;
    let adjacent = radius - y as f32;
    let mut distance = ((radius * radius - adjacent * adjacent) as f64).sqrt() as f32;
    if adjacent == 0.0 {
        distance = radius;
    } else if adjacent.abs() >= radius {
        return 0.0;
    }
    distance * 0.5
}

/// A box of positions (`BoundingBox`), with a voxel shape over it.
struct Shape {
    min: [i32; 3],
    size: [i32; 3],
    full: Vec<bool>,
}

impl Shape {
    fn new(min: [i32; 3], max: [i32; 3]) -> Shape {
        let size = [
            max[0] - min[0] + 1,
            max[1] - min[1] + 1,
            max[2] - min[2] + 1,
        ];
        Shape {
            min,
            size,
            full: vec![false; (size[0] * size[1] * size[2]) as usize],
        }
    }

    fn inside(&self, pos: [i32; 3]) -> bool {
        (0..3).all(|i| pos[i] >= self.min[i] && pos[i] < self.min[i] + self.size[i])
    }

    fn cell(&self, x: i32, y: i32, z: i32) -> usize {
        ((x * self.size[1] + y) * self.size[2] + z) as usize
    }

    fn is_full(&self, x: i32, y: i32, z: i32) -> bool {
        self.full[self.cell(x, y, z)]
    }

    fn fill(&mut self, pos: [i32; 3]) {
        let c = self.cell(
            pos[0] - self.min[0],
            pos[1] - self.min[1],
            pos[2] - self.min[2],
        );
        self.full[c] = true;
    }

    fn full_at(&self, pos: [i32; 3]) -> bool {
        self.is_full(
            pos[0] - self.min[0],
            pos[1] - self.min[1],
            pos[2] - self.min[2],
        )
    }

    /// `DiscreteVoxelShape.forAllFaces`: Z faces (X, then Y, then Z), then Y
    /// faces (Z, X, Y), then X faces (Y, Z, X); along each line, the negative
    /// face entering a run and the positive face leaving it.
    fn faces(&self) -> Vec<(usize, [i32; 3])> {
        let mut out = Vec::new();
        let [sx, sy, sz] = self.size;
        let line = |out: &mut Vec<(usize, [i32; 3])>,
                    len: i32,
                    at: &dyn Fn(i32) -> [i32; 3],
                    neg: usize,
                    pos: usize| {
            let mut last = false;
            for c in 0..=len {
                let full = c != len && {
                    let p = at(c);
                    self.is_full(p[0], p[1], p[2])
                };
                if !last && full {
                    out.push((neg, at(c)));
                }
                if last && !full {
                    out.push((pos, at(c - 1)));
                }
                last = full;
            }
        };
        for a in 0..sx {
            for b in 0..sy {
                line(&mut out, sz, &|c| [a, b, c], NORTH, SOUTH);
            }
        }
        for a in 0..sz {
            for b in 0..sx {
                line(&mut out, sy, &|c| [b, c, a], DOWN, UP);
            }
        }
        for a in 0..sy {
            for b in 0..sz {
                line(&mut out, sx, &|c| [c, a, b], WEST, EAST);
            }
        }
        out
    }
}

impl Tree {
    /// `TreeFeature.place`.
    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let mut p = Placing {
            d,
            region,
            random,
            tree: Some(self),
            roots: JavaHashSet::new(),
            trunks: JavaHashSet::new(),
            foliage: JavaHashSet::new(),
            decorations: JavaHashSet::new(),
        };
        let placed = p.do_place(origin)?;
        if !placed || (p.trunks.is_empty() && p.foliage.is_empty()) {
            return Ok(false);
        }
        let logs = Placing::sorted(&p.trunks);
        let leaves = Placing::sorted(&p.foliage);
        let roots = Placing::sorted(&p.roots);
        if !self.decorators.is_empty() {
            p.decorate(&self.decorators, &logs, &leaves, &roots)?;
        }
        let mut min = [i32::MAX; 3];
        let mut max = [i32::MIN; 3];
        for set in [&p.roots, &p.trunks, &p.foliage, &p.decorations] {
            for pos in set.iter() {
                for i in 0..3 {
                    min[i] = min[i].min(pos[i]);
                    max[i] = max[i].max(pos[i]);
                }
            }
        }
        if [&p.roots, &p.trunks, &p.foliage, &p.decorations]
            .iter()
            .any(|s| s.unordered)
        {
            return Err("a tree's position set needs identity hash order".into());
        }
        let shape = p.update_leaves(min, max)?;
        p.update_edges(&shape)?;
        Ok(true)
    }
}

impl Placing<'_, '_> {
    fn do_place(&mut self, origin: [i32; 3]) -> Result<bool, String> {
        let tree = self.tree();
        let tree_height = self.tree_height();
        let foliage_height = self.foliage_height(tree_height);
        let trunk_height = tree_height - foliage_height;
        let leaf_radius = self.foliage_radius(trunk_height);
        let trunk_origin = match &tree.roots {
            Some(roots) => offset(origin, [0, roots.trunk_offset_y.sample(self.random), 0]),
            None => origin,
        };
        let min_y = origin[1].min(trunk_origin[1]);
        let max_y = origin[1].max(trunk_origin[1]) + tree_height + 1;
        let (world_min, world_max) = (
            self.region.min_y(),
            self.region.min_y() + self.region.height() - 1,
        );
        if min_y < world_min + 1 || max_y > world_max + 1 {
            return Ok(false);
        }
        let clipped = self.max_free_height(tree_height, trunk_origin);
        let min_clipped = match tree.size {
            FeatureSize::Two { min_clipped, .. } | FeatureSize::Three { min_clipped, .. } => {
                min_clipped
            }
        };
        if !(clipped >= tree_height || min_clipped.is_some_and(|m| clipped >= m)) {
            return Ok(false);
        }
        if tree.roots.is_some() && !self.place_roots(origin, trunk_origin) {
            return Ok(false);
        }
        let attachments = self.place_trunk(clipped, trunk_origin);
        for a in attachments {
            self.create_foliage(clipped, a, foliage_height, leaf_radius);
        }
        Ok(true)
    }

    fn size_at(&self, tree_height: i32, y: i32) -> i32 {
        match self.tree().size {
            FeatureSize::Two {
                limit,
                lower,
                upper,
                ..
            } => {
                if y < limit {
                    lower
                } else {
                    upper
                }
            }
            FeatureSize::Three {
                limit,
                upper_limit,
                lower,
                middle,
                upper,
                ..
            } => {
                if y < limit {
                    lower
                } else if y >= tree_height - upper_limit {
                    upper
                } else {
                    middle
                }
            }
        }
    }

    fn max_free_height(&mut self, max_height: i32, origin: [i32; 3]) -> i32 {
        let vine = self.d.table.block("vine").unwrap_or(u16::MAX);
        for y in 0..=max_height + 1 {
            let r = self.size_at(max_height, y);
            for x in -r..=r {
                for z in -r..=r {
                    let pos = offset(origin, [x, y, z]);
                    let free = self.is_free(pos);
                    let is_vine = {
                        let s = self.get(pos);
                        self.table().block_of(s) == vine
                    };
                    if !free || (!self.tree().ignore_vines && is_vine) {
                        return y - 2;
                    }
                }
            }
        }
        max_height
    }

    /// `LeavesBlock.getOptionalDistanceAt`: 0 next to logs (the block tag),
    /// a leaf's distance, or none.
    fn leaf_distance(&mut self, state: u16) -> Option<i32> {
        let table = self.d.table.clone();
        if table
            .tag("minecraft:prevents_nearby_leaf_decay")
            .is_ok_and(|t| table.in_tag(state, t))
        {
            return Some(0);
        }
        let block = table.block_of(state) as usize;
        let leaves_distance = table.properties[block]
            .iter()
            .any(|p| p.name == "distance" && p.values.len() == 7 && p.values[0] == "1");
        if leaves_distance {
            table.value(state, "distance").and_then(|v| v.parse().ok())
        } else {
            None
        }
    }

    /// `TreeFeature.updateLeaves`: leaf distances from the logs, as a voxel
    /// shape of the tree.
    fn update_leaves(&mut self, min: [i32; 3], max: [i32; 3]) -> Result<Shape, String> {
        let mut shape = Shape::new(min, max);
        for pos in self.decorations.iter().chain(self.roots.iter()) {
            if shape.inside(pos) {
                shape.fill(pos);
            }
        }
        let mut to_check: Vec<JavaHashSet> = (0..7).map(|_| JavaHashSet::new()).collect();
        for pos in self.trunks.iter() {
            to_check[0].insert(pos);
        }
        let mut smallest = 0usize;
        loop {
            while smallest >= 7 || !to_check[smallest].is_empty() {
                if smallest >= 7 {
                    if to_check.iter().any(|s| s.unordered) {
                        return Err("a leaf distance set needs identity hash order".into());
                    }
                    return Ok(shape);
                }
                // `iterator.next()` and `iterator.remove()`.
                let pos = to_check[smallest].poll_first().expect("not empty");
                if !shape.inside(pos) {
                    continue;
                }
                if smallest != 0 {
                    let state = self.get(pos);
                    let with = self
                        .table()
                        .with(state, "distance", &smallest.to_string())
                        .ok_or("leaf distance")?;
                    self.region.set(pos, with, 19);
                }
                shape.fill(pos);
                for step in STEP {
                    let n = offset(pos, step);
                    if !shape.inside(n) || shape.full_at(n) {
                        continue;
                    }
                    let current = self.get(n);
                    if let Some(distance) = self.leaf_distance(current) {
                        let next = distance.min(smallest as i32 + 1);
                        if next < 7 {
                            to_check[next as usize].insert(n);
                            smallest = smallest.min(next as usize);
                        }
                    }
                }
            }
            smallest += 1;
        }
    }

    /// `StructureTemplate.updateShapeAtEdge(level, 3, shape, …)`.
    fn update_edges(&mut self, shape: &Shape) -> Result<(), String> {
        for (direction, cell) in shape.faces() {
            let pos = [
                shape.min[0] + cell[0],
                shape.min[1] + cell[1],
                shape.min[2] + cell[2],
            ];
            let neighbor = moved(pos, direction, 1);
            let state = self.get(pos);
            let neighbor_state = self.get(neighbor);
            let new_state = self
                .d
                .update_shape(self.region, state, pos, direction, None)?;
            if new_state != state {
                self.region.set(pos, new_state, 2);
            }
            let new_neighbor = self.d.update_shape(
                self.region,
                neighbor_state,
                neighbor,
                opposite(direction),
                Some((pos, new_state)),
            )?;
            if new_neighbor != neighbor_state {
                self.region.set(neighbor, new_neighbor, 2);
            }
        }
        Ok(())
    }
}

/// `FallenTreeFeature`: a stump, and a log lying beside it when the ground
/// holds it.
#[derive(Debug)]
pub struct FallenTree {
    trunk_provider: Arc<StateProvider>,
    length: IntProvider,
    stump_decorators: Vec<Decorator>,
    log_decorators: Vec<Decorator>,
}

impl FallenTree {
    pub fn parse(json: &Json, provider: Provider) -> Result<FallenTree, String> {
        Ok(FallenTree {
            trunk_provider: provider(json.field("trunk_provider")?)?,
            length: int(json, "log_length")?,
            stump_decorators: parse_decorators(json.field("stump_decorators")?, provider)?,
            log_decorators: parse_decorators(json.field("log_decorators")?, provider)?,
        })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let mut p = Placing {
            d,
            region,
            random,
            tree: None,
            roots: JavaHashSet::new(),
            trunks: JavaHashSet::new(),
            foliage: JavaHashSet::new(),
            decorations: JavaHashSet::new(),
        };
        let stump = self.place_log(&mut p, origin, None);
        if !self.stump_decorators.is_empty() {
            p.decorate(&self.stump_decorators, &[stump], &[], &[])?;
        }
        let direction = p.horizontal_random();
        let length = self.length.sample(p.random) - 2;
        let mut start = moved(origin, direction, 2 + p.random.next_int_bounded(2));
        start[1] += 1;
        for _ in 0..6 {
            if p.valid_tree_pos(start) && Self::over_solid_ground(&mut p, start) {
                break;
            }
            start[1] -= 1;
        }
        if self.can_place_log(&mut p, length, start, direction) {
            let mut logs = JavaHashSet::new();
            let mut pos = start;
            for _ in 0..length {
                logs.insert(self.place_log(&mut p, pos, Some(axis_name(direction))));
                pos = moved(pos, direction, 1);
            }
            if logs.unordered {
                return Err("a fallen log's position set needs identity hash order".into());
            }
            if !self.log_decorators.is_empty() {
                let logs = Placing::sorted(&logs);
                p.decorate(&self.log_decorators, &logs, &[], &[])?;
            }
        }
        Ok(true)
    }

    fn over_solid_ground(p: &mut Placing, pos: [i32; 3]) -> bool {
        let below = p.get(offset(pos, [0, -1, 0]));
        p.table().flag(below, STURDY << UP)
    }

    fn can_place_log(
        &self,
        p: &mut Placing,
        length: i32,
        start: [i32; 3],
        direction: usize,
    ) -> bool {
        let mut gap = 0;
        let mut pos = start;
        for _ in 0..length {
            if !p.valid_tree_pos(pos) {
                return false;
            }
            if !Self::over_solid_ground(p, pos) {
                gap += 1;
                if gap > 2 {
                    return false;
                }
            } else {
                gap = 0;
            }
            pos = moved(pos, direction, 1);
        }
        true
    }

    /// `placeLogBlock`: written with neighbour updates, which a generation
    /// region does not run, and marked above for post-processing.
    fn place_log(&self, p: &mut Placing, pos: [i32; 3], axis: Option<&str>) -> [i32; 3] {
        let mut state = p.state(&self.trunk_provider, pos);
        if let Some(axis) = axis {
            state = p.table().with(state, "axis", axis).unwrap_or(state);
        }
        p.region.set(pos, state, 3);
        p.d.mark_above(p.region, pos);
        pos
    }
}
