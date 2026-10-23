//! Plants that grow (VMC-039a): the random ticks of crops (`CropBlock` and
//! `BeetrootBlock`), pumpkin and melon stems (`StemBlock`), sugar cane,
//! cactus, farmland (`FarmlandBlock`), saplings (`SaplingBlock`) and
//! mangrove propagules, bone meal on those that take it, and the scheduled
//! tick of farmland and dirt paths. A sapling that grows into a tree is not
//! grown here: its tick answers `GROW_TREE` and the owner grows the tree
//! through the world generator's features, which the rules do not hold.
//!
//! Light is the raw brightness the stores hold (`max(sky - darkening,
//! block)`) as of the run's start. Rain at a farmland's top
//! (`isRainingAt(pos.above())`) is the caller's.

use std::collections::HashMap;

use super::updater::{Engine, World, ALL, CLIENTS, UPDATE_LIMIT};
use crate::worldgen::blocks::{
    BlockSet, BlockTable, FENCE_GATE, FLUID_FLOWING_WATER, FLUID_WATER, SOLID,
};
use crate::worldgen::json::Json;

/// A random tick's or bone meal's result: nothing to report (bone meal: not
/// a target, so the use passes on).
pub const PASS: i32 = 0;
/// Bone meal was used up, whether or not it grew anything.
pub const USED: i32 = 1;
/// A sapling or propagule grows into a tree at the action's cell (bone meal:
/// used up too).
pub const GROW_TREE: i32 = 2;

/// The level event of bone meal used on a block (its particles).
const BONE_MEAL_USED: i32 = 1505;

/// `UPDATE_INVISIBLE | UPDATE_SKIP_BLOCK_ENTITY_SIDEEFFECTS`: sugar cane's
/// and cactus's age, a sapling's stage.
const QUIET: i32 = 4 | 256;

/// `Direction.Plane.HORIZONTAL` (north, east, south, west) as `STEP`
/// indices, and their names.
const HORIZONTAL: [usize; 4] = [2, 5, 3, 4];
const HORIZONTAL_NAMES: [&str; 4] = ["north", "east", "south", "west"];

/// A `TreeGrower`'s weighted feature lists and the trunk base height of its
/// shortest tree (`getMinimumHeight`, 0 when it has none).
#[derive(Clone, Debug, Default)]
pub struct Grower {
    pub trees: Vec<(String, i32)>,
    pub mega: Vec<(String, i32)>,
    pub flowers: Vec<(String, i32)>,
    pub min_height: i32,
}

impl Grower {
    pub fn parse(json: &Json) -> Result<Grower, String> {
        let list = |key: &str| -> Result<Vec<(String, i32)>, String> {
            json.field(key)?
                .as_array()?
                .iter()
                .map(|e| {
                    let e = e.as_array()?;
                    Ok((e[0].as_str()?.to_string(), e[1].as_i32()?))
                })
                .collect()
        };
        Ok(Grower {
            trees: list("trees")?,
            mega: list("mega")?,
            flowers: list("flowers")?,
            min_height: json.field("min_height")?.as_i32()?,
        })
    }
}

/// `WeightedList.getRandom`: `nextInt(total)` when the list has entries,
/// the entry that index falls in.
pub fn draw<'a>(
    list: &'a [(String, i32)],
    next_int: &mut dyn FnMut(i32) -> i32,
) -> Option<&'a str> {
    let total: i32 = list.iter().map(|(_, w)| w).sum();
    if list.is_empty() {
        return None;
    }
    let mut index = next_int(total);
    for (name, weight) in list {
        if index < *weight {
            return Some(name);
        }
        index -= weight;
    }
    None
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    /// A crop and its maximum age; a beetroot skips one tick in three and
    /// grows a third as far by bone meal.
    Crop {
        max: i32,
        beetroot: bool,
    },
    /// A stem, an index into `stems`.
    Stem(usize),
    SugarCane,
    Cactus,
    Farmland,
    /// A sapling or propagule and its grower, an index into `growers`.
    Sapling {
        grower: usize,
        propagule: bool,
    },
}

struct Stem {
    fruit: u16,
    attached: u16,
    fruit_support: BlockSet,
}

/// The growing blocks and what they read.
pub struct Growth {
    kinds: HashMap<u16, Kind>,
    stems: Vec<Stem>,
    pub growers: Vec<(String, Grower)>,
    grows_crops: BlockSet,
    maintains_farmland: BlockSet,
    flowers: BlockSet,
    cactus: u16,
    cactus_flower: u16,
    dirt: u16,
    farmland: u16,
    dirt_path: u16,
}

/// A state's integer property (0 without it), and the state with it set.
fn int(table: &BlockTable, state: u16, property: &str) -> i32 {
    table
        .value(state, property)
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
}

fn with_int(table: &BlockTable, state: u16, property: &str, value: i32) -> u16 {
    table
        .with(state, property, &value.to_string())
        .unwrap_or(state)
}

fn offset(pos: [i32; 3], dx: i32, dy: i32, dz: i32) -> [i32; 3] {
    [pos[0] + dx, pos[1] + dy, pos[2] + dz]
}

/// `Mth.nextInt(random, 2, 5)`.
fn two_to_five(next_int: &mut dyn FnMut(i32) -> i32) -> i32 {
    next_int(4) + 2
}

impl Growth {
    /// From the block table and the growth facts (`priv/physics/growth.json`:
    /// the tree growers and the sapling blocks that use them).
    pub fn new(table: &BlockTable, facts: &Json) -> Result<Growth, String> {
        let mut kinds = HashMap::new();
        let growers = facts
            .field("growers")?
            .entries()?
            .iter()
            .map(|(name, g)| Ok((name.clone(), Grower::parse(g)?)))
            .collect::<Result<Vec<_>, String>>()?;
        for (block, grower) in facts.field("saplings")?.entries()? {
            let block = table.block(block)?;
            let grower = grower.as_str()?;
            let index = growers
                .iter()
                .position(|(n, _)| n == grower)
                .ok_or_else(|| format!("unknown tree grower {grower}"))?;
            let propagule =
                table.class_name(table.default_state_of(block)) == "MangrovePropaguleBlock";
            kinds.insert(
                block,
                Kind::Sapling {
                    grower: index,
                    propagule,
                },
            );
        }
        for name in ["wheat", "carrots", "potatoes", "beetroots"] {
            let block = table.block(name)?;
            let default = table.default_state_of(block);
            let max = (0..16)
                .take_while(|a| table.with(default, "age", &a.to_string()).is_some())
                .last()
                .unwrap_or(0);
            let beetroot = name == "beetroots";
            kinds.insert(block, Kind::Crop { max, beetroot });
        }
        let mut stems = Vec::new();
        for (stem, fruit, attached, support) in [
            (
                "pumpkin_stem",
                "pumpkin",
                "attached_pumpkin_stem",
                "minecraft:supports_pumpkin_stem_fruit",
            ),
            (
                "melon_stem",
                "melon",
                "attached_melon_stem",
                "minecraft:supports_melon_stem_fruit",
            ),
        ] {
            kinds.insert(table.block(stem)?, Kind::Stem(stems.len()));
            stems.push(Stem {
                fruit: table.default_state(fruit)?,
                attached: table.default_state(attached)?,
                fruit_support: table.tag(support)?.clone(),
            });
        }
        kinds.insert(table.block("sugar_cane")?, Kind::SugarCane);
        kinds.insert(table.block("cactus")?, Kind::Cactus);
        kinds.insert(table.block("farmland")?, Kind::Farmland);
        Ok(Growth {
            kinds,
            stems,
            growers,
            grows_crops: table.tag("minecraft:grows_crops")?.clone(),
            maintains_farmland: table.tag("minecraft:maintains_farmland")?.clone(),
            flowers: table.tag("minecraft:flowers")?.clone(),
            cactus: table.default_state("cactus")?,
            cactus_flower: table.default_state("cactus_flower")?,
            dirt: table.default_state("dirt")?,
            farmland: table.block("farmland")?,
            dirt_path: table.block("dirt_path")?,
        })
    }

    fn kind(&self, table: &BlockTable, state: u16) -> Option<Kind> {
        self.kinds.get(&table.block_of(state)).copied()
    }

    /// The tree grower of sapling `state`, if it is one.
    pub fn grower(&self, table: &BlockTable, state: u16) -> Option<&Grower> {
        match self.kind(table, state)? {
            Kind::Sapling { grower, .. } => Some(&self.growers[grower].1),
            _ => None,
        }
    }
}

/// What a growth decision (made from reads and draws alone) does: the
/// `setBlock`s in order, then whether a tree grows.
#[derive(Default)]
struct Plan {
    writes: Vec<([i32; 3], u16, i32)>,
    tree: bool,
}

impl Plan {
    fn set(pos: [i32; 3], state: u16, flags: i32) -> Plan {
        Plan {
            writes: vec![(pos, state, flags)],
            tree: false,
        }
    }

    fn tree() -> Plan {
        Plan {
            writes: Vec::new(),
            tree: true,
        }
    }
}

impl<W: World> Engine<'_, W> {
    fn growth(&self) -> &Growth {
        self.rules.growth.as_ref().expect("growth facts")
    }

    fn growth_kind(&self, state: u16) -> Option<Kind> {
        self.rules
            .growth
            .as_ref()
            .and_then(|g| g.kind(&self.rules.table, state))
    }

    /// Whether the cell at `pos` holds a growing plant.
    pub fn growing(&mut self, pos: [i32; 3]) -> bool {
        if !self.world.owns(pos) {
            return false;
        }
        let state = self.world.get(pos);
        self.growth_kind(state).is_some()
    }

    /// `getRawBrightness(pos, darkening)`.
    fn raw_brightness(&mut self, pos: [i32; 3], darkening: i32) -> i32 {
        (self.world.sky_light(pos) - darkening).max(self.world.block_light(pos))
    }

    /// A random tick of a growing block at `pos` (`randomTick`), `rain`
    /// whether it rains at the cell above: `PASS`, or `GROW_TREE`.
    pub fn growth_random_tick(&mut self, pos: [i32; 3], rain: bool) -> i32 {
        if !self.world.owns(pos) {
            return PASS;
        }
        let state = self.world.get(pos);
        let Some(kind) = self.growth_kind(state) else {
            return PASS;
        };
        match self.decide_growth(|e| e.plan_tick(kind, pos, state, rain)) {
            Some(plan) => self.apply_growth(plan),
            None => PASS,
        }
    }

    /// Bone meal on the block at `pos` (`BoneMealItem.useOn` on a block that
    /// takes it, `growCrop`): `PASS` when it is not a target, else `USED` or
    /// `GROW_TREE`, with the bone meal's level event.
    pub fn bone_meal(&mut self, pos: [i32; 3]) -> i32 {
        if !self.world.owns(pos) {
            return PASS;
        }
        let state = self.world.get(pos);
        let Some(kind) = self.growth_kind(state) else {
            return PASS;
        };
        let Some(plan) = self.decide_growth(|e| e.plan_bone_meal(kind, pos, state)) else {
            return PASS;
        };
        let Some(plan) = plan else {
            return PASS;
        };
        // A stem that bone meal grows to its last age ticks at once.
        let grown = match kind {
            Kind::Stem(_) => plan
                .writes
                .first()
                .map(|w| w.1)
                .filter(|&s| int(&self.rules.table, s, "age") == 7),
            _ => None,
        };
        let mut result = self.apply_growth(plan);
        if let Some(grown) = grown {
            if let Some(plan) = self.decide_growth(|e| e.plan_tick(kind, pos, grown, false)) {
                result = self.apply_growth(plan);
            }
        }
        // `BoneMealItem.useOn`'s particles.
        self.report.events.push((pos, BONE_MEAL_USED, 15));
        result.max(USED)
    }

    /// An entity tramples the farmland at `pos` (`FarmlandBlock.fallOn`
    /// once it decided to): it turns to dirt (`turnToBaseBlock`; pushing the
    /// entities on it up is the caller's). 1 when it did.
    pub fn trample(&mut self, pos: [i32; 3]) -> i32 {
        let Some(growth) = self.rules.growth.as_ref() else {
            return 0;
        };
        let (farmland, dirt) = (growth.farmland, growth.dirt);
        if !self.world.owns(pos) || self.rules.table.block_of(self.world.get(pos)) != farmland {
            return 0;
        }
        i32::from(self.set_block(pos, dirt, ALL, UPDATE_LIMIT))
    }

    /// The scheduled tick of farmland or a dirt path: one that cannot
    /// survive turns to dirt (`turnToBaseBlock`; the entities on it are not
    /// pushed up). Whether `state` is one.
    pub(super) fn growth_tick(&mut self, pos: [i32; 3], state: u16) -> bool {
        let Some(growth) = self.rules.growth.as_ref() else {
            return false;
        };
        let table = self.rules.table.clone();
        let block = table.block_of(state);
        if block != growth.farmland && block != growth.dirt_path {
            return false;
        }
        let (dirt, farmland) = (growth.dirt, block == growth.farmland);
        let survives = self.decide_growth(|e| {
            let above = e.world.get(offset(pos, 0, 1, 0));
            !table.flag(above, SOLID)
                || if farmland {
                    e.growth()
                        .maintains_farmland
                        .contains(table.block_of(above))
                } else {
                    table.flag2(above, FENCE_GATE)
                }
        });
        if survives == Some(false) {
            self.set_block(pos, dirt, ALL, UPDATE_LIMIT);
        }
        true
    }

    /// Run `decide` (reads and draws) unless it reads past the owner.
    fn decide_growth<T>(&mut self, decide: impl FnOnce(&mut Self) -> T) -> Option<T> {
        let mark = self.world.begin();
        let decision = decide(self);
        if self.world.crossed(mark) {
            self.report.stopped += 1;
            None
        } else {
            Some(decision)
        }
    }

    fn apply_growth(&mut self, plan: Plan) -> i32 {
        for (p, s, flags) in plan.writes {
            self.set_block(p, s, flags, UPDATE_LIMIT);
        }
        if plan.tree {
            GROW_TREE
        } else {
            PASS
        }
    }

    fn plan_tick(&mut self, kind: Kind, pos: [i32; 3], state: u16, rain: bool) -> Plan {
        let table = self.rules.table.clone();
        let table = table.as_ref();
        let above = offset(pos, 0, 1, 0);
        match kind {
            Kind::Crop { max, beetroot } => {
                let age = int(table, state, "age");
                // A grown crop does not tick at all.
                if age >= max || (beetroot && self.world.next_int(3) == 0) {
                    return Plan::default();
                }
                if self.raw_brightness(pos, 0) >= 9 {
                    let speed = self.growth_speed(state, pos);
                    if self.world.next_int((25.0f32 / speed) as i32 + 1) == 0 {
                        return Plan::set(pos, with_int(table, state, "age", age + 1), CLIENTS);
                    }
                }
                Plan::default()
            }
            Kind::Stem(index) => {
                if self.raw_brightness(pos, 0) < 9 {
                    return Plan::default();
                }
                let speed = self.growth_speed(state, pos);
                if self.world.next_int((25.0f32 / speed) as i32 + 1) != 0 {
                    return Plan::default();
                }
                let age = int(table, state, "age");
                if age < 7 {
                    return Plan::set(pos, with_int(table, state, "age", age + 1), CLIENTS);
                }
                let i = self.world.next_int(4) as usize;
                let cell = super::at(pos, HORIZONTAL[i]);
                let below = self.world.get(offset(cell, 0, -1, 0));
                let stem = &self.growth().stems[index];
                let (fruit, attached) = (stem.fruit, stem.attached);
                let supported = stem.fruit_support.contains(table.block_of(below));
                if table.is_air(self.world.get(cell)) && supported {
                    let attached = table
                        .with(attached, "facing", HORIZONTAL_NAMES[i])
                        .unwrap_or(attached);
                    return Plan {
                        writes: vec![(cell, fruit, ALL), (pos, attached, ALL)],
                        tree: false,
                    };
                }
                Plan::default()
            }
            Kind::SugarCane => {
                if !table.is_air(self.world.get(above)) {
                    return Plan::default();
                }
                let block = table.block_of(state);
                let mut height = 1;
                while table.block_of(self.world.get(offset(pos, 0, -height, 0))) == block {
                    height += 1;
                }
                if height >= 3 {
                    return Plan::default();
                }
                let age = int(table, state, "age");
                if age == 15 {
                    Plan {
                        writes: vec![
                            (above, table.default_state_of(block), ALL),
                            (pos, with_int(table, state, "age", 0), QUIET),
                        ],
                        tree: false,
                    }
                } else {
                    Plan::set(pos, with_int(table, state, "age", age + 1), QUIET)
                }
            }
            Kind::Cactus => {
                if !table.is_air(self.world.get(above)) {
                    return Plan::default();
                }
                let block = table.block_of(state);
                let age = int(table, state, "age");
                let mut height = 1;
                while table.block_of(self.world.get(offset(pos, 0, -height, 0))) == block {
                    height += 1;
                    if height == 3 && age == 15 {
                        return Plan::default();
                    }
                }
                let mut plan = Plan::default();
                let cactus = self.growth().cactus;
                if age == 8 && self.rules.live_survives(&mut self.world, cactus, above) {
                    let chance = if height >= 3 { 0.25 } else { 0.1 };
                    if self.world.next_double() <= chance {
                        let flower = self.growth().cactus_flower;
                        plan.writes.push((above, flower, ALL));
                    }
                } else if age == 15 && height < 3 {
                    plan.writes.push((above, cactus, ALL));
                    plan.writes
                        .push((pos, with_int(table, state, "age", 0), QUIET));
                }
                if age < 15 {
                    plan.writes
                        .push((pos, with_int(table, state, "age", age + 1), QUIET));
                }
                plan
            }
            Kind::Farmland => {
                let moisture = int(table, state, "moisture");
                if !self.near_water(pos) && !rain {
                    let top = table.block_of(self.world.get(above));
                    if moisture > 0 {
                        Plan::set(
                            pos,
                            with_int(table, state, "moisture", moisture - 1),
                            CLIENTS,
                        )
                    } else if !self.growth().maintains_farmland.contains(top) {
                        Plan::set(pos, self.growth().dirt, ALL)
                    } else {
                        Plan::default()
                    }
                } else if moisture < 7 {
                    Plan::set(pos, with_int(table, state, "moisture", 7), CLIENTS)
                } else {
                    Plan::default()
                }
            }
            Kind::Sapling { propagule, .. } => {
                if propagule && table.value(state, "hanging") == Some("true") {
                    let age = int(table, state, "age");
                    if age != 4 {
                        return Plan::set(pos, with_int(table, state, "age", age + 1), CLIENTS);
                    }
                    return Plan::default();
                }
                // A propagule on the ground needs no light.
                if !propagule && self.raw_brightness(above, self.redstone.sky_darken) < 9 {
                    return Plan::default();
                }
                if self.world.next_int(7) == 0 {
                    return self.advance_tree(pos, state);
                }
                Plan::default()
            }
        }
    }

    /// `SaplingBlock.advanceTree`: the next stage, or the tree.
    fn advance_tree(&mut self, pos: [i32; 3], state: u16) -> Plan {
        let table = self.rules.table.as_ref();
        if int(table, state, "stage") == 0 {
            Plan::set(pos, with_int(table, state, "stage", 1), QUIET)
        } else {
            Plan::tree()
        }
    }

    /// Bone meal's decision: `None` when the block is not a target.
    fn plan_bone_meal(&mut self, kind: Kind, pos: [i32; 3], state: u16) -> Option<Plan> {
        let table = self.rules.table.clone();
        let table = table.as_ref();
        match kind {
            Kind::Crop { max, beetroot } => {
                let age = int(table, state, "age");
                if age >= max {
                    return None;
                }
                let mut grow = two_to_five(&mut |b| self.world.next_int(b));
                if beetroot {
                    grow /= 3;
                }
                let age = max.min(age + grow);
                Some(Plan::set(pos, with_int(table, state, "age", age), CLIENTS))
            }
            Kind::Stem(_) => {
                let age = int(table, state, "age");
                if age == 7 {
                    return None;
                }
                let age = 7.min(age + two_to_five(&mut |b| self.world.next_int(b)));
                Some(Plan::set(pos, with_int(table, state, "age", age), CLIENTS))
            }
            Kind::Sapling { grower, propagule } => {
                let hanging = propagule && table.value(state, "hanging") == Some("true");
                if hanging {
                    let age = int(table, state, "age");
                    if age == 4 {
                        return None;
                    }
                    return Some(Plan::set(
                        pos,
                        with_int(table, state, "age", age + 1),
                        CLIENTS,
                    ));
                }
                // `TreeGrower.canGrow` and the build height (a propagule
                // skips both).
                if !propagule {
                    let grower = self.growth().growers[grower].1.clone();
                    if !self.can_grow(&grower, pos, state) {
                        return None;
                    }
                    let top = pos[1] + grower.min_height;
                    if !(crate::column::MIN_Y..crate::column::MIN_Y + crate::column::HEIGHT as i32)
                        .contains(&top)
                    {
                        return None;
                    }
                }
                if self.world.next_float() < 0.45 {
                    Some(self.advance_tree(pos, state))
                } else {
                    Some(Plan::default())
                }
            }
            Kind::SugarCane | Kind::Cactus | Kind::Farmland => None,
        }
    }

    /// `TreeGrower.canGrow`: its draws, and a grower with only mega trees
    /// needs a 2 × 2 of the sapling.
    fn can_grow(&mut self, grower: &Grower, pos: [i32; 3], state: u16) -> bool {
        let flowers = self.has_flowers(pos);
        let feature = if flowers && !grower.flowers.is_empty() {
            draw(&grower.flowers, &mut |b| self.world.next_int(b)).is_some()
        } else {
            draw(&grower.trees, &mut |b| self.world.next_int(b)).is_some()
        };
        let mega = draw(&grower.mega, &mut |b| self.world.next_int(b)).is_some();
        if !feature && mega {
            self.two_by_two(pos, state).is_some()
        } else {
            true
        }
    }

    /// `TreeGrower.hasFlowers`: a flower within 2 across and 1 up or down.
    fn has_flowers(&mut self, pos: [i32; 3]) -> bool {
        let table = self.rules.table.clone();
        for y in -1..=1 {
            for z in -2..=2 {
                for x in -2..=2 {
                    let state = self.world.get(offset(pos, x, y, z));
                    if self.growth().flowers.contains(table.block_of(state)) {
                        return true;
                    }
                }
            }
        }
        false
    }

    /// `TreeGrower.findTwoByTwoSaplingPos`: the offset of a 2 × 2 of the
    /// sapling's block that holds `pos`.
    fn two_by_two(&mut self, pos: [i32; 3], state: u16) -> Option<(i32, i32)> {
        let table = self.rules.table.clone();
        let block = table.block_of(state);
        for dx in [0, -1] {
            for dz in [0, -1] {
                let all = [(0, 0), (1, 0), (0, 1), (1, 1)].iter().all(|&(x, z)| {
                    table.block_of(self.world.get(offset(pos, dx + x, 0, dz + z))) == block
                });
                if all {
                    return Some((dx, dz));
                }
            }
        }
        None
    }

    /// `CropBlock.getGrowthSpeed`, in floats as vanilla's.
    fn growth_speed(&mut self, state: u16, pos: [i32; 3]) -> f32 {
        let table = self.rules.table.clone();
        let block = table.block_of(state);
        let below = offset(pos, 0, -1, 0);
        let mut speed = 1.0f32;
        for x in -1..=1 {
            for z in -1..=1 {
                let soil = self.world.get(offset(below, x, 0, z));
                let mut block_speed = 0.0f32;
                if self.growth().grows_crops.contains(table.block_of(soil)) {
                    block_speed = 1.0;
                    if int(&table, soil, "moisture") > 0 {
                        block_speed = 3.0;
                    }
                }
                if x != 0 || z != 0 {
                    block_speed /= 4.0;
                }
                speed += block_speed;
            }
        }
        let mut is =
            |dx: i32, dz: i32| table.block_of(self.world.get(offset(pos, dx, 0, dz))) == block;
        let horizontal = is(-1, 0) || is(1, 0);
        let vertical = is(0, -1) || is(0, 1);
        if (horizontal && vertical) || is(-1, -1) || is(1, -1) || is(1, 1) || is(-1, 1) {
            speed /= 2.0;
        }
        speed
    }

    /// `FarmlandBlock.isNearWater`: water within 4 across, at or one above.
    fn near_water(&mut self, pos: [i32; 3]) -> bool {
        let table = self.rules.table.clone();
        for y in 0..=1 {
            for z in -4..=4 {
                for x in -4..=4 {
                    let fluid = table.fluid(self.world.get(offset(pos, x, y, z)));
                    if fluid == FLUID_WATER || fluid == FLUID_FLOWING_WATER {
                        return true;
                    }
                }
            }
        }
        false
    }
}
