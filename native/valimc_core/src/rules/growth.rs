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
use std::sync::Arc;

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
/// The generator grows at the action's cell (`Growth::generated`): a
/// sapling's, propagule's or azalea's tree, or what bone meal on a grass
/// block, nylium, moss or a mushroom places (bone meal: used up too).
pub const GROW_TREE: i32 = 2;
/// Bone meal was used up and drops a copy of the block at the action's cell
/// (a tall flower, a full flower bed).
pub const POP: i32 = 3;

/// The level event of bone meal used on a block (its particles).
pub(super) const BONE_MEAL_USED: i32 = 1505;

/// `UPDATE_INVISIBLE | UPDATE_SKIP_BLOCK_ENTITY_SIDEEFFECTS`: sugar cane's
/// and cactus's age, a sapling's stage.
const QUIET: i32 = 4 | 256;

/// `Direction.Plane.HORIZONTAL` (north, east, south, west) as `STEP`
/// indices, and their names.
pub(super) const HORIZONTAL: [usize; 4] = [2, 5, 3, 4];
pub(super) const HORIZONTAL_NAMES: [&str; 4] = ["north", "east", "south", "west"];

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

/// How far bone meal grows a crop.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Increase {
    /// `Mth.nextInt(random, 2, 5)`.
    Random,
    /// A beetroot's third of it.
    Third,
    /// A torchflower's one.
    One,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Kind {
    /// A crop: its maximum age, whether it skips one random tick in three
    /// (beetroot, torchflower), bone meal's increase, and the state of its
    /// last age when that is another block (a grown torchflower).
    Crop {
        max: i32,
        skip: bool,
        increase: Increase,
        grown: Option<u16>,
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
    /// An azalea and its grower (`AzaleaBlock`, VMC-039b).
    Azalea(usize),
    /// A grass block or mycelium (`SpreadingSnowyBlock`).
    Spreading,
    /// A mushroom and its huge mushroom, an index into `mushrooms`.
    Mushroom(usize),
    /// A block whose bone meal places a feature above it (moss,
    /// `BonemealableFeaturePlacerBlock`), an index into `placers`.
    Placer(usize),
    /// Crimson or warped nylium.
    Nylium,
    Pitcher,
    NetherWart,
    Cocoa,
    SweetBerries,
    /// A growing plant's head or body (`GrowingPlantHeadBlock`,
    /// `GrowingPlantBodyBlock`: kelp, the Nether's vines, cave vines), an
    /// index into `plants`.
    Head(usize),
    Body(usize),
    /// Short grass or a fern and the lower half it grows into.
    Small(u16),
    /// A two-block flower: bone meal drops a copy.
    TallFlower,
    /// Pink petals and wildflowers.
    FlowerBed,
    Seagrass,
    /// A plant that bone meal spreads beside it (`BonemealableBlock
    /// .findSpreadableNeighbourPos`): the state it places.
    Spreader(u16),
    ShortDryGrass,
    SeaPickle,
    MangroveLeaves,
    RootedDirt,
}

/// A growing plant (`GrowingPlantHeadBlock`): its head and body blocks,
/// whether it grows up (else down), its chance to grow per random tick,
/// whether it grows into water (else air), whether bone meal grows it by
/// the Nether's vines' draws (else one), and whether it bears berries (cave
/// vines: bone meal sets them instead).
#[derive(Clone, Copy, Debug)]
pub(super) struct Plant {
    pub head: u16,
    pub body: u16,
    pub up: bool,
    pub chance: f64,
    pub water: bool,
    pub vines: bool,
    pub berries: bool,
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
    pub(super) plants: Vec<Plant>,
    pub growers: Vec<(String, Grower)>,
    /// Per biome, the features bone meal on a grass block places by chance
    /// (`getBoneMealFeatures`).
    pub bone_meal_features: Arc<HashMap<String, Vec<String>>>,
    /// Per mushroom its huge mushroom feature and the height it needs.
    pub(super) mushrooms: Vec<(String, i32)>,
    /// Per feature placer and nylium (by block) the feature it places.
    pub(super) placers: Vec<String>,
    placer_of: HashMap<u16, usize>,
    pub(super) grass_block: u16,
    grows_crops: BlockSet,
    maintains_farmland: BlockSet,
    flowers: BlockSet,
    cactus: u16,
    cactus_flower: u16,
    pub(super) dirt: u16,
    farmland: u16,
    dirt_path: u16,
    /// Per state: whether a grass block (or mycelium) dies under it
    /// (`SpreadingSnowyBlock.canStayAlive` false), and nylium.
    pub(super) smothers_grass: Vec<bool>,
    pub(super) smothers_nylium: Vec<bool>,
    pub(super) dirt_block: u16,
    pub(super) netherrack: u16,
    pub(super) snow: BlockSet,
    pub(super) coral_blocks: BlockSet,
    pub(super) water: u16,
    pub(super) pitcher: u16,
    pub(super) tall_seagrass: u16,
    pub(super) tall_dry_grass: u16,
    pub(super) hanging_propagule: u16,
    pub(super) hanging_roots: u16,
    pub(super) sea_pickle: u16,
    /// `BlockTags.WALL_CORALS` and `UNDERWATER_BONEMEALS` in their
    /// iteration order (bone meal in warm water draws from them).
    pub(super) wall_corals: Vec<u16>,
    pub(super) underwater: Vec<u16>,
}

/// A state's integer property (0 without it), and the state with it set.
pub(super) fn int(table: &BlockTable, state: u16, property: &str) -> i32 {
    table
        .value(state, property)
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
}

pub(super) fn with_int(table: &BlockTable, state: u16, property: &str, value: i32) -> u16 {
    table
        .with(state, property, &value.to_string())
        .unwrap_or(state)
}

/// `CropBlock.getStateForAge`: the crop at `age`, its grown block at its
/// last age when that is another (a torchflower).
fn crop_age(table: &BlockTable, kind: Kind, state: u16, age: i32) -> u16 {
    match kind {
        Kind::Crop {
            max,
            grown: Some(grown),
            ..
        } if age == max => grown,
        _ => with_int(table, state, "age", age),
    }
}

pub(super) fn offset(pos: [i32; 3], dx: i32, dy: i32, dz: i32) -> [i32; 3] {
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
        for (name, skip, increase) in [
            ("wheat", false, Increase::Random),
            ("carrots", false, Increase::Random),
            ("potatoes", false, Increase::Random),
            ("beetroots", true, Increase::Third),
            ("torchflower_crop", true, Increase::One),
        ] {
            let block = table.block(name)?;
            let default = table.default_state_of(block);
            let mut max = (0..16)
                .take_while(|a| table.with(default, "age", &a.to_string()).is_some())
                .last()
                .unwrap_or(0);
            // A torchflower crop's last age is the torchflower.
            let grown = if name == "torchflower_crop" {
                max += 1;
                Some(table.default_state("torchflower")?)
            } else {
                None
            };
            kinds.insert(
                block,
                Kind::Crop {
                    max,
                    skip,
                    increase,
                    grown,
                },
            );
        }
        for (block, grower) in facts.field("azaleas")?.entries()? {
            let grower = grower.as_str()?;
            let index = growers
                .iter()
                .position(|(n, _)| n == grower)
                .ok_or_else(|| format!("unknown tree grower {grower}"))?;
            kinds.insert(table.block(block)?, Kind::Azalea(index));
        }
        let mut plants = Vec::new();
        for (head, body, up, chance, water, vines, berries) in [
            ("kelp", "kelp_plant", true, 0.14, true, false, false),
            (
                "weeping_vines",
                "weeping_vines_plant",
                false,
                0.1,
                false,
                true,
                false,
            ),
            (
                "twisting_vines",
                "twisting_vines_plant",
                true,
                0.1,
                false,
                true,
                false,
            ),
            (
                "cave_vines",
                "cave_vines_plant",
                false,
                0.1,
                false,
                false,
                true,
            ),
        ] {
            let (head, body) = (table.block(head)?, table.block(body)?);
            kinds.insert(head, Kind::Head(plants.len()));
            kinds.insert(body, Kind::Body(plants.len()));
            plants.push(Plant {
                head,
                body,
                up,
                chance,
                water,
                vines,
                berries,
            });
        }
        for (name, kind) in [
            ("grass_block", Kind::Spreading),
            ("mycelium", Kind::Spreading),
            ("crimson_nylium", Kind::Nylium),
            ("warped_nylium", Kind::Nylium),
            ("pitcher_crop", Kind::Pitcher),
            ("nether_wart", Kind::NetherWart),
            ("cocoa", Kind::Cocoa),
            ("sweet_berry_bush", Kind::SweetBerries),
            (
                "short_grass",
                Kind::Small(table.default_state("tall_grass")?),
            ),
            ("fern", Kind::Small(table.default_state("large_fern")?)),
            ("seagrass", Kind::Seagrass),
            ("bush", Kind::Spreader(table.default_state("bush")?)),
            (
                "firefly_bush",
                Kind::Spreader(table.default_state("firefly_bush")?),
            ),
            (
                "tall_dry_grass",
                Kind::Spreader(table.default_state("short_dry_grass")?),
            ),
            ("short_dry_grass", Kind::ShortDryGrass),
            ("sea_pickle", Kind::SeaPickle),
            ("mangrove_leaves", Kind::MangroveLeaves),
            ("rooted_dirt", Kind::RootedDirt),
        ] {
            kinds.insert(table.block(name)?, kind);
        }
        let mut mushrooms = Vec::new();
        for (name, mushroom) in facts.field("mushrooms")?.entries()? {
            kinds.insert(table.block(name)?, Kind::Mushroom(mushrooms.len()));
            mushrooms.push((
                mushroom.field("feature")?.as_str()?.to_string(),
                mushroom.field("height")?.as_i32()?,
            ));
        }
        let (mut placers, mut placer_of) = (Vec::new(), HashMap::new());
        for (name, feature) in facts.field("feature_placers")?.entries()? {
            let block = table.block(name)?;
            kinds.entry(block).or_insert(Kind::Placer(placers.len()));
            placer_of.insert(block, placers.len());
            placers.push(feature.as_str()?.to_string());
        }
        let bone_meal_features = facts
            .field("bone_meal_features")?
            .entries()?
            .iter()
            .map(|(biome, list)| {
                let list = list
                    .as_array()?
                    .iter()
                    .map(|f| Ok(f.as_str()?.to_string()))
                    .collect::<Result<Vec<_>, String>>()?;
                Ok((biome.clone(), list))
            })
            .collect::<Result<HashMap<_, _>, String>>()?;
        for block in 0..table.names.len() as u16 {
            let kind = match table.class_name(table.default_state_of(block)) {
                "TallFlowerBlock" => Kind::TallFlower,
                "FlowerBedBlock" => Kind::FlowerBed,
                _ => continue,
            };
            kinds.insert(block, kind);
        }
        let smothers = |key: &str| -> Result<Vec<bool>, String> {
            let mut set = vec![false; table.block_of.len()];
            for run in facts.field("smothers")?.field(key)?.as_array()? {
                let run = run.as_array()?;
                for state in run[0].as_i32()?..=run[1].as_i32()? {
                    *set.get_mut(state as usize)
                        .ok_or("smothering state out of range")? = true;
                }
            }
            Ok(set)
        };
        let ordered = |tag: &str| -> Result<Vec<u16>, String> {
            Ok(table
                .tag_blocks(tag)?
                .iter()
                .map(|&b| table.default_state_of(b))
                .collect())
        };
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
            bone_meal_features: Arc::new(bone_meal_features),
            mushrooms,
            placers,
            placer_of,
            grass_block: table.block("grass_block")?,
            smothers_grass: smothers("grass")?,
            smothers_nylium: smothers("nylium")?,
            dirt_block: table.block("dirt")?,
            netherrack: table.default_state("netherrack")?,
            snow: table.tag("minecraft:snow")?.clone(),
            coral_blocks: table.tag("minecraft:coral_blocks")?.clone(),
            water: table.block("water")?,
            pitcher: table.block("pitcher_crop")?,
            tall_seagrass: table.default_state("tall_seagrass")?,
            tall_dry_grass: table.default_state("tall_dry_grass")?,
            hanging_propagule: {
                let propagule = table.default_state("mangrove_propagule")?;
                table
                    .with(propagule, "hanging", "true")
                    .ok_or("no hanging propagule")?
            },
            hanging_roots: table.default_state("hanging_roots")?,
            sea_pickle: table.default_state("sea_pickle")?,
            wall_corals: ordered("minecraft:wall_corals")?,
            underwater: ordered("minecraft:underwater_bonemeals")?,
            plants,
        })
    }

    fn kind(&self, table: &BlockTable, state: u16) -> Option<Kind> {
        self.kinds.get(&table.block_of(state)).copied()
    }

    /// What the generator grows at a cell holding `state` once a random
    /// tick or bone meal answered `GROW_TREE` there.
    pub fn generated(&self, table: &BlockTable, state: u16) -> Option<Generated<'_>> {
        let block = table.block_of(state);
        Some(match self.kind(table, state)? {
            Kind::Sapling { grower, .. } | Kind::Azalea(grower) => {
                Generated::Tree(&self.growers[grower].1)
            }
            Kind::Spreading if block == self.grass_block => {
                Generated::Grass(self.bone_meal_features.clone())
            }
            Kind::Mushroom(index) => Generated::Mushroom(&self.mushrooms[index].0),
            Kind::Nylium | Kind::Placer(_) => {
                Generated::Above(&self.placers[*self.placer_of.get(&block)?])
            }
            _ => return None,
        })
    }

    /// The tree grower of sapling (or azalea) `state`, if it is one.
    pub fn grower(&self, table: &BlockTable, state: u16) -> Option<&Grower> {
        match self.kind(table, state)? {
            Kind::Sapling { grower, .. } | Kind::Azalea(grower) => Some(&self.growers[grower].1),
            _ => None,
        }
    }
}

/// What the generator grows (VMC-039a, VMC-039b).
pub enum Generated<'a> {
    /// A sapling's or azalea's tree, by its grower.
    Tree(&'a Grower),
    /// A grass block's bone meal (`GrassBlock.performBonemeal`): grass, and
    /// by chance a biome's bone meal feature.
    Grass(Arc<HashMap<String, Vec<String>>>),
    /// A mushroom's huge mushroom (`MushroomBlock.growMushroom`).
    Mushroom(&'a str),
    /// A feature placed on the cell above (moss, nylium).
    Above(&'a str),
}

/// What a growth decision (made from reads and draws alone) does: the
/// `setBlock`s in order, then whether a tree grows.
#[derive(Default)]
pub(super) struct Plan {
    pub writes: Vec<([i32; 3], u16, i32)>,
    pub tree: bool,
    /// Bone meal drops a copy of the block at the action's cell
    /// (`Block.popResource`, its position's draws taken).
    pub pop: bool,
}

impl Plan {
    pub(super) fn set(pos: [i32; 3], state: u16, flags: i32) -> Plan {
        Plan {
            writes: vec![(pos, state, flags)],
            ..Plan::default()
        }
    }

    /// The generator grows at the action's cell (`GROW_TREE`).
    pub(super) fn grow() -> Plan {
        Plan {
            tree: true,
            ..Plan::default()
        }
    }

    /// The cell at `pos` as the plan's writes so far leave it.
    pub(super) fn get<W: World>(&self, world: &mut W, pos: [i32; 3]) -> u16 {
        match self.writes.iter().rev().find(|w| w.0 == pos) {
            Some(w) => w.1,
            None => world.get(pos),
        }
    }
}

impl<W: World> Engine<'_, W> {
    pub(super) fn growth(&self) -> &Growth {
        self.rules.growth.as_ref().expect("growth facts")
    }

    pub(super) fn growth_kind(&self, state: u16) -> Option<Kind> {
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
    pub(super) fn raw_brightness(&mut self, pos: [i32; 3], darkening: i32) -> i32 {
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

    /// Bone meal on the block at `pos` (`BoneMealItem.useOn`): on a block
    /// that takes it (`growCrop`), else, clicked on face `face` (`STEP`
    /// index), on the water beside it (`growWaterPlant`, `corals` whether
    /// the biome there grows corals). `PASS` when nothing takes it, else
    /// `USED`, `GROW_TREE` or `POP`, with the bone meal's level event.
    pub fn bone_meal(&mut self, pos: [i32; 3], face: Option<usize>, corals: bool) -> i32 {
        if !self.world.owns(pos) {
            return PASS;
        }
        let state = self.world.get(pos);
        if let Some(kind) = self.growth_kind(state) {
            match self.decide_growth(|e| e.plan_bone_meal(kind, pos, state)) {
                None => return PASS,
                Some(Some(plan)) => return self.grow_by_bone_meal(kind, pos, plan),
                Some(None) => {}
            }
        }
        match face {
            Some(face) if self.rules.growth.is_some() => {
                self.water_bone_meal(pos, state, face, corals)
            }
            _ => PASS,
        }
    }

    fn grow_by_bone_meal(&mut self, kind: Kind, pos: [i32; 3], plan: Plan) -> i32 {
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

    /// A mob's edit of the block at `pos` (`Action::Edit`, VMC-043c): only
    /// while it holds `from`. Whether it changed.
    pub fn mob_edit(
        &mut self,
        pos: [i32; 3],
        from: u16,
        to: Option<u16>,
        event: Option<i32>,
    ) -> i32 {
        if !self.world.owns(pos) || self.world.get(pos) != from {
            return 0;
        }
        match to {
            Some(to) => {
                if let Some(data) = event {
                    self.event(pos, super::fluid::BREAK, data);
                }
                i32::from(self.set_block(pos, to, CLIENTS, UPDATE_LIMIT))
            }
            None => i32::from(self.destroy(pos, false, UPDATE_LIMIT)),
        }
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
    pub(super) fn decide_growth<T>(&mut self, decide: impl FnOnce(&mut Self) -> T) -> Option<T> {
        let mark = self.world.begin();
        let decision = decide(self);
        if self.world.crossed(mark) {
            self.report.stopped += 1;
            None
        } else {
            Some(decision)
        }
    }

    pub(super) fn apply_growth(&mut self, plan: Plan) -> i32 {
        for (p, s, flags) in plan.writes {
            self.set_block(p, s, flags, UPDATE_LIMIT);
        }
        if plan.tree {
            GROW_TREE
        } else if plan.pop {
            POP
        } else {
            PASS
        }
    }

    fn plan_tick(&mut self, kind: Kind, pos: [i32; 3], state: u16, rain: bool) -> Plan {
        let table = self.rules.table.clone();
        let table = table.as_ref();
        let above = offset(pos, 0, 1, 0);
        match kind {
            Kind::Crop { max, skip, .. } => {
                let age = int(table, state, "age");
                // A grown crop does not tick at all.
                if age >= max || (skip && self.world.next_int(3) == 0) {
                    return Plan::default();
                }
                if self.raw_brightness(pos, 0) >= 9 {
                    let speed = self.growth_speed(state, pos);
                    if self.world.next_int((25.0f32 / speed) as i32 + 1) == 0 {
                        return Plan::set(pos, crop_age(table, kind, state, age + 1), CLIENTS);
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
                        ..Plan::default()
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
                        ..Plan::default()
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
            _ => self.plant_tick(kind, pos, state),
        }
    }

    /// `SaplingBlock.advanceTree`: the next stage, or the tree.
    fn advance_tree(&mut self, pos: [i32; 3], state: u16) -> Plan {
        let table = self.rules.table.as_ref();
        if int(table, state, "stage") == 0 {
            Plan::set(pos, with_int(table, state, "stage", 1), QUIET)
        } else {
            Plan::grow()
        }
    }

    /// Bone meal's decision: `None` when the block is not a target.
    fn plan_bone_meal(&mut self, kind: Kind, pos: [i32; 3], state: u16) -> Option<Plan> {
        let table = self.rules.table.clone();
        let table = table.as_ref();
        match kind {
            Kind::Crop { max, increase, .. } => {
                let age = int(table, state, "age");
                if age >= max {
                    return None;
                }
                let grow = match increase {
                    Increase::Random => two_to_five(&mut |b| self.world.next_int(b)),
                    Increase::Third => two_to_five(&mut |b| self.world.next_int(b)) / 3,
                    Increase::One => 1,
                };
                let age = max.min(age + grow);
                Some(Plan::set(pos, crop_age(table, kind, state, age), CLIENTS))
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
            _ => self.plant_bone_meal(kind, pos, state),
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
    pub(super) fn growth_speed(&mut self, state: u16, pos: [i32; 3]) -> f32 {
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
