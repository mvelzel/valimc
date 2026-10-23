//! The rest of what random ticks and bone meal grow on a survival farm
//! (VMC-039b), on `growth`'s kinds and plans: grass blocks and mycelium
//! spreading and dying (`SpreadingSnowyBlock`), nylium dying, torchflowers
//! (as crops), pitcher crops, nether wart, cocoa, sweet berries, kelp and the
//! vines (`GrowingPlantHeadBlock`), and bone meal on those, on short grass and
//! ferns, tall flowers, flower beds, seagrass, bushes and dry grass, sea
//! pickles, mangrove leaves, rooted dirt, azaleas (their tree, as a
//! sapling's) and on water (`BoneMealItem.growWaterPlant`). Bone meal on a
//! grass block, nylium, moss and mushrooms places features: it answers
//! `GROW_TREE` and the owner places them through the generator as a
//! sapling's tree (`Growth::generated`), with the generator's own draws.

use super::growth::{int, offset, with_int, Kind, Plan, Plant, BONE_MEAL_USED, HORIZONTAL};
use super::growth::{HORIZONTAL_NAMES, PASS, USED};
use super::updater::{Engine, World, ALL, CLIENTS};
use crate::column::{HEIGHT, MIN_Y};
use crate::worldgen::blocks::{
    BlockTable, FLUID_EMPTY, FLUID_FLOWING_WATER, FLUID_WATER, FULL_COLLISION, STURDY,
};

/// `Level.isInsideBuildHeight` of a block at `y`.
fn inside(y: i32) -> bool {
    (MIN_Y..MIN_Y + HEIGHT as i32).contains(&y)
}

fn with(table: &BlockTable, state: u16, property: &str, value: &str) -> u16 {
    table.with(state, property, value).unwrap_or(state)
}

/// The face properties of a multiface block, in `STEP` order.
const FACES: [&str; 6] = ["down", "up", "north", "south", "west", "east"];

/// `MultifaceBlock.hasFace`.
fn has_face(table: &BlockTable, state: u16, face: usize) -> bool {
    table.value(state, FACES[face]) == Some("true")
}

/// A big dripleaf or its stem (`block`'s default state) facing `facing`,
/// waterlogged when the cell held a water source.
fn dripleaf(table: &BlockTable, block: u16, facing: &str, wet: bool) -> u16 {
    let state = with(table, block, "facing", facing);
    with(
        table,
        state,
        "waterlogged",
        if wet { "true" } else { "false" },
    )
}

impl super::growth::Growth {
    /// `BambooSaplingBlock.growBamboo`'s stalk: bamboo with small leaves.
    fn bamboo_shoot(&self, table: &BlockTable) -> u16 {
        with(
            table,
            table.default_state_of(self.bamboo),
            "leaves",
            "small",
        )
    }
}

fn is_water(table: &BlockTable, state: u16) -> bool {
    let fluid = table.fluid(state);
    fluid == FLUID_WATER || fluid == FLUID_FLOWING_WATER
}

impl Plant {
    fn step(&self) -> i32 {
        if self.up {
            1
        } else {
            -1
        }
    }

    /// `canGrowInto`: water (the block, at any level) for kelp, air for the
    /// vines.
    fn grows_into(&self, table: &BlockTable, water: u16, state: u16) -> bool {
        if self.water {
            table.block_of(state) == water
        } else {
            table.is_air(state)
        }
    }
}

impl<W: World> Engine<'_, W> {
    /// The random tick of the kinds `growth` leaves here.
    pub(super) fn plant_tick(&mut self, kind: Kind, pos: [i32; 3], state: u16) -> Plan {
        let rules = self.rules;
        let table = rules.table.as_ref();
        let growth = rules.growth.as_ref().expect("growth facts");
        let above = offset(pos, 0, 1, 0);
        match kind {
            Kind::Spreading => {
                if growth.smothers_grass[self.world.get(above) as usize] {
                    return Plan::set(pos, growth.dirt, ALL);
                }
                if self.raw_brightness(above, self.redstone.sky_darken) < 9 {
                    return Plan::default();
                }
                let grass = table.default_state_of(table.block_of(state));
                let mut plan = Plan::default();
                for _ in 0..4 {
                    let dx = self.world.next_int(3) - 1;
                    let dy = self.world.next_int(5) - 3;
                    let dz = self.world.next_int(3) - 1;
                    let target = offset(pos, dx, dy, dz);
                    if table.block_of(plan.get(&mut self.world, target)) != growth.dirt_block {
                        continue;
                    }
                    // `canPropagate`: alive there and no water above.
                    let top = plan.get(&mut self.world, offset(target, 0, 1, 0));
                    if growth.smothers_grass[top as usize] || is_water(table, top) {
                        continue;
                    }
                    let snowy = growth.snow.contains(table.block_of(top));
                    let spread = with(table, grass, "snowy", if snowy { "true" } else { "false" });
                    plan.writes.push((target, spread, ALL));
                }
                plan
            }
            Kind::Nylium if growth.smothers_nylium[self.world.get(above) as usize] => {
                Plan::set(pos, growth.netherrack, ALL)
            }
            // Only the lower half ticks.
            Kind::Pitcher if table.value(state, "half") == Some("lower") => {
                let speed = self.growth_speed(state, pos);
                if self.world.next_int((25.0f32 / speed) as i32 + 1) == 0 {
                    self.grow_pitcher(pos, state)
                } else {
                    Plan::default()
                }
            }
            Kind::NetherWart => {
                let age = int(table, state, "age");
                if age < 3 && self.world.next_int(10) == 0 {
                    return Plan::set(pos, with_int(table, state, "age", age + 1), CLIENTS);
                }
                Plan::default()
            }
            Kind::Cocoa => {
                let age = int(table, state, "age");
                if self.world.next_int(5) == 0 && age < 2 {
                    return Plan::set(pos, with_int(table, state, "age", age + 1), CLIENTS);
                }
                Plan::default()
            }
            Kind::SweetBerries => {
                let age = int(table, state, "age");
                if age < 3 && self.world.next_int(5) == 0 && self.raw_brightness(above, 0) >= 9 {
                    return Plan::set(pos, with_int(table, state, "age", age + 1), CLIENTS);
                }
                Plan::default()
            }
            Kind::Head(index) => {
                let plant = growth.plants[index];
                let age = int(table, state, "age");
                if age >= 25 || self.world.next_double() >= plant.chance {
                    return Plan::default();
                }
                let target = offset(pos, 0, plant.step(), 0);
                if !plant.grows_into(table, growth.water, self.world.get(target)) {
                    return Plan::default();
                }
                let mut grown = with_int(table, state, "age", age + 1);
                if plant.berries {
                    let berries = self.world.next_float() < 0.11;
                    grown = with(
                        table,
                        grown,
                        "berries",
                        if berries { "true" } else { "false" },
                    );
                }
                Plan::set(target, grown, ALL)
            }
            Kind::BambooSapling | Kind::Bamboo => {
                let sapling = kind == Kind::BambooSapling;
                if !sapling && int(table, state, "stage") != 0 {
                    return Plan::default();
                }
                if self.world.next_int(3) != 0
                    || !table.is_air(self.world.get(above))
                    || self.raw_brightness(above, 0) < 9
                {
                    return Plan::default();
                }
                if sapling {
                    return Plan::set(above, growth.bamboo_shoot(table), ALL);
                }
                let height = self.bamboo_below(pos) + 1;
                let mut plan = Plan::default();
                if height < 16 {
                    self.grow_bamboo(&mut plan, pos, state, height);
                }
                plan
            }
            _ => Plan::default(),
        }
    }

    /// `getHeightBelowUpToMax`: the bamboo under `pos`, at most 16.
    fn bamboo_below(&mut self, pos: [i32; 3]) -> i32 {
        self.bamboo_run(pos, -1)
    }

    /// The bamboo in a row from `pos` toward `step` (not counting `pos`), at
    /// most 16 (`getHeightAboveUpToMax`, `getHeightBelowUpToMax`).
    fn bamboo_run(&mut self, pos: [i32; 3], step: i32) -> i32 {
        let rules = self.rules;
        let bamboo = rules.growth.as_ref().expect("growth facts").bamboo;
        let mut height = 0;
        while height < 16
            && rules
                .table
                .block_of(self.world.get(offset(pos, 0, step * (height + 1), 0)))
                == bamboo
        {
            height += 1;
        }
        height
    }

    /// `BambooStalkBlock.growBamboo` from the top stalk `pos` (`state`) of a
    /// stalk `height` tall: its leaves move up, and the new stalk above it.
    /// A thicker stalk's shape update thickens the stalk below it (`updateShape`
    /// cycles its age), which the plan's reads see.
    fn grow_bamboo(&mut self, plan: &mut Plan, pos: [i32; 3], state: u16, height: i32) {
        let rules = self.rules;
        let table = rules.table.as_ref();
        let bamboo = rules.growth.as_ref().expect("growth facts").bamboo;
        let below_pos = offset(pos, 0, -1, 0);
        let two_below_pos = offset(pos, 0, -2, 0);
        let below = plan.get(&mut self.world, below_pos);
        let two_below = plan.get(&mut self.world, two_below_pos);
        let is_bamboo = |s: u16| table.block_of(s) == bamboo;
        let mut leaves = "none";
        if height >= 1 {
            if !is_bamboo(below) || table.value(below, "leaves") == Some("none") {
                leaves = "small";
            } else {
                leaves = "large";
                if is_bamboo(two_below) {
                    plan.writes
                        .push((below_pos, with(table, below, "leaves", "small"), ALL));
                    plan.writes.push((
                        two_below_pos,
                        with(table, two_below, "leaves", "none"),
                        ALL,
                    ));
                }
            }
        }
        let age = i32::from(int(table, state, "age") == 1 || is_bamboo(two_below));
        let stage = if (height < 11 || self.world.next_float() >= 0.25) && height != 15 {
            0
        } else {
            1
        };
        let grown = table.default_state_of(bamboo);
        let grown = with_int(table, with(table, grown, "leaves", leaves), "age", age);
        let above = offset(pos, 0, 1, 0);
        plan.writes
            .push((above, with_int(table, grown, "stage", stage), ALL));
        // `updateShape` from above: each thinner stalk below thickens.
        let mut cell = pos;
        loop {
            let here = plan.get(&mut self.world, cell);
            if !is_bamboo(here) || int(table, here, "age") >= age {
                break;
            }
            plan.writes
                .push((cell, with_int(table, here, "age", age), ALL));
            cell = offset(cell, 0, -1, 0);
        }
    }

    /// `PitcherCropBlock.grow` by one from its lower half.
    fn grow_pitcher(&mut self, pos: [i32; 3], lower: u16) -> Plan {
        let table = self.rules.table.as_ref();
        let updated = (int(table, lower, "age") + 1).min(4);
        if !self.pitcher_can_grow(pos, lower, updated) {
            return Plan::default();
        }
        let grown = with_int(table, lower, "age", updated);
        let mut plan = Plan::set(pos, grown, CLIENTS);
        if updated >= 3 {
            let upper = with(table, grown, "half", "upper");
            plan.writes.push((offset(pos, 0, 1, 0), upper, ALL));
        }
        plan
    }

    /// `PitcherCropBlock.canGrow`.
    fn pitcher_can_grow(&mut self, pos: [i32; 3], lower: u16, age: i32) -> bool {
        let rules = self.rules;
        let table = rules.table.as_ref();
        let pitcher = rules.growth.as_ref().expect("growth facts").pitcher;
        int(table, lower, "age") < 4
            && self.raw_brightness(pos, 0) >= 8
            && inside(pos[1] + 1)
            && (age < 3 || {
                let above = self.world.get(offset(pos, 0, 1, 0));
                table.is_air(above) || table.block_of(above) == pitcher
            })
    }

    /// Bone meal on the kinds `growth` leaves here: `None` when the block
    /// is not a target.
    pub(super) fn plant_bone_meal(
        &mut self,
        kind: Kind,
        pos: [i32; 3],
        state: u16,
    ) -> Option<Plan> {
        let rules = self.rules;
        let table = rules.table.as_ref();
        let growth = rules.growth.as_ref().expect("growth facts");
        let above = offset(pos, 0, 1, 0);
        let below = offset(pos, 0, -1, 0);
        match kind {
            Kind::Azalea(grower) => {
                let min_height = growth.growers[grower].1.min_height;
                if !inside(pos[1] + min_height + 2)
                    || table.fluid(self.world.get(above)) != FLUID_EMPTY
                {
                    return None;
                }
                Some(if self.world.next_float() < 0.45 {
                    Plan::grow()
                } else {
                    Plan::default()
                })
            }
            Kind::Pitcher => {
                let (pos, lower) = if table.value(state, "half") == Some("lower") {
                    (pos, state)
                } else {
                    let lower = self.world.get(below);
                    if table.block_of(lower) != growth.pitcher
                        || table.value(lower, "half") != Some("lower")
                    {
                        return None;
                    }
                    (below, lower)
                };
                let age = int(table, lower, "age") + 1;
                if !self.pitcher_can_grow(pos, lower, age) {
                    return None;
                }
                Some(self.grow_pitcher(pos, lower))
            }
            Kind::Cocoa => {
                let age = int(table, state, "age");
                (age < 2).then(|| Plan::set(pos, with_int(table, state, "age", age + 1), CLIENTS))
            }
            Kind::SweetBerries => {
                let age = int(table, state, "age");
                (age < 3).then(|| Plan::set(pos, with_int(table, state, "age", age + 1), CLIENTS))
            }
            Kind::Head(index) | Kind::Body(index) if growth.plants[index].berries => {
                // Cave vines: berries.
                (table.value(state, "berries") == Some("false"))
                    .then(|| Plan::set(pos, with(table, state, "berries", "true"), CLIENTS))
            }
            Kind::Head(index) => self.grow_plant(growth.plants[index], pos, state),
            Kind::Body(index) => {
                // `BlockUtil.getTopConnectedBlock`: the head past the body.
                let plant = growth.plants[index];
                let mut head = pos;
                let mut head_state;
                loop {
                    head = offset(head, 0, plant.step(), 0);
                    head_state = self.world.get(head);
                    if table.block_of(head_state) != plant.body {
                        break;
                    }
                }
                if table.block_of(head_state) != plant.head {
                    return None;
                }
                self.grow_plant(plant, head, head_state)
            }
            Kind::Small(grown) => {
                let fits = rules.live_survives(&mut self.world, grown, pos)
                    && table.is_air(self.world.get(above))
                    && inside(above[1]);
                fits.then(|| Plan {
                    writes: vec![
                        (pos, grown, CLIENTS),
                        (above, with(table, grown, "half", "upper"), CLIENTS),
                    ],
                    ..Plan::default()
                })
            }
            Kind::TallFlower => Some(self.pop()),
            Kind::FlowerBed => {
                let amount = int(table, state, "flower_amount");
                Some(if amount < 4 {
                    Plan::set(
                        pos,
                        with_int(table, state, "flower_amount", amount + 1),
                        CLIENTS,
                    )
                } else {
                    self.pop()
                })
            }
            Kind::Seagrass => {
                (table.block_of(self.world.get(above)) == growth.water).then(|| Plan {
                    writes: vec![
                        (pos, growth.tall_seagrass, CLIENTS),
                        (
                            above,
                            with(table, growth.tall_seagrass, "half", "upper"),
                            CLIENTS,
                        ),
                    ],
                    ..Plan::default()
                })
            }
            Kind::Spreader(place) => {
                // `hasSpreadableNeighbourPos` in the plane's order, then
                // `findSpreadableNeighbourPos` in a shuffled one.
                let spreads = |e: &mut Self, d: usize| {
                    let cell = super::at(pos, d);
                    table.is_air(e.world.get(cell))
                        && rules.live_survives(&mut e.world, place, cell)
                };
                if !HORIZONTAL.iter().any(|&d| spreads(self, d)) {
                    return None;
                }
                let mut order = HORIZONTAL;
                for i in (2..=4).rev() {
                    let swap = self.world.next_int(i as i32) as usize;
                    order.swap(i - 1, swap);
                }
                Some(match order.into_iter().find(|&d| spreads(self, d)) {
                    Some(d) => Plan::set(super::at(pos, d), place, ALL),
                    None => Plan::default(),
                })
            }
            Kind::ShortDryGrass => Some(Plan::set(pos, growth.tall_dry_grass, ALL)),
            Kind::SeaPickle => {
                let alive = table.value(state, "waterlogged") == Some("true");
                if !alive
                    || !growth
                        .coral_blocks
                        .contains(table.block_of(self.world.get(below)))
                {
                    return None;
                }
                Some(self.spread_pickles(pos, state))
            }
            Kind::MangroveLeaves => table
                .is_air(self.world.get(below))
                .then(|| Plan::set(below, growth.hanging_propagule, CLIENTS)),
            Kind::RootedDirt => (table.is_air(self.world.get(below)) && inside(below[1]))
                .then(|| Plan::set(below, growth.hanging_roots, ALL)),
            // The generator places what these grow, with its own draws.
            Kind::Spreading if table.block_of(state) != growth.grass_block => None,
            Kind::Spreading | Kind::Nylium => {
                (table.is_air(self.world.get(above)) && inside(above[1])).then(Plan::grow)
            }
            Kind::Placer(_) => table.is_air(self.world.get(above)).then(Plan::grow),
            Kind::Mushroom(index) => {
                if !inside(pos[1] + growth.mushrooms[index].1) {
                    return None;
                }
                Some(if self.world.next_float() < 0.4 {
                    Plan::grow()
                } else {
                    Plan::default()
                })
            }
            Kind::Fungus(index) => {
                let base = growth.fungi[index].1;
                if table.block_of(self.world.get(below)) != base || !inside(above[1]) {
                    return None;
                }
                Some(if self.world.next_float() < 0.4 {
                    Plan::grow()
                } else {
                    Plan::default()
                })
            }
            Kind::BambooSapling => (table.is_air(self.world.get(above)) && inside(above[1]))
                .then(|| Plan::set(above, growth.bamboo_shoot(table), ALL)),
            Kind::Bamboo => self.bamboo_bone_meal(pos),
            Kind::Lichen => self.spread_lichen(pos, state),
            Kind::SmallDripleaf => {
                let (pos, lower) = if table.value(state, "half") == Some("lower") {
                    (pos, state)
                } else {
                    let lower = self.world.get(below);
                    if table.block_of(lower) != growth.small_dripleaf
                        || table.value(lower, "half") != Some("lower")
                    {
                        // Vanilla's recursion fails on anything else.
                        return Some(Plan::default());
                    }
                    (below, lower)
                };
                Some(self.grow_small_dripleaf(pos, lower))
            }
            Kind::BigDripleaf => {
                if !self.dripleaf_grows_into(above) {
                    return None;
                }
                let facing = table.value(state, "facing").unwrap_or("north");
                let wet = table.fluid(state) == FLUID_WATER;
                let leaf_wet = table.fluid(self.world.get(above)) == FLUID_WATER;
                Some(Plan {
                    writes: vec![
                        (pos, dripleaf(table, growth.dripleaf_stem, facing, wet), ALL),
                        (
                            above,
                            dripleaf(table, growth.big_dripleaf, facing, leaf_wet),
                            ALL,
                        ),
                    ],
                    ..Plan::default()
                })
            }
            Kind::DripleafStem => {
                // `BlockUtil.getTopConnectedBlock`: the leaf over the stem.
                let mut head = pos;
                let mut head_state;
                loop {
                    head = offset(head, 0, 1, 0);
                    head_state = self.world.get(head);
                    if table.block_of(head_state) != table.block_of(growth.dripleaf_stem) {
                        break;
                    }
                }
                let top = offset(head, 0, 1, 0);
                if table.block_of(head_state) != table.block_of(growth.big_dripleaf)
                    || !self.dripleaf_grows_into(top)
                {
                    return None;
                }
                // The clicked stem's facing.
                let facing = table.value(state, "facing").unwrap_or("north");
                let wet = table.fluid(head_state) == FLUID_WATER;
                let top_wet = table.fluid(self.world.get(top)) == FLUID_WATER;
                Some(Plan {
                    writes: vec![
                        (
                            head,
                            dripleaf(table, growth.dripleaf_stem, facing, wet),
                            ALL,
                        ),
                        (
                            top,
                            dripleaf(table, growth.big_dripleaf, facing, top_wet),
                            ALL,
                        ),
                    ],
                    ..Plan::default()
                })
            }
            Kind::Netherrack => {
                if !growth.skylight[self.world.get(above) as usize] {
                    return None;
                }
                // `findBlocksIn` the 3 × 3 × 3 about it (the `nylium` tag);
                // the order only decides when the scan stops.
                let (mut crimson, mut warped) = (false, false);
                for dz in -1..=1 {
                    for dy in -1..=1 {
                        for dx in -1..=1 {
                            let block = table.block_of(self.world.get(offset(pos, dx, dy, dz)));
                            if growth.nylium.contains(block) {
                                warped |= block == table.block_of(growth.warped_nylium);
                                crimson |= block == table.block_of(growth.crimson_nylium);
                            }
                        }
                    }
                }
                if !crimson && !warped {
                    return None;
                }
                let grown = match (crimson, warped) {
                    (true, true) => {
                        if self.world.next_int(2) == 1 {
                            growth.warped_nylium
                        } else {
                            growth.crimson_nylium
                        }
                    }
                    (false, true) => growth.warped_nylium,
                    _ => growth.crimson_nylium,
                };
                Some(Plan::set(pos, grown, ALL))
            }
            Kind::HangingMoss => {
                // `getTip`: the last moss below it, and the cell under that.
                let block = table.block_of(state);
                let mut cell = below;
                while table.block_of(self.world.get(cell)) == block {
                    cell = offset(cell, 0, -1, 0);
                }
                (table.is_air(self.world.get(cell)) && inside(cell[1]))
                    .then(|| Plan::set(cell, with(table, state, "tip", "true"), ALL))
            }
            Kind::MossCarpet => {
                if table.value(state, "bottom") != Some("true") {
                    return None;
                }
                let carpet = crate::worldgen::multiface::MossyCarpet::new(table).ok()?;
                let topper = carpet.grown(&mut |p| self.world.get(p), pos)?;
                Some(Plan::set(above, topper, ALL))
            }
            _ => None,
        }
    }

    /// `BambooStalkBlock` bone meal at `pos`: one or two stalks more on the
    /// top of its stalk, while it is shorter than 16 and still growing.
    fn bamboo_bone_meal(&mut self, pos: [i32; 3]) -> Option<Plan> {
        let table = self.rules.table.as_ref();
        let height_above = self.bamboo_run(pos, 1);
        let height_below = self.bamboo_below(pos);
        let total = height_above + height_below + 1;
        let top = offset(pos, 0, height_above, 0);
        let growth_pos = offset(top, 0, 1, 0);
        if total >= 16
            || int(table, self.world.get(top), "stage") == 1
            || !inside(growth_pos[1])
            || !table.is_air(self.world.get(growth_pos))
        {
            return None;
        }
        let mut plan = Plan::default();
        let count = 1 + self.world.next_int(2);
        for grown in 0..count {
            let top = offset(pos, 0, height_above + grown, 0);
            let top_state = plan.get(&mut self.world, top);
            let growth_pos = offset(top, 0, 1, 0);
            if total + grown >= 16
                || int(table, top_state, "stage") == 1
                || !table.is_air(plan.get(&mut self.world, growth_pos))
                || !inside(growth_pos[1])
            {
                break;
            }
            self.grow_bamboo(&mut plan, top, top_state, total + grown);
        }
        Some(plan)
    }

    /// `BigDripleafBlock.canGrowInto`: inside the build height, air, water or
    /// a small dripleaf.
    fn dripleaf_grows_into(&mut self, pos: [i32; 3]) -> bool {
        let rules = self.rules;
        let table = rules.table.as_ref();
        let growth = rules.growth.as_ref().expect("growth facts");
        let state = self.world.get(pos);
        inside(pos[1])
            && (table.is_air(state)
                || table.block_of(state) == growth.water
                || table.block_of(state) == growth.small_dripleaf)
    }

    /// `SmallDripleafBlock.performBonemeal` on its lower half `pos`: the upper
    /// half gives way to its fluid, and a big dripleaf two to five tall grows
    /// in its place (`BigDripleafBlock.placeWithRandomHeight`).
    fn grow_small_dripleaf(&mut self, pos: [i32; 3], lower: u16) -> Plan {
        let rules = self.rules;
        let table = rules.table.as_ref();
        let growth = rules.growth.as_ref().expect("growth facts");
        let above = offset(pos, 0, 1, 0);
        let upper = self.world.get(above);
        // `UPDATE_CLIENTS | UPDATE_KNOWN_SHAPE`.
        let mut plan = Plan::set(above, table.remains[upper as usize], CLIENTS | 16);
        let facing = table.value(lower, "facing").unwrap_or("north");
        let desired = self.world.next_int(4) + 2;
        let mut height = 0;
        while height < desired {
            let cell = offset(pos, 0, height, 0);
            let state = plan.get(&mut self.world, cell);
            let fits = inside(cell[1])
                && (table.is_air(state)
                    || table.block_of(state) == growth.water
                    || table.block_of(state) == growth.small_dripleaf);
            if !fits {
                break;
            }
            height += 1;
        }
        for dy in 0..height {
            let cell = offset(pos, 0, dy, 0);
            let wet = table.fluid(plan.get(&mut self.world, cell)) == FLUID_WATER;
            let block = if dy + 1 < height {
                growth.dripleaf_stem
            } else {
                growth.big_dripleaf
            };
            plan.writes
                .push((cell, dripleaf(table, block, facing, wet), ALL));
        }
        plan
    }

    /// `MultifaceSpreader.spreadFromRandomFaceTowardRandomDirection` of the
    /// glow lichen at `pos`: `None` when it can spread nowhere
    /// (`isValidBonemealTarget`).
    fn spread_lichen(&mut self, pos: [i32; 3], state: u16) -> Option<Plan> {
        let valid = (0..6).any(|face| {
            (0..6).any(|spread| self.lichen_spread(pos, state, face ^ 1, spread).is_some())
        });
        if !valid {
            return None;
        }
        let table = self.rules.table.as_ref();
        let faces = self.shuffled_directions();
        for face in faces {
            if !has_face(table, state, face) {
                continue;
            }
            // Each face shuffles the spread directions anew, lazily.
            for spread in self.shuffled_directions() {
                let Some((cell, to)) = self.lichen_spread(pos, state, face, spread) else {
                    continue;
                };
                // `placeBlock`: `getStateForPlacement` on what is there now.
                let old = self.world.get(cell);
                if let Some(placed) = self.lichen_placement(old, cell, to) {
                    return Some(Plan::set(cell, placed, CLIENTS));
                }
            }
        }
        Some(Plan::default())
    }

    /// `Direction.allShuffled`.
    fn shuffled_directions(&mut self) -> [usize; 6] {
        let mut order = [0, 1, 2, 3, 4, 5];
        for i in (2..=6).rev() {
            let swap = self.world.next_int(i as i32) as usize;
            order.swap(i - 1, swap);
        }
        order
    }

    /// `getSpreadFromFaceTowardDirection` with `canSpreadInto`: where the
    /// lichen's face `from` spreads toward `spread`, as a cell and the face
    /// it gains there.
    fn lichen_spread(
        &mut self,
        pos: [i32; 3],
        state: u16,
        from: usize,
        spread: usize,
    ) -> Option<([i32; 3], usize)> {
        let rules = self.rules;
        let table = rules.table.as_ref();
        let water = rules.growth.as_ref().expect("growth facts").water;
        if spread / 2 == from / 2 || !has_face(table, state, from) || has_face(table, state, spread)
        {
            return None;
        }
        let beside = super::at(pos, spread);
        // Same position, same plane, wrapped around.
        for (cell, face) in [
            (pos, spread),
            (beside, from),
            (super::at(beside, from), spread ^ 1),
        ] {
            let existing = self.world.get(cell);
            let replaceable = table.is_air(existing)
                || table.block_of(existing) == table.block_of(state)
                || (table.block_of(existing) == water && table.fluid(existing) == FLUID_WATER);
            if replaceable && self.lichen_valid(existing, cell, face, table.block_of(state)) {
                return Some((cell, face));
            }
        }
        None
    }

    /// `MultifaceBlock.isValidStateForPlacement`: the face is new and its
    /// neighbour holds it.
    fn lichen_valid(&mut self, old: u16, cell: [i32; 3], face: usize, lichen: u16) -> bool {
        let table = self.rules.table.as_ref();
        if table.block_of(old) == lichen && has_face(table, old, face) {
            return false;
        }
        let neighbour = self.world.get(super::at(cell, face));
        crate::worldgen::multiface::attaches(table, neighbour, face)
    }

    /// `MultifaceBlock.getStateForPlacement(old, level, cell, face)`.
    fn lichen_placement(&mut self, old: u16, cell: [i32; 3], face: usize) -> Option<u16> {
        let rules = self.rules;
        let table = rules.table.as_ref();
        let lichen = table.block("glow_lichen").ok()?;
        if !self.lichen_valid(old, cell, face, lichen) {
            return None;
        }
        let base = if table.block_of(old) == lichen {
            old
        } else if table.fluid(old) == FLUID_WATER {
            with(table, table.default_state_of(lichen), "waterlogged", "true")
        } else {
            table.default_state_of(lichen)
        };
        Some(with(table, base, FACES[face], "true"))
    }

    /// `GrowingPlantHeadBlock.performBonemeal` at the head `pos`, when its
    /// cell ahead takes it.
    fn grow_plant(&mut self, plant: Plant, pos: [i32; 3], state: u16) -> Option<Plan> {
        let rules = self.rules;
        let table = rules.table.as_ref();
        let water = rules.growth.as_ref().expect("growth facts").water;
        let mut ahead = offset(pos, 0, plant.step(), 0);
        if !plant.grows_into(table, water, self.world.get(ahead)) || !inside(ahead[1]) {
            return None;
        }
        let mut age = (int(table, state, "age") + 1).min(25);
        let count = if plant.vines {
            // `NetherVines.getBlocksToGrowWhenBonemealed`.
            let (mut chance, mut count) = (1.0, 0);
            while self.world.next_double() < chance {
                chance *= 0.826;
                count += 1;
            }
            count
        } else {
            1
        };
        let mut plan = Plan::default();
        for _ in 0..count {
            if !plant.grows_into(table, water, plan.get(&mut self.world, ahead))
                || !inside(ahead[1])
            {
                break;
            }
            plan.writes
                .push((ahead, with_int(table, state, "age", age), ALL));
            ahead = offset(ahead, 0, plant.step(), 0);
            age = (age + 1).min(25);
        }
        Some(plan)
    }

    /// `Block.popResource` of the block's own item: its position's draws.
    fn pop(&mut self) -> Plan {
        for _ in 0..3 {
            self.world.next_double();
        }
        Plan {
            pop: true,
            ..Plan::default()
        }
    }

    /// `SeaPickleBlock.performBonemeal`: pickles on the coral blocks about
    /// it, and itself to four.
    fn spread_pickles(&mut self, pos: [i32; 3], state: u16) -> Plan {
        let rules = self.rules;
        let table = rules.table.as_ref();
        let growth = rules.growth.as_ref().expect("growth facts");
        let mut plan = Plan::default();
        let (mut span, mut shift) = (1, 0);
        for x in 0..5 {
            for z in 0..span {
                for y in pos[1] - 1..pos[1] + 1 {
                    let cell = [pos[0] - 2 + x, y, pos[2] - shift + z];
                    if cell == pos || self.world.next_int(6) != 0 {
                        continue;
                    }
                    if table.block_of(plan.get(&mut self.world, cell)) != growth.water {
                        continue;
                    }
                    let floor = plan.get(&mut self.world, offset(cell, 0, -1, 0));
                    if growth.coral_blocks.contains(table.block_of(floor)) {
                        let pickles = self.world.next_int(4) + 1;
                        let pickle = with_int(table, growth.sea_pickle, "pickles", pickles);
                        plan.writes.push((cell, pickle, ALL));
                    }
                }
            }
            if x < 2 {
                span += 2;
                shift += 1;
            } else {
                span -= 2;
                shift -= 1;
            }
        }
        plan.writes
            .push((pos, with_int(table, state, "pickles", 4), CLIENTS));
        plan
    }

    /// Bone meal on the water beside `pos`'s face `face` (`useOn` when the
    /// clicked block takes none): `growWaterPlant` on a water source there
    /// when the face is sturdy.
    pub(super) fn water_bone_meal(
        &mut self,
        pos: [i32; 3],
        state: u16,
        face: usize,
        corals: bool,
    ) -> i32 {
        let rules = self.rules;
        let table = rules.table.as_ref();
        let water = rules.growth.as_ref().expect("growth facts").water;
        let target = super::at(pos, face);
        if face > 5 || !table.flag(state, STURDY << face) || !self.world.owns(target) {
            return PASS;
        }
        let source = self.world.get(target);
        if table.block_of(source) != water || table.fluid(source) != FLUID_WATER {
            return PASS;
        }
        let Some(plan) = self.decide_growth(|e| e.plan_water(target, face, corals)) else {
            return PASS;
        };
        self.apply_growth(plan);
        self.report.events.push((target, BONE_MEAL_USED, 15));
        USED
    }

    /// `BoneMealItem.growWaterPlant` at the water source `pos`.
    fn plan_water(&mut self, pos: [i32; 3], face: usize, corals: bool) -> Plan {
        let rules = self.rules;
        let table = rules.table.as_ref();
        let growth = rules.growth.as_ref().expect("growth facts");
        let seagrass = table.default_state("seagrass").unwrap_or(0);
        let mut plan = Plan::default();
        'attempts: for j in 0..128 {
            let mut cell = pos;
            for _ in 0..j / 16 {
                let dx = self.world.next_int(3) - 1;
                let dy = (self.world.next_int(3) - 1) * self.world.next_int(3) / 2;
                let dz = self.world.next_int(3) - 1;
                cell = offset(cell, dx, dy, dz);
                if table.flag(plan.get(&mut self.world, cell), FULL_COLLISION) {
                    continue 'attempts;
                }
            }
            let mut grow = seagrass;
            if corals {
                if j == 0 && face >= 2 {
                    let i = self.world.next_int(growth.wall_corals.len() as i32) as usize;
                    grow = growth.wall_corals[i];
                    let names = ["down", "up", "north", "south", "west", "east"];
                    grow = with(table, grow, "facing", names[face]);
                } else if self.world.next_int(4) == 0 {
                    let i = self.world.next_int(growth.underwater.len() as i32) as usize;
                    grow = growth.underwater[i];
                }
            }
            let wall = growth
                .wall_corals
                .contains(&table.default_state_of(table.block_of(grow)))
                && table.has_property(grow, "facing");
            if wall {
                let mut tries = 0;
                while !self.water_plant_survives(&plan, grow, cell) && tries < 4 {
                    let d = self.world.next_int(4) as usize;
                    grow = with(table, grow, "facing", HORIZONTAL_NAMES[d]);
                    tries += 1;
                }
            }
            if !self.water_plant_survives(&plan, grow, cell) {
                continue;
            }
            let here = plan.get(&mut self.world, cell);
            if table.block_of(here) == growth.water && table.fluid(here) == FLUID_WATER {
                plan.writes.push((cell, grow, ALL));
            } else if here == seagrass
                && table.block_of(plan.get(&mut self.world, offset(cell, 0, 1, 0))) == growth.water
                && self.world.next_int(10) == 0
            {
                let upper = offset(cell, 0, 1, 0);
                plan.writes.push((cell, growth.tall_seagrass, CLIENTS));
                plan.writes.push((
                    upper,
                    with(table, growth.tall_seagrass, "half", "upper"),
                    CLIENTS,
                ));
            }
        }
        plan
    }

    /// `canSurvive` of a plant bone meal grows in water: a coral on a sturdy
    /// top, a wall coral against the sturdy face behind it, seagrass by the
    /// live survival facts.
    fn water_plant_survives(&mut self, plan: &Plan, state: u16, pos: [i32; 3]) -> bool {
        let rules = self.rules;
        let table = rules.table.as_ref();
        let class = table.class_name(state);
        if class.contains("WallFan") {
            let facing = ["down", "up", "north", "south", "west", "east"]
                .iter()
                .position(|n| Some(*n) == table.value(state, "facing"))
                .unwrap_or(2);
            let behind = plan.get(&mut self.world, super::at(pos, facing ^ 1));
            return table.flag(behind, STURDY << facing);
        }
        if class.contains("Coral") {
            return table.flag(
                plan.get(&mut self.world, offset(pos, 0, -1, 0)),
                STURDY << 1,
            );
        }
        rules.live_survives(&mut self.world, state, pos)
    }
}

impl<W: World> Engine<'_, W> {
    /// Berries picked (`SweetBerryBushBlock.useWithoutItem`, `CaveVines.use`,
    /// VMC-039b): a sweet berry bush past age 1 goes back to it, cave vines
    /// lose their berries. 1 when there were berries (their loot and sound are
    /// the caller's), else 0.
    pub fn harvest(&mut self, pos: [i32; 3]) -> i32 {
        let rules = self.rules;
        let table = rules.table.as_ref();
        if !self.world.owns(pos) || rules.growth.is_none() {
            return 0;
        }
        let state = self.world.get(pos);
        let picked = match self.growth_kind(state) {
            Some(Kind::SweetBerries) if int(table, state, "age") > 1 => {
                with_int(table, state, "age", 1)
            }
            Some(Kind::Head(_) | Kind::Body(_))
                if table.value(state, "berries") == Some("true") =>
            {
                with(table, state, "berries", "false")
            }
            _ => return 0,
        };
        self.set_block(pos, picked, CLIENTS, super::updater::UPDATE_LIMIT);
        1
    }

    /// Shears used on the block at `pos` (VMC-039c): a full beehive or bee
    /// nest empties (`resetHoneyLevel`), a pumpkin is carved facing `facing`
    /// (`STEP` index; `PumpkinBlock.useItemOn`). 1 when it did (the loot,
    /// sound and the shears' wear are the caller's), else 0.
    pub fn shear(&mut self, pos: [i32; 3], facing: usize) -> i32 {
        let table = self.rules.table.as_ref();
        if !self.world.owns(pos) || facing > 5 {
            return 0;
        }
        let state = self.world.get(pos);
        let name = table.names[table.block_of(state) as usize].as_str();
        let (sheared, flags) = match name {
            "minecraft:beehive" | "minecraft:bee_nest" if int(table, state, "honey_level") >= 5 => {
                (with_int(table, state, "honey_level", 0), ALL)
            }
            "minecraft:pumpkin" => {
                let Ok(carved) = table.default_state("carved_pumpkin") else {
                    return 0;
                };
                (with(table, carved, "facing", FACES[facing]), ALL | 8)
            }
            _ => return 0,
        };
        self.set_block(pos, sheared, flags, super::updater::UPDATE_LIMIT);
        1
    }

    /// A live coral's scheduled tick (`CoralBlock.tick`, `CoralPlantBlock`,
    /// `CoralFanBlock`, `CoralWallFanBlock`): out of water, it dies. Whether
    /// `state` is one.
    pub(super) fn coral_tick(&mut self, pos: [i32; 3], state: u16) -> bool {
        let table = self.rules.table.as_ref();
        let class = table.class_name(state);
        let block = class == "CoralBlock";
        if !block
            && !matches!(
                class,
                "CoralPlantBlock" | "CoralFanBlock" | "CoralWallFanBlock"
            )
        {
            return false;
        }
        let name = &table.names[table.block_of(state) as usize];
        let Ok(dead) = table.default_state(&name.replacen(':', ":dead_", 1)) else {
            return true;
        };
        let wet = !block && table.value(state, "waterlogged") == Some("true");
        let decision = self.decide_growth(|e| {
            wet || (0..6).any(|d| is_water(table, e.world.get(super::at(pos, d))))
        });
        if decision == Some(false) {
            let mut dead = with(table, dead, "waterlogged", "false");
            if let Some(facing) = table.value(state, "facing") {
                dead = with(table, dead, "facing", facing);
            }
            self.set_block(pos, dead, CLIENTS, super::updater::UPDATE_LIMIT);
        }
        true
    }
}
