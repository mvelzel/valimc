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
            _ => Plan::default(),
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
            _ => None,
        }
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
