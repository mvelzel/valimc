//! The Nether's features (VMC-026a): deltas, stepped basalt column clusters,
//! single block pillars and projected patchy squares (basalt pillars), replace
//! blobs, random neighbour spreads (glowstone, nether wart), huge fungi and
//! scattered ores (ancient debris).

use std::sync::Arc;

use super::blocks::{BlockSet, BlockTable, REPLACEABLE};
use super::feature::Decoration;
use super::json::Json;
use super::placement::PlacedFeature;
use super::predicate::{direction, offset, BlockPredicate, RuleTest};
use super::providers::{next_int, IntProvider};
use super::random::Random;
use super::region::Region;
use super::state_provider::StateProvider;

/// `Direction.values()`: down, up, north, south, west, east.
const DIRECTIONS: [[i32; 3]; 6] = [
    [0, -1, 0],
    [0, 1, 0],
    [0, 0, -1],
    [0, 0, 1],
    [-1, 0, 0],
    [1, 0, 0],
];

/// `Vec3i.distManhattan`.
fn dist_manhattan(a: [i32; 3], b: [i32; 3]) -> i32 {
    (a[0] - b[0]).abs() + (a[1] - b[1]).abs() + (a[2] - b[2]).abs()
}

/// `BlockPos.withinBoxByManhattanDistance` (`manhattanOrdered`): positions
/// by Manhattan distance from the origin, each depth X outer, Y inner, a Z
/// offset followed by its mirror.
pub(crate) struct Manhattan {
    origin: [i32; 3],
    reach: [i32; 3],
    max_depth: i32,
    depth: i32,
    max_x: i32,
    max_y: i32,
    x: i32,
    y: i32,
    mirror: Option<[i32; 3]>,
}

impl Manhattan {
    pub(crate) fn within_box(origin: [i32; 3], rx: i32, ry: i32, rz: i32) -> Manhattan {
        Manhattan {
            origin,
            reach: [rx, ry, rz],
            max_depth: rx + ry + rz,
            depth: 0,
            max_x: 0,
            max_y: 0,
            x: 0,
            y: 0,
            mirror: None,
        }
    }
}

impl Iterator for Manhattan {
    type Item = [i32; 3];

    fn next(&mut self) -> Option<[i32; 3]> {
        if let Some(mirror) = self.mirror.take() {
            return Some(mirror);
        }
        loop {
            if self.y > self.max_y {
                self.x += 1;
                if self.x > self.max_x {
                    self.depth += 1;
                    if self.depth > self.max_depth {
                        return None;
                    }
                    self.max_x = self.reach[0].min(self.depth);
                    self.x = -self.max_x;
                }
                self.max_y = self.reach[1].min(self.depth - self.x.abs());
                self.y = -self.max_y;
            }
            let (xx, yy) = (self.x, self.y);
            let zz = self.depth - xx.abs() - yy.abs();
            self.y += 1;
            if zz <= self.reach[2] {
                let o = self.origin;
                if zz != 0 {
                    self.mirror = Some([o[0] + xx, o[1] + yy, o[2] - zz]);
                }
                return Some([o[0] + xx, o[1] + yy, o[2] + zz]);
            }
        }
    }
}

/// `DeltaFeature`: a lava (contents) patch with a magma rim, on surfaces
/// with air above and no air beside or below.
#[derive(Debug)]
pub struct Delta {
    contents: u16,
    rim: u16,
    size: IntProvider,
    rim_size: IntProvider,
    cannot_replace: BlockSet,
}

impl Delta {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<Delta, String> {
        let cannot_replace = [
            "bedrock",
            "nether_bricks",
            "nether_brick_fence",
            "nether_brick_stairs",
            "nether_wart",
            "chest",
            "spawner",
        ]
        .iter()
        .map(|b| table.block(b))
        .collect::<Result<Vec<_>, _>>()?;
        Ok(Delta {
            contents: table.state(json.field("contents")?)?,
            rim: table.state(json.field("rim")?)?,
            size: IntProvider::parse(json.field("size")?)?,
            rim_size: IntProvider::parse(json.field("rim_size")?)?,
            cannot_replace: BlockSet::from_blocks(cannot_replace),
        })
    }

    fn is_clear(&self, table: &BlockTable, region: &mut Region, pos: [i32; 3]) -> bool {
        let state = region.get(pos);
        if table.block_of(state) == table.block_of(self.contents)
            || table.in_tag(state, &self.cannot_replace)
        {
            return false;
        }
        for (d, step) in DIRECTIONS.iter().enumerate() {
            let air = region.is_air_at(offset(pos, *step));
            if air != (d == 1) {
                return false;
            }
        }
        true
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        let mut placed = false;
        let spawn_rim = random.next_double() < 0.9;
        let rim_x = if spawn_rim {
            self.rim_size.sample(random)
        } else {
            0
        };
        let rim_z = if spawn_rim {
            self.rim_size.sample(random)
        } else {
            0
        };
        let has_rim = spawn_rim && rim_x != 0 && rim_z != 0;
        let radius_x = self.size.sample(random);
        let radius_z = self.size.sample(random);
        let limit = radius_x.max(radius_z);
        for pos in Manhattan::within_box(origin, radius_x, 0, radius_z) {
            if dist_manhattan(pos, origin) > limit {
                break;
            }
            if self.is_clear(table, region, pos) {
                if has_rim {
                    placed = true;
                    region.set(pos, self.rim, 3);
                }
                let shifted = offset(pos, [rim_x, 0, rim_z]);
                if self.is_clear(table, region, shifted) {
                    placed = true;
                    region.set(shifted, self.contents, 3);
                }
            }
        }
        Ok(placed)
    }
}

/// `SteppedColumnClusterFeature`: basalt columns stepping down from the
/// cluster's centre, each a square of columns that find a surface (or the
/// air above one) and grow up through what they may replace.
#[derive(Debug)]
pub struct SteppedColumnCluster {
    block: Arc<StateProvider>,
    continue_through: BlockPredicate,
    can_replace: BlockPredicate,
    cannot_place_on: BlockSet,
    cluster_reach: IntProvider,
    column_count: IntProvider,
    column_reach: IntProvider,
    height: IntProvider,
}

impl SteppedColumnCluster {
    pub fn parse(
        json: &Json,
        table: &BlockTable,
        provider: &mut dyn FnMut(&Json) -> Result<Arc<StateProvider>, String>,
    ) -> Result<SteppedColumnCluster, String> {
        Ok(SteppedColumnCluster {
            block: provider(json.field("block")?)?,
            continue_through: BlockPredicate::parse(json.field("continue_through")?, table)?,
            can_replace: BlockPredicate::parse(json.field("can_replace")?, table)?,
            cannot_place_on: table.block_set(json.field("cannot_place_on")?)?,
            cluster_reach: IntProvider::parse(json.field("cluster_reach")?)?,
            column_count: IntProvider::parse(json.field("column_count")?)?,
            column_reach: IntProvider::parse(json.field("column_reach")?)?,
            height: IntProvider::parse(json.field("height")?)?,
        })
    }

    fn can_place_at(&self, d: &Decoration, region: &mut Region, pos: [i32; 3]) -> bool {
        if !self.can_replace.test(d, region, pos) {
            return false;
        }
        let below = region.get(offset(pos, [0, -1, 0]));
        !d.table.is_air(below) && !d.table.in_tag(below, &self.cannot_place_on)
    }

    fn find_surface(
        &self,
        d: &Decoration,
        region: &mut Region,
        mut pos: [i32; 3],
        mut limit: i32,
    ) -> Option<[i32; 3]> {
        while pos[1] > region.min_y() + 1 && limit > 0 {
            limit -= 1;
            if self.can_place_at(d, region, pos) {
                return Some(pos);
            }
            pos[1] -= 1;
        }
        None
    }

    fn find_air(
        &self,
        d: &Decoration,
        region: &mut Region,
        mut pos: [i32; 3],
        mut limit: i32,
    ) -> Option<[i32; 3]> {
        let max_y = region.min_y() + region.height() - 1;
        while pos[1] <= max_y && limit > 0 {
            limit -= 1;
            let state = region.get(pos);
            if d.table.in_tag(state, &self.cannot_place_on) {
                return None;
            }
            if d.table.is_air(state) {
                return Some(pos);
            }
            pos[1] += 1;
        }
        None
    }

    fn place_column(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
        column_height: i32,
        reach: i32,
    ) -> bool {
        let mut placed = false;
        // `BlockPos.betweenClosed`: X fastest, then Z (one layer).
        for z in origin[2] - reach..=origin[2] + reach {
            for x in origin[0] - reach..=origin[0] + reach {
                let pos = [x, origin[1], z];
                let step_limit = dist_manhattan(pos, origin);
                let column = if self.can_replace.test(d, region, pos) {
                    self.find_surface(d, region, pos, step_limit)
                } else {
                    self.find_air(d, region, pos, step_limit)
                };
                let Some(mut cursor) = column else {
                    continue;
                };
                let mut blocks = column_height - step_limit / 2;
                while blocks >= 0 {
                    if self.can_replace.test(d, region, cursor) {
                        let state = self.block.state(d, region, random, cursor);
                        region.set(cursor, state, 3);
                        placed = true;
                    } else if !self.continue_through.test(d, region, cursor) {
                        break;
                    }
                    cursor[1] += 1;
                    blocks -= 1;
                }
            }
        }
        placed
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        if !self.can_place_at(d, region, origin) {
            return Ok(false);
        }
        let column_height = self.height.sample(random);
        let reach = column_height.min(self.cluster_reach.sample(random));
        let count = self.column_count.sample(random);
        let mut placed = false;
        // `BlockPos.randomBetweenClosed` draws each position as the loop
        // asks for it.
        let width = 2 * reach + 1;
        for _ in 0..count {
            let pos = [
                origin[0] - reach + random.next_int_bounded(width),
                origin[1] + random.next_int_bounded(1),
                origin[2] - reach + random.next_int_bounded(width),
            ];
            let blocks = column_height - dist_manhattan(pos, origin);
            if blocks >= 0 {
                let column_reach = self.column_reach.sample(random);
                placed |= self.place_column(d, region, random, pos, blocks, column_reach);
            }
        }
        Ok(placed)
    }
}

/// `SingleBlockPillarFeature`: a pillar while the block may be replaced and
/// the chance holds, then its cap feature at the last block.
#[derive(Debug)]
pub struct SingleBlockPillar {
    block: Arc<StateProvider>,
    can_replace: BlockPredicate,
    step: [i32; 3],
    chance: f32,
    cap: Option<Arc<PlacedFeature>>,
}

impl SingleBlockPillar {
    pub fn parse(
        json: &Json,
        table: &BlockTable,
        provider: &mut dyn FnMut(&Json) -> Result<Arc<StateProvider>, String>,
        cap: Option<Arc<PlacedFeature>>,
    ) -> Result<SingleBlockPillar, String> {
        Ok(SingleBlockPillar {
            block: provider(json.field("block")?)?,
            can_replace: match json.get("can_replace") {
                Some(p) => BlockPredicate::parse(p, table)?,
                None => BlockPredicate::True,
            },
            step: direction(json.field("direction")?.as_str()?)?.1,
            chance: match json.get("chance_to_continue") {
                Some(c) => c.as_f64()? as f32,
                None => 1.0,
            },
            cap,
        })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let mut pos = origin;
        while self.can_replace.test(d, region, pos)
            && random.next_float() < self.chance
            && !region.is_outside_build_height(pos[1])
        {
            let state = self.block.state(d, region, random, pos);
            region.set(pos, state, 2);
            pos = offset(pos, self.step);
        }
        let last = offset(pos, self.step.map(|s| -s));
        if let Some(cap) = &self.cap {
            cap.place(d, region, random, last, false)?;
        }
        Ok(true)
    }
}

/// `ProjectedRandomPatchySquare`: a square, sparser towards its corners, each
/// block dropped through what it may project through.
#[derive(Debug)]
pub struct PatchySquare {
    block: Arc<StateProvider>,
    project_through: BlockPredicate,
    size: IntProvider,
    max_projection: i32,
}

impl PatchySquare {
    pub fn parse(
        json: &Json,
        table: &BlockTable,
        provider: &mut dyn FnMut(&Json) -> Result<Arc<StateProvider>, String>,
    ) -> Result<PatchySquare, String> {
        Ok(PatchySquare {
            block: provider(json.field("block")?)?,
            project_through: BlockPredicate::parse(json.field("project_through")?, table)?,
            size: IntProvider::parse(json.field("size")?)?,
            max_projection: json.field("max_projection_height")?.as_i32()?,
        })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let size = self.size.sample(random);
        let bound = size * size + 1;
        for dx in -size..=size {
            for dz in -size..=size {
                let probability = dx.abs() * dz.abs();
                if random.next_int_bounded(bound) >= bound - probability {
                    continue;
                }
                let mut base = offset(origin, [dx, 0, dz]);
                let mut drop = self.max_projection;
                while self
                    .project_through
                    .test(d, region, offset(base, [0, -1, 0]))
                {
                    base[1] -= 1;
                    drop -= 1;
                    if drop <= 0 {
                        break;
                    }
                }
                if let Some(state) = self.block.optional_state(d, region, random, base) {
                    region.set(base, state, 2);
                }
            }
        }
        Ok(true)
    }
}

/// `ReplaceBlobsFeature` (`netherrack_replace_blobs`): from the first target
/// block at or below the origin, the target blocks of a Manhattan blob
/// become the state.
#[derive(Debug)]
pub struct ReplaceBlobs {
    target: u16,
    state: u16,
    radius: IntProvider,
}

impl ReplaceBlobs {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<ReplaceBlobs, String> {
        Ok(ReplaceBlobs {
            target: table.block_of(table.state(json.field("target")?)?),
            state: table.state(json.field("state")?)?,
            radius: IntProvider::parse(json.field("radius")?)?,
        })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        let (min_y, max_y) = (region.min_y(), region.min_y() + region.height() - 1);
        let mut cursor = [origin[0], origin[1].clamp(min_y + 1, max_y), origin[2]];
        let centre = loop {
            if cursor[1] <= min_y + 1 {
                return Ok(false);
            }
            if table.block_of(region.get(cursor)) == self.target {
                break cursor;
            }
            cursor[1] -= 1;
        };
        let rx = self.radius.sample(random);
        let ry = self.radius.sample(random);
        let rz = self.radius.sample(random);
        let limit = rx.max(ry.max(rz));
        let mut replaced = false;
        for pos in Manhattan::within_box(centre, rx, ry, rz) {
            if dist_manhattan(pos, centre) > limit {
                break;
            }
            if table.block_of(region.get(pos)) == self.target {
                region.set(pos, self.state, 3);
                replaced = true;
            }
        }
        Ok(replaced)
    }
}

/// `RandomNeighborSpreadFeature`: the block at the origin, then at random
/// offsets where it may replace and exactly one neighbour is accepted.
#[derive(Debug)]
pub struct NeighborSpread {
    block: Arc<StateProvider>,
    accepted: BlockSet,
    can_replace: BlockPredicate,
    attempts: IntProvider,
    xz_offset: IntProvider,
    y_offset: IntProvider,
}

impl NeighborSpread {
    pub fn parse(
        json: &Json,
        table: &BlockTable,
        provider: &mut dyn FnMut(&Json) -> Result<Arc<StateProvider>, String>,
    ) -> Result<NeighborSpread, String> {
        Ok(NeighborSpread {
            block: provider(json.field("block")?)?,
            accepted: table.block_set(json.field("accepted_neighbors")?)?,
            can_replace: BlockPredicate::parse(json.field("can_replace")?, table)?,
            attempts: IntProvider::parse(json.field("attempts")?)?,
            xz_offset: IntProvider::parse(json.field("xz_offset")?)?,
            y_offset: IntProvider::parse(json.field("y_offset")?)?,
        })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let state = self.block.state(d, region, random, origin);
        region.set(origin, state, 2);
        let attempts = self.attempts.sample(random);
        for _ in 0..attempts {
            let dx = self.xz_offset.sample(random);
            let dy = self.y_offset.sample(random);
            let dz = self.xz_offset.sample(random);
            let pos = offset(origin, [dx, dy, dz]);
            if !self.can_replace.test(d, region, pos) {
                continue;
            }
            let mut neighbours = 0;
            for step in DIRECTIONS {
                if d.table
                    .in_tag(region.get(offset(pos, step)), &self.accepted)
                {
                    neighbours += 1;
                }
                if neighbours > 1 {
                    break;
                }
            }
            if neighbours == 1 {
                let state = self.block.state(d, region, random, pos);
                region.set(pos, state, 2);
            }
        }
        Ok(true)
    }
}

/// `HugeFungusFeature` as world generation places it (not planted): a stem,
/// a hat with decor blocks and, under nether wart hats, weeping vines.
#[derive(Debug)]
pub struct HugeFungus {
    valid_base: u16,
    stem: u16,
    hat: u16,
    decor: u16,
    replaceable: BlockPredicate,
    weeping_vines: u16,
    weeping_vines_plant: u16,
}

impl HugeFungus {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<HugeFungus, String> {
        if json.get("planted").is_some_and(|p| p.as_bool() == Ok(true)) {
            return Err("planted huge fungi grow from saplings, not decoration".into());
        }
        Ok(HugeFungus {
            valid_base: table.block_of(table.state(json.field("valid_base_block")?)?),
            stem: table.state(json.field("stem_state")?)?,
            hat: table.state(json.field("hat_state")?)?,
            decor: table.state(json.field("decor_state")?)?,
            replaceable: BlockPredicate::parse(json.field("replaceable_blocks")?, table)?,
            weeping_vines: table.default_state("weeping_vines")?,
            weeping_vines_plant: table.default_state("weeping_vines_plant")?,
        })
    }

    fn is_replaceable(
        &self,
        d: &Decoration,
        region: &mut Region,
        pos: [i32; 3],
        plants: bool,
    ) -> bool {
        if d.table.flag(region.get(pos), REPLACEABLE) {
            return true;
        }
        plants && self.replaceable.test(d, region, pos)
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        if table.block_of(region.get(offset(origin, [0, -1, 0]))) != self.valid_base {
            return Ok(false);
        }
        let mut height = next_int(random, 4, 13);
        if random.next_int_bounded(12) == 0 {
            height *= 2;
        }
        // The generator's depth (`getGenDepth`).
        if origin[1] + height + 1 >= d.context().height {
            return Ok(false);
        }
        let huge = random.next_float() < 0.06;
        region.set(origin, region.air, 260);
        self.place_stem(d, region, random, origin, height, huge);
        self.place_hat(d, region, random, origin, height, huge)?;
        Ok(true)
    }

    fn place_stem(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
        height: i32,
        huge: bool,
    ) {
        let radius = i32::from(huge);
        for dx in -radius..=radius {
            for dz in -radius..=radius {
                let corner = huge && dx.abs() == radius && dz.abs() == radius;
                for dy in 0..height {
                    let pos = offset(origin, [dx, dy, dz]);
                    if !self.is_replaceable(d, region, pos, true) {
                        continue;
                    }
                    if !corner || random.next_float() < 0.1 {
                        region.set(pos, self.stem, 3);
                    }
                }
            }
        }
    }

    fn place_hat(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
        height: i32,
        huge: bool,
    ) -> Result<(), String> {
        let table = d.table.as_ref();
        let vines = table.block_of(self.hat) == table.block("nether_wart_block")?;
        let hat_height = (random.next_int_bounded(1 + height / 3) + 5).min(height);
        let hat_start = height - hat_height;
        for dy in hat_start..=height {
            let mut radius = if dy < height - random.next_int_bounded(3) {
                2
            } else {
                1
            };
            if hat_height > 8 && dy < hat_start + 4 {
                radius = 3;
            }
            if huge {
                radius += 1;
            }
            for dx in -radius..=radius {
                for dz in -radius..=radius {
                    let edge_x = dx == -radius || dx == radius;
                    let edge_z = dz == -radius || dz == radius;
                    let inside = !edge_x && !edge_z && dy != height;
                    let corner = edge_x && edge_z;
                    let bottom = dy < hat_start + 3;
                    let pos = offset(origin, [dx, dy, dz]);
                    if !self.is_replaceable(d, region, pos, false) {
                        continue;
                    }
                    let vine = |p: f32| if vines { p } else { 0.0 };
                    if bottom {
                        if !inside {
                            self.place_drop_block(d, region, random, pos, vines);
                        }
                    } else if inside {
                        self.place_hat_block(region, random, pos, 0.1, 0.2, vine(0.1));
                    } else if corner {
                        self.place_hat_block(region, random, pos, 0.01, 0.7, vine(0.083));
                    } else {
                        self.place_hat_block(region, random, pos, 5.0e-4, 0.98, vine(0.07));
                    }
                }
            }
        }
        Ok(())
    }

    fn place_hat_block(
        &self,
        region: &mut Region,
        random: &mut Random,
        pos: [i32; 3],
        decor: f32,
        hat: f32,
        vines: f32,
    ) {
        if random.next_float() < decor {
            region.set(pos, self.decor, 3);
        } else if random.next_float() < hat {
            region.set(pos, self.hat, 3);
            if random.next_float() < vines {
                self.weeping_vines(region, random, pos);
            }
        }
    }

    fn place_drop_block(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        pos: [i32; 3],
        vines: bool,
    ) {
        let table = d.table.as_ref();
        if table.block_of(region.get(offset(pos, [0, -1, 0]))) == table.block_of(self.hat) {
            region.set(pos, self.hat, 3);
        } else if (random.next_float() as f64) < 0.15 {
            region.set(pos, self.hat, 3);
            if vines && random.next_int_bounded(11) == 0 {
                self.weeping_vines(region, random, pos);
            }
        }
    }

    /// `tryPlaceWeepingVines` under a hat block.
    fn weeping_vines(&self, region: &mut Region, random: &mut Random, hat: [i32; 3]) {
        let mut pos = offset(hat, [0, -1, 0]);
        if !region.is_air_at(pos) {
            return;
        }
        let mut goal = next_int(random, 1, 5);
        if random.next_int_bounded(7) == 0 {
            goal *= 2;
        }
        for height in 0..=goal {
            if region.is_air_at(pos) {
                if height == goal || !region.is_air_at(offset(pos, [0, -1, 0])) {
                    let age = next_int(random, 23, 25);
                    let tip = region
                        .table
                        .with(self.weeping_vines, "age", &age.to_string())
                        .unwrap_or(self.weeping_vines);
                    region.set(pos, tip, 2);
                    break;
                }
                region.set(pos, self.weeping_vines_plant, 2);
            }
            pos[1] -= 1;
        }
    }
}

/// `ScatteredOreFeature`: up to `size` single blocks around the origin,
/// spreading out with each try.
#[derive(Debug)]
pub struct ScatteredOre {
    targets: Vec<(RuleTest, u16)>,
    size: i32,
    discard_on_air: f32,
}

impl ScatteredOre {
    pub fn new(targets: Vec<(RuleTest, u16)>, size: i32, discard_on_air: f32) -> ScatteredOre {
        ScatteredOre {
            targets,
            size,
            discard_on_air,
        }
    }

    /// `getRandomPlacementInOneAxisRelativeToOrigin`: `Math.round` of a float.
    fn axis(random: &mut Random, max: i32) -> i32 {
        let value = (random.next_float() - random.next_float()) * max as f32;
        (value as f64 + 0.5).floor() as i32
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        let tries = random.next_int_bounded(self.size + 1);
        for i in 0..tries {
            let max = i.min(7);
            let dx = Self::axis(random, max);
            let dy = Self::axis(random, max);
            let dz = Self::axis(random, max);
            let pos = offset(origin, [dx, dy, dz]);
            let state = region.get(pos);
            for (target, ore) in &self.targets {
                if !target.test(table, state, pos, random) {
                    continue;
                }
                let skip_air_check = if self.discard_on_air <= 0.0 {
                    true
                } else if self.discard_on_air >= 1.0 {
                    false
                } else {
                    random.next_float() >= self.discard_on_air
                };
                let exposed = !skip_air_check
                    && DIRECTIONS
                        .iter()
                        .any(|step| region.is_air_at(offset(pos, *step)));
                if !exposed {
                    region.set(pos, *ore, 2);
                    break;
                }
            }
        }
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manhattan_order_matches_vanilla() {
        // Depth 0, then depth 1 with X outer, Y inner and each Z mirrored.
        let positions: Vec<_> = Manhattan::within_box([0, 0, 0], 1, 1, 1).take(7).collect();
        assert_eq!(
            positions,
            vec![
                [0, 0, 0],
                [-1, 0, 0],
                [0, -1, 0],
                [0, 0, 1],
                [0, 0, -1],
                [0, 1, 0],
                [1, 0, 0]
            ]
        );
        // Every position of the box exactly once.
        let all: Vec<_> = Manhattan::within_box([5, 6, 7], 2, 0, 3).collect();
        assert_eq!(all.len(), 5 * 7);
        let set: std::collections::HashSet<_> = all.iter().collect();
        assert_eq!(set.len(), all.len());
    }
}
