//! Large plants that are not trees: huge mushrooms and bamboo (VMC-025b);
//! root systems, vines and coral trees and claws (VMC-025c).

use std::sync::Arc;

use super::blocks::{
    BlockSet, BlockTable, Heightmap, FLUID_FLOWING_LAVA, FLUID_FLOWING_WATER, FLUID_LAVA,
    FLUID_WATER, SOLID, STURDY,
};
use super::feature::Decoration;
use super::json::Json;
use super::placement::PlacedFeature;
use super::predicate::{offset, BlockPredicate};
use super::random::Random;
use super::region::Region;
use super::state_provider::StateProvider;

/// `HugeRedMushroomFeature` and `HugeBrownMushroomFeature`.
#[derive(Debug)]
pub struct HugeMushroom {
    red: bool,
    cap: Arc<StateProvider>,
    stem: Arc<StateProvider>,
    foliage_radius: i32,
    can_place_on: BlockPredicate,
    leaves: BlockSet,
    replaceable: BlockSet,
}

impl HugeMushroom {
    pub fn parse(
        json: &Json,
        table: &BlockTable,
        red: bool,
        provider: &mut dyn FnMut(&Json) -> Result<Arc<StateProvider>, String>,
    ) -> Result<HugeMushroom, String> {
        Ok(HugeMushroom {
            red,
            cap: provider(json.field("cap_provider")?)?,
            stem: provider(json.field("stem_provider")?)?,
            foliage_radius: json.get("foliage_radius").map_or(Ok(2), Json::as_i32)?,
            can_place_on: BlockPredicate::parse(json.field("can_place_on")?, table)?,
            leaves: table.tag("minecraft:leaves")?.clone(),
            replaceable: table.tag("minecraft:replaceable_by_mushrooms")?.clone(),
        })
    }

    /// `getTreeRadiusForHeight(-1, -1, radius, dy)`: for red mushrooms the
    /// trunk and tree heights vanilla passes leave every radius zero.
    fn radius_at(&self, dy: i32) -> i32 {
        if self.red || dy <= 3 {
            0
        } else {
            self.foliage_radius
        }
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let mut height = random.next_int_bounded(3) + 4;
        if random.next_int_bounded(12) == 0 {
            height *= 2;
        }
        if !self.valid_position(d, region, origin, height) {
            return Ok(false);
        }
        if self.red {
            self.red_cap(d, region, random, origin, height);
        } else {
            self.brown_cap(d, region, random, origin, height);
        }
        for dy in 0..height {
            let state = self.stem.state(d, region, random, origin);
            self.place_block(d, region, offset(origin, [0, dy, 0]), state);
        }
        Ok(true)
    }

    fn valid_position(
        &self,
        d: &Decoration,
        region: &mut Region,
        origin: [i32; 3],
        height: i32,
    ) -> bool {
        let y = origin[1];
        let min_y = d.context().min_y;
        let max_y = min_y + d.context().height - 1;
        if y < min_y + 1 || y + height + 1 > max_y {
            return false;
        }
        if !self
            .can_place_on
            .test(d, region, offset(origin, [0, -1, 0]))
        {
            return false;
        }
        for dy in 0..=height {
            let r = self.radius_at(dy);
            for dx in -r..=r {
                for dz in -r..=r {
                    let state = region.get(offset(origin, [dx, dy, dz]));
                    if !d.table.is_air(state) && !d.table.in_tag(state, &self.leaves) {
                        return false;
                    }
                }
            }
        }
        true
    }

    /// `placeMushroomBlock`: only into air or what mushrooms replace,
    /// with neighbour updates (none in a generation region).
    fn place_block(&self, d: &Decoration, region: &mut Region, pos: [i32; 3], state: u16) {
        let current = region.get(pos);
        if d.table.is_air(current) || d.table.in_tag(current, &self.replaceable) {
            region.set(pos, state, 3);
        }
    }

    fn faces(table: &BlockTable, state: u16, faces: &[(&str, bool)]) -> u16 {
        if !faces.iter().all(|(f, _)| table.has_property(state, f)) {
            return state;
        }
        faces.iter().fold(state, |s, (f, v)| {
            table
                .with(s, f, if *v { "true" } else { "false" })
                .unwrap_or(s)
        })
    }

    fn red_cap(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
        height: i32,
    ) {
        let table = d.table.as_ref();
        let fr = self.foliage_radius;
        for dy in height - 3..=height {
            let radius = if dy < height { fr } else { fr - 1 };
            let center = fr - 2;
            for dx in -radius..=radius {
                for dz in -radius..=radius {
                    let x_edge = dx == -radius || dx == radius;
                    let z_edge = dz == -radius || dz == radius;
                    if dy >= height || x_edge != z_edge {
                        let pos = offset(origin, [dx, dy, dz]);
                        let state = self.cap.state(d, region, random, origin);
                        let state = Self::faces(
                            table,
                            state,
                            &[
                                ("up", dy >= height - 1),
                                ("west", dx < -center),
                                ("east", dx > center),
                                ("north", dz < -center),
                                ("south", dz > center),
                            ],
                        );
                        self.place_block(d, region, pos, state);
                    }
                }
            }
        }
    }

    fn brown_cap(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
        height: i32,
    ) {
        let table = d.table.as_ref();
        let r = self.foliage_radius;
        for dx in -r..=r {
            for dz in -r..=r {
                let (min_x, max_x, min_z, max_z) = (dx == -r, dx == r, dz == -r, dz == r);
                let x_edge = min_x || max_x;
                let z_edge = min_z || max_z;
                if x_edge && z_edge {
                    continue;
                }
                let pos = offset(origin, [dx, height, dz]);
                let west = min_x || (z_edge && dx == 1 - r);
                let east = max_x || (z_edge && dx == r - 1);
                let north = min_z || (x_edge && dz == 1 - r);
                let south = max_z || (x_edge && dz == r - 1);
                let state = self.cap.state(d, region, random, origin);
                let state = Self::faces(
                    table,
                    state,
                    &[
                        ("west", west),
                        ("east", east),
                        ("north", north),
                        ("south", south),
                    ],
                );
                self.place_block(d, region, pos, state);
            }
        }
    }
}

/// `BambooFeature`: a stalk with leaves on top, on a podzol disc by chance.
#[derive(Debug)]
pub struct Bamboo {
    probability: f32,
    trunk: u16,
    final_large: u16,
    top_large: u16,
    top_small: u16,
    sapling_test: u16,
    podzol: u16,
    podzol_replaceable: BlockSet,
}

impl Bamboo {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<Bamboo, String> {
        let default = table.default_state("bamboo")?;
        let set =
            |s: u16, p: &str, v: &str| table.with(s, p, v).ok_or_else(|| format!("bamboo {p}"));
        let trunk = set(
            set(set(default, "age", "1")?, "leaves", "none")?,
            "stage",
            "0",
        )?;
        Ok(Bamboo {
            probability: json.field("probability")?.as_f64()? as f32,
            trunk,
            final_large: set(set(trunk, "leaves", "large")?, "stage", "1")?,
            top_large: set(trunk, "leaves", "large")?,
            top_small: set(trunk, "leaves", "small")?,
            sapling_test: default,
            podzol: table.default_state("podzol")?,
            podzol_replaceable: table
                .tag("minecraft:beneath_bamboo_podzol_replaceable")?
                .clone(),
        })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        if !region.is_air_at(origin) {
            return Ok(false);
        }
        if d.survives(region, self.sapling_test, origin) {
            let height = random.next_int_bounded(12) + 5;
            if random.next_float() < self.probability {
                let r = random.next_int_bounded(4) + 1;
                for x in origin[0] - r..=origin[0] + r {
                    for z in origin[2] - r..=origin[2] + r {
                        let (xd, zd) = (x - origin[0], z - origin[2]);
                        if xd * xd + zd * zd <= r * r {
                            let y = region.height_at(Heightmap::WorldSurface, x, z) - 1;
                            let state = region.get([x, y, z]);
                            if d.table.in_tag(state, &self.podzol_replaceable) {
                                region.set([x, y, z], self.podzol, 2);
                            }
                        }
                    }
                }
            }
            let mut pos = origin;
            let mut i = 0;
            while i < height && region.is_air_at(pos) {
                region.set(pos, self.trunk, 2);
                pos[1] += 1;
                i += 1;
            }
            if pos[1] - origin[1] >= 3 {
                region.set(pos, self.final_large, 2);
                pos[1] -= 1;
                region.set(pos, self.top_large, 2);
                pos[1] -= 1;
                region.set(pos, self.top_small, 2);
            }
        }
        Ok(true)
    }
}

/// `RootSystemFeature`: a tree on the surface above a cave, a column of
/// root blocks down to the cave's ceiling and hanging roots beneath it.
#[derive(Debug)]
pub struct RootSystem {
    tree: Arc<PlacedFeature>,
    required_space: i32,
    level_test_distance: i32,
    max_level_deviation: i32,
    root_radius: i32,
    root_replaceable: BlockSet,
    root_provider: Arc<StateProvider>,
    root_attempts: i32,
    root_column_max_height: i32,
    hanging_radius: i32,
    hanging_span: i32,
    hanging_provider: Arc<StateProvider>,
    hanging_attempts: i32,
    allowed_water: i32,
    allowed_tree_position: BlockPredicate,
}

/// `Direction.from2DDataValue`: south, west, north, east.
const BY_2D: [[i32; 3]; 4] = [[0, 0, 1], [-1, 0, 0], [0, 0, -1], [1, 0, 0]];

impl RootSystem {
    pub fn parse(
        json: &Json,
        table: &BlockTable,
        tree: Arc<PlacedFeature>,
        provider: &mut dyn FnMut(&Json) -> Result<Arc<StateProvider>, String>,
    ) -> Result<RootSystem, String> {
        let i = |k: &str| json.field(k)?.as_i32();
        Ok(RootSystem {
            tree,
            required_space: i("required_vertical_space_for_tree")?,
            level_test_distance: i("level_test_distance")?,
            max_level_deviation: i("max_level_deviation")?,
            root_radius: i("root_radius")?,
            root_replaceable: table.block_set(json.field("root_replaceable")?)?,
            root_provider: provider(json.field("root_state_provider")?)?,
            root_attempts: i("root_placement_attempts")?,
            root_column_max_height: i("root_column_max_height")?,
            hanging_radius: i("hanging_root_radius")?,
            hanging_span: i("hanging_roots_vertical_span")?,
            hanging_provider: provider(json.field("hanging_root_state_provider")?)?,
            hanging_attempts: i("hanging_root_placement_attempts")?,
            allowed_water: i("allowed_vertical_water_for_tree")?,
            allowed_tree_position: BlockPredicate::parse(
                json.field("allowed_tree_position")?,
                table,
            )?,
        })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        if !region.is_air_at(origin) {
            return Ok(false);
        }
        if self.place_dirt_and_tree(d, region, random, origin)? {
            self.place_roots(d, region, random, origin);
        }
        Ok(true)
    }

    fn water(table: &BlockTable, state: u16) -> bool {
        matches!(table.fluid(state), FLUID_WATER | FLUID_FLOWING_WATER)
    }

    fn space_for_tree(&self, d: &Decoration, region: &mut Region, pos: [i32; 3]) -> bool {
        let table = d.table.as_ref();
        for i in 1..=self.required_space {
            let state = region.get(offset(pos, [0, i, 0]));
            let allowed =
                table.is_air(state) || (i < self.allowed_water && Self::water(table, state));
            if !allowed {
                return false;
            }
        }
        if self.level_test_distance > 0 {
            for step in BY_2D {
                let n = self.level_test_distance;
                let corner = offset(pos, [step[0] * n, 0, step[2] * n]);
                let below = region.get(offset(corner, [0, -self.max_level_deviation, 0]));
                let above = region.get(offset(corner, [0, self.max_level_deviation, 0]));
                if table.is_air(below) || !table.is_air(above) {
                    return false;
                }
            }
        }
        true
    }

    fn place_dirt_and_tree(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        let mut pos = origin;
        for y in 0..self.root_column_max_height {
            pos[1] += 1;
            if region.height_at(Heightmap::WorldSurface, pos[0], pos[2]) < pos[1] {
                return Ok(false);
            }
            if self.allowed_tree_position.test(d, region, pos)
                && self.space_for_tree(d, region, pos)
            {
                let below = region.get(offset(pos, [0, -1, 0]));
                let lava = matches!(table.fluid(below), FLUID_LAVA | FLUID_FLOWING_LAVA);
                if lava || !table.flag(below, SOLID) {
                    return Ok(false);
                }
                if self.tree.place(d, region, random, pos, false)? {
                    for dirt_y in origin[1]..origin[1] + y {
                        self.place_rooted_dirt(d, region, random, [origin[0], dirt_y, origin[2]]);
                    }
                    return Ok(true);
                }
            }
        }
        Ok(false)
    }

    fn place_rooted_dirt(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        at: [i32; 3],
    ) {
        let r = self.root_radius;
        for _ in 0..self.root_attempts {
            let dx = random.next_int_bounded(r) - random.next_int_bounded(r);
            let dz = random.next_int_bounded(r) - random.next_int_bounded(r);
            let pos = offset(at, [dx, 0, dz]);
            let state = region.get(pos);
            if d.table.in_tag(state, &self.root_replaceable) {
                let root = self.root_provider.state(d, region, random, pos);
                region.set(pos, root, 2);
            }
        }
    }

    fn place_roots(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) {
        let (r, v) = (self.hanging_radius, self.hanging_span);
        for _ in 0..self.hanging_attempts {
            let dx = random.next_int_bounded(r) - random.next_int_bounded(r);
            let dy = random.next_int_bounded(v) - random.next_int_bounded(v);
            let dz = random.next_int_bounded(r) - random.next_int_bounded(r);
            let pos = offset(origin, [dx, dy, dz]);
            if !region.is_air_at(pos) {
                continue;
            }
            let state = self.hanging_provider.state(d, region, random, pos);
            if d.survives(region, state, pos) {
                let above = region.get(offset(pos, [0, 1, 0]));
                if d.table.flag(above, STURDY) {
                    region.set(pos, state, 2);
                }
            }
        }
    }
}

/// `VinesFeature`: a vine on the first face around an air block that holds
/// one.
#[derive(Debug)]
pub struct Vines {
    vine: u16,
}

impl Vines {
    pub fn new(table: &BlockTable) -> Result<Vines, String> {
        Ok(Vines {
            vine: table.default_state("vine")?,
        })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        if !region.is_air_at(origin) {
            return Ok(false);
        }
        const FACES: [(usize, [i32; 3], &str); 5] = [
            (1, [0, 1, 0], "up"),
            (2, [0, 0, -1], "north"),
            (3, [0, 0, 1], "south"),
            (4, [-1, 0, 0], "west"),
            (5, [1, 0, 0], "east"),
        ];
        for (dir, step, face) in FACES {
            let neighbour = region.get(offset(origin, step));
            if super::multiface::attaches(table, neighbour, dir) {
                let state = table.with(self.vine, face, "true").ok_or("vine face")?;
                region.set(origin, state, 2);
                return Ok(true);
            }
        }
        Ok(false)
    }
}

/// North, east, south, west.
const PLANE: [[i32; 3]; 4] = [[0, 0, -1], [1, 0, 0], [0, 0, 1], [-1, 0, 0]];

/// `Util.shuffle` of a list, in place.
pub fn shuffle<T>(list: &mut [T], random: &mut Random) {
    for i in (2..=list.len()).rev() {
        let swap = random.next_int_bounded(i as i32) as usize;
        list.swap(i - 1, swap);
    }
}

/// `CoralTreeFeature`: a trunk and branches of the coral block feature.
#[derive(Debug)]
pub struct CoralTree {
    feature: Arc<PlacedFeature>,
}

impl CoralTree {
    pub fn new(feature: Arc<PlacedFeature>) -> CoralTree {
        CoralTree { feature }
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let mut pos = origin;
        let trunk = random.next_int_bounded(3) + 1;
        for _ in 0..trunk {
            if !self.feature.place(d, region, random, pos, false)? {
                return Ok(true);
            }
            pos[1] += 1;
        }
        let top = pos;
        let branches = random.next_int_bounded(3) + 2;
        let mut directions = PLANE;
        shuffle(&mut directions, random);
        for branch in &directions[..branches as usize] {
            let mut pos = offset(top, *branch);
            let height = random.next_int_bounded(5) + 2;
            let mut segment = 0;
            let mut j = 0;
            while j < height && self.feature.place(d, region, random, pos, false)? {
                segment += 1;
                pos[1] += 1;
                if j == 0 || segment >= 2 && random.next_float() < 0.25 {
                    pos = offset(pos, *branch);
                    segment = 0;
                }
                j += 1;
            }
        }
        Ok(true)
    }
}

/// `CoralClawFeature`: a coral block with two or three claws.
#[derive(Debug)]
pub struct CoralClaw {
    feature: Arc<PlacedFeature>,
}

impl CoralClaw {
    pub fn new(feature: Arc<PlacedFeature>) -> CoralClaw {
        CoralClaw { feature }
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        if !self.feature.place(d, region, random, origin, false)? {
            return Ok(false);
        }
        // Indices into PLANE; clockwise is the next, counterclockwise the previous.
        let claw = random.next_int_bounded(4) as usize;
        let branches = random.next_int_bounded(2) + 2;
        let mut possible = [claw, (claw + 1) % 4, (claw + 3) % 4];
        shuffle(&mut possible, random);
        for &branch in &possible[..branches as usize] {
            let mut pos = offset(origin, PLANE[branch]);
            let sideways = random.next_int_bounded(2) + 1;
            let (segment, inward): ([i32; 3], i32) = if branch == claw {
                (PLANE[claw], random.next_int_bounded(3) + 2)
            } else {
                pos[1] += 1;
                let choices = [PLANE[branch], [0, 1, 0]];
                let segment = choices[random.next_int_bounded(2) as usize];
                (segment, random.next_int_bounded(3) + 3)
            };
            let mut i = 0;
            while i < sideways && self.feature.place(d, region, random, pos, false)? {
                pos = offset(pos, segment);
                i += 1;
            }
            pos = offset(pos, [-segment[0], -segment[1], -segment[2]]);
            pos[1] += 1;
            for _ in 0..inward {
                pos = offset(pos, PLANE[claw]);
                if !self.feature.place(d, region, random, pos, false)? {
                    break;
                }
                if random.next_float() < 0.25 {
                    pos[1] += 1;
                }
            }
        }
        Ok(true)
    }
}
