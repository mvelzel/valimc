//! Vanilla's features step (VMC-025): the decoration registry (features,
//! placed features, vanilla's feature order per step, each biome's features),
//! the features themselves and `ChunkGenerator.applyBiomeDecoration`.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use super::blocks::{
    BlockSet, BlockTable, Heightmap, DOUBLE_PLANT, FLUID_WATER, LIQUID, LIQUID_BLOCK, MOSSY_CARPET,
    REPLACEABLE, SOLID, STURDY,
};
use super::javahash::JavaHashSet;
use super::json::Json;
use super::placement::{Modifier, PlacedFeature};
use super::predicate::{offset, BlockPredicate, RuleTest};
use super::providers::{GenContext, IntProvider, Weighted};
use super::random::Random;
use super::region::Region;
use super::state_provider::{self, StateProvider};
use super::surface::{temperature, BiomeClimate};
use crate::rules::Rules;

const DIRECTIONS: [[i32; 3]; 6] = [
    [0, -1, 0],
    [0, 1, 0],
    [0, 0, -1],
    [0, 0, 1],
    [-1, 0, 0],
    [1, 0, 0],
];

#[derive(Debug)]
pub enum Feature {
    /// `BlockPileFeature` (VMC-025f: villages' hay, melon, pumpkin, snow and
    /// ice piles).
    BlockPile {
        provider: Arc<StateProvider>,
    },
    Ore {
        targets: Vec<(RuleTest, u16)>,
        size: i32,
        discard_on_air: f32,
    },
    Disk {
        provider: Arc<StateProvider>,
        target: BlockPredicate,
        radius: IntProvider,
        half_height: i32,
    },
    Spring {
        state: u16,
        fluid: u8,
        requires_block_below: bool,
        rock_count: i32,
        hole_count: i32,
        valid: BlockSet,
    },
    SimpleBlock {
        provider: Arc<StateProvider>,
        schedule_tick: bool,
    },
    RandomSelector {
        features: Vec<(Arc<PlacedFeature>, f32)>,
        default: Arc<PlacedFeature>,
    },
    SimpleRandomSelector(Vec<Arc<PlacedFeature>>),
    WeightedRandomSelector(Weighted<Arc<PlacedFeature>>),
    RandomBooleanSelector(Arc<PlacedFeature>, Arc<PlacedFeature>),
    Sequence(Vec<Arc<PlacedFeature>>),
    BlockColumn {
        layers: Vec<(IntProvider, Arc<StateProvider>)>,
        step: [i32; 3],
        allowed: BlockPredicate,
        prioritize_tip: bool,
    },
    Lake {
        fluid: Arc<StateProvider>,
        barrier: Arc<StateProvider>,
        can_place: BlockPredicate,
        can_replace_with_air_or_fluid: BlockPredicate,
        can_replace_with_barrier: BlockPredicate,
    },
    FreezeTopLayer,
    BlueIce,
    BlockBlob {
        state: u16,
        can_place_on: BlockPredicate,
    },
    Tree(Box<super::tree::Tree>),
    VegetationPatch(Box<VegetationPatch>),
    FallenTree(Box<super::tree::FallenTree>),
    HugeMushroom(Box<super::plants::HugeMushroom>),
    Bamboo(super::plants::Bamboo),
    RootSystem(Box<super::plants::RootSystem>),
    Vines(super::plants::Vines),
    CoralTree(super::plants::CoralTree),
    CoralClaw(super::plants::CoralClaw),
    Iceberg(Box<super::formations::Iceberg>),
    Spike(Box<super::formations::Spike>),
    Geode(Box<super::formations::Geode>),
    UnderwaterMagma(Box<super::formations::UnderwaterMagma>),
    MonsterRoom(Box<super::formations::MonsterRoom>),
    LargeDripstone(Box<super::speleothem::LargeDripstone>),
    SpeleothemCluster(Box<super::speleothem::SpeleothemCluster>),
    Speleothem(Box<super::speleothem::Speleothem>),
    MultifaceGrowth(Box<super::sculk::MultifaceGrowth>),
    SculkPatch(Box<super::sculk::SculkPatch>),
    Template(Box<super::template::TemplateFeature>),
    Fossil(Box<super::template::Fossil>),
    Overlay(Vec<Arc<PlacedFeature>>),
    Delta(Box<super::nether::Delta>),
    SteppedColumnCluster(Box<super::nether::SteppedColumnCluster>),
    SingleBlockPillar(Box<super::nether::SingleBlockPillar>),
    PatchySquare(Box<super::nether::PatchySquare>),
    ReplaceBlobs(super::nether::ReplaceBlobs),
    NeighborSpread(Box<super::nether::NeighborSpread>),
    HugeFungus(Box<super::nether::HugeFungus>),
    ScatteredOre(super::nether::ScatteredOre),
    EndIsland,
    EndSpikes(super::end::EndSpikes),
    EndGateway(super::end::EndGateway),
    EndPlatform,
    ChorusPlant,
    NoOp,
    /// A feature type this slice does not implement; placing it fails.
    Unsupported(String),
}

/// States and blocks features name directly.
#[derive(Debug)]
pub(crate) struct Known {
    cave_air: u16,
    water: u16,
    ice: u16,
    snow: u16,
    blue_ice: u16,
    pub(crate) water_block: u16,
    packed_ice_block: u16,
    ice_block: u16,
    blue_ice_block: u16,
    snow_block: u16,
    pub(crate) bedrock_block: u16,
    pub(crate) lava_block: u16,
    pub(crate) end_stone: u16,
    pub(crate) obsidian: u16,
    pub(crate) bedrock: u16,
    pub(crate) iron_bars: u16,
    pub(crate) end_gateway: u16,
}

pub struct Decoration {
    pub table: Arc<BlockTable>,
    /// The dimension's build bounds (bottom, height) its chunks have.
    pub dimension: (i32, i32),
    pub rules: Arc<Rules>,
    templates: Option<Arc<super::template::Templates>>,
    pub features: HashMap<String, Arc<Feature>>,
    pub placed: HashMap<String, Arc<PlacedFeature>>,
    /// Per step, the placed features in vanilla's order (`FeatureSorter`),
    /// whose index seeds each feature.
    pub order: Vec<Vec<Arc<PlacedFeature>>>,
    /// Per biome registry id: per step, the global indices of its placed
    /// features; and all of them (`hasFeature`) as bits by placed feature key.
    biome_steps: Vec<Vec<Vec<usize>>>,
    biome_features: Vec<Vec<u64>>,
    /// The biome source's biomes (`possibleBiomes`).
    source_biomes: Vec<bool>,
    climates: Vec<BiomeClimate>,
    precipitation: Vec<bool>,
    context: GenContext,
    known: Arc<Known>,
}

impl std::fmt::Debug for Decoration {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Decoration({} features, {} placed features, {} steps)",
            self.features.len(),
            self.placed.len(),
            self.order.len()
        )
    }
}

/// Lazily parsed registry entries.
struct Parser<'a> {
    table: &'a BlockTable,
    templates: Option<&'a super::template::Templates>,
    features_json: &'a Json,
    placed_json: &'a Json,
    providers_json: &'a Json,
    features: HashMap<String, Arc<Feature>>,
    placed: HashMap<String, Arc<PlacedFeature>>,
    /// Dense keys of registry placed features, for biome checks.
    keys: HashMap<String, u32>,
    providers: std::cell::RefCell<HashMap<String, Arc<StateProvider>>>,
}

impl<'a> Parser<'a> {
    fn provider(&self, json: &Json) -> Result<Arc<StateProvider>, String> {
        let registry = |id: &str| -> Result<Arc<StateProvider>, String> {
            if let Some(p) = self.providers.borrow().get(id) {
                return Ok(p.clone());
            }
            let entry = self
                .providers_json
                .get(id)
                .ok_or_else(|| format!("no state provider {id}"))?;
            let p = self.provider(entry)?;
            self.providers
                .borrow_mut()
                .insert(id.to_string(), p.clone());
            Ok(p)
        };
        state_provider::parse(json, self.table, &registry)
    }

    fn feature(&mut self, json: &Json) -> Result<Arc<Feature>, String> {
        if let Json::String(id) = json {
            if let Some(f) = self.features.get(id) {
                return Ok(f.clone());
            }
            let entry = self
                .features_json
                .get(id)
                .ok_or_else(|| format!("no feature {id}"))?;
            let f = self
                .feature_body(entry)
                .map_err(|e| format!("feature {id}: {e}"))?;
            self.features.insert(id.clone(), f.clone());
            return Ok(f);
        }
        self.feature_body(json)
    }

    fn placed(&mut self, json: &Json) -> Result<Arc<PlacedFeature>, String> {
        if let Json::String(id) = json {
            if let Some(p) = self.placed.get(id) {
                return Ok(p.clone());
            }
            let entry = self
                .placed_json
                .get(id)
                .ok_or_else(|| format!("no placed feature {id}"))?;
            let p = self
                .placed_body(entry, Some(id.clone()))
                .map_err(|e| format!("placed feature {id}: {e}"))?;
            self.placed.insert(id.clone(), p.clone());
            return Ok(p);
        }
        self.placed_body(json, None)
    }

    fn placed_body(
        &mut self,
        json: &Json,
        id: Option<String>,
    ) -> Result<Arc<PlacedFeature>, String> {
        let feature = self.feature(json.field("feature")?)?;
        let placement = json
            .field("placement")?
            .as_array()?
            .iter()
            .map(|m| Modifier::parse(m, self.table))
            .collect::<Result<_, _>>()?;
        let key = id.as_ref().map(|id| {
            let next = self.keys.len() as u32;
            *self.keys.entry(id.clone()).or_insert(next)
        });
        Ok(Arc::new(PlacedFeature {
            id,
            key,
            feature,
            placement,
        }))
    }

    /// A feature; one this slice cannot parse (a part of a type it does not
    /// implement) becomes unsupported, failing only when placed.
    fn feature_body(&mut self, json: &Json) -> Result<Arc<Feature>, String> {
        match self.feature_parse(json) {
            Ok(feature) => Ok(feature),
            Err(e) => Ok(Arc::new(Feature::Unsupported(format!(
                "{}: {e}",
                json.get("type")
                    .and_then(|t| t.as_str().ok())
                    .unwrap_or("?")
            )))),
        }
    }

    fn feature_parse(&mut self, json: &Json) -> Result<Arc<Feature>, String> {
        let table = self.table;
        let kind = json.field("type")?.as_str()?;
        let i = |k: &str| json.field(k)?.as_i32();
        let feature = match kind {
            "minecraft:ore" => {
                let (targets, size, discard_on_air) = ore_config(json, table)?;
                Feature::Ore {
                    targets,
                    size,
                    discard_on_air,
                }
            }
            "minecraft:disk" => Feature::Disk {
                provider: self.provider(json.field("state_provider")?)?,
                target: BlockPredicate::parse(json.field("target")?, table)?,
                radius: IntProvider::parse(json.field("radius")?)?,
                half_height: i("half_height")?,
            },
            "minecraft:spring_feature" => {
                let (state, fluid) = table.fluid_state(json.field("state")?)?;
                Feature::Spring {
                    state,
                    fluid,
                    requires_block_below: json
                        .get("requires_block_below")
                        .map_or(Ok(true), Json::as_bool)?,
                    rock_count: json.get("rock_count").map_or(Ok(4), Json::as_i32)?,
                    hole_count: json.get("hole_count").map_or(Ok(1), Json::as_i32)?,
                    valid: table.block_set(json.field("valid_blocks")?)?,
                }
            }
            "minecraft:block_pile" => Feature::BlockPile {
                provider: self.provider(json.field("state_provider")?)?,
            },
            "minecraft:simple_block" => Feature::SimpleBlock {
                provider: self.provider(json.field("to_place")?)?,
                schedule_tick: json.get("schedule_tick").map_or(Ok(false), Json::as_bool)?,
            },
            "minecraft:random_selector" => Feature::RandomSelector {
                features: json
                    .field("features")?
                    .as_array()?
                    .iter()
                    .map(|w| {
                        Ok((
                            self.placed(w.field("feature")?)?,
                            w.field("chance")?.as_f64()? as f32,
                        ))
                    })
                    .collect::<Result<_, String>>()?,
                default: self.placed(json.field("default")?)?,
            },
            "minecraft:simple_random_selector" => {
                Feature::SimpleRandomSelector(self.placed_list(json.field("features")?)?)
            }
            "minecraft:weighted_random_selector" => {
                let mut entries = Vec::new();
                let mut total = 0;
                for entry in json.field("features")?.as_array()? {
                    let weight = entry.field("weight")?.as_i32()?;
                    total += weight;
                    entries.push((self.placed(entry.field("data")?)?, weight));
                }
                Feature::WeightedRandomSelector(Weighted { entries, total })
            }
            "minecraft:random_boolean_selector" => Feature::RandomBooleanSelector(
                self.placed(json.field("feature_true")?)?,
                self.placed(json.field("feature_false")?)?,
            ),
            "minecraft:sequence" => Feature::Sequence(self.placed_list(json.field("features")?)?),
            "minecraft:block_column" => Feature::BlockColumn {
                layers: json
                    .field("layers")?
                    .as_array()?
                    .iter()
                    .map(|l| {
                        Ok((
                            IntProvider::parse(l.field("height")?)?,
                            self.provider(l.field("provider")?)?,
                        ))
                    })
                    .collect::<Result<_, String>>()?,
                step: super::predicate::direction(json.field("direction")?.as_str()?)?.1,
                allowed: BlockPredicate::parse(json.field("allowed_placement")?, table)?,
                prioritize_tip: json.field("prioritize_tip")?.as_bool()?,
            },
            "minecraft:lake" => Feature::Lake {
                fluid: self.provider(json.field("fluid")?)?,
                barrier: self.provider(json.field("barrier")?)?,
                can_place: match json.get("can_place_feature") {
                    Some(p) => BlockPredicate::parse(p, table)?,
                    None => BlockPredicate::True,
                },
                can_replace_with_air_or_fluid: BlockPredicate::parse(
                    json.field("can_replace_with_air_or_fluid")?,
                    table,
                )?,
                can_replace_with_barrier: BlockPredicate::parse(
                    json.field("can_replace_with_barrier")?,
                    table,
                )?,
            },
            "minecraft:freeze_top_layer" => Feature::FreezeTopLayer,
            "minecraft:blue_ice" => Feature::BlueIce,
            "minecraft:block_blob" => Feature::BlockBlob {
                state: table.state(json.field("state")?)?,
                can_place_on: BlockPredicate::parse(json.field("can_place_on")?, table)?,
            },
            "minecraft:vegetation_patch" | "minecraft:waterlogged_vegetation_patch" => {
                Feature::VegetationPatch(Box::new(VegetationPatch {
                    replaceable: table.block_set(json.field("replaceable")?)?,
                    ground: self.provider(json.field("ground_state")?)?,
                    vegetation: self.placed(json.field("vegetation_feature")?)?,
                    ceiling: match json.field("surface")?.as_str()? {
                        "floor" => false,
                        "ceiling" => true,
                        other => return Err(format!("unknown cave surface {other}")),
                    },
                    depth: IntProvider::parse(json.field("depth")?)?,
                    extra_bottom: json.field("extra_bottom_block_chance")?.as_f64()? as f32,
                    vertical_range: i("vertical_range")?,
                    vegetation_chance: json.field("vegetation_chance")?.as_f64()? as f32,
                    xz_radius: IntProvider::parse(json.field("xz_radius")?)?,
                    extra_edge: json.field("extra_edge_column_chance")?.as_f64()? as f32,
                    waterlogged: kind == "minecraft:waterlogged_vegetation_patch",
                }))
            }
            "minecraft:fallen_tree" => {
                let mut provider = |j: &Json| self.provider(j);
                Feature::FallenTree(Box::new(super::tree::FallenTree::parse(
                    json,
                    &mut provider,
                )?))
            }
            "minecraft:huge_red_mushroom" | "minecraft:huge_brown_mushroom" => {
                let mut provider = |j: &Json| self.provider(j);
                Feature::HugeMushroom(Box::new(super::plants::HugeMushroom::parse(
                    json,
                    table,
                    kind == "minecraft:huge_red_mushroom",
                    &mut provider,
                )?))
            }
            "minecraft:bamboo" => Feature::Bamboo(super::plants::Bamboo::parse(json, table)?),
            "minecraft:root_system" => {
                let tree = self.placed(json.field("feature")?)?;
                let mut provider = |j: &Json| self.provider(j);
                Feature::RootSystem(Box::new(super::plants::RootSystem::parse(
                    json,
                    table,
                    tree,
                    &mut provider,
                )?))
            }
            "minecraft:vines" => Feature::Vines(super::plants::Vines::new(table)?),
            "minecraft:coral_tree" => Feature::CoralTree(super::plants::CoralTree::new(
                self.placed(json.field("feature")?)?,
            )),
            "minecraft:coral_claw" => Feature::CoralClaw(super::plants::CoralClaw::new(
                self.placed(json.field("feature")?)?,
            )),
            "minecraft:iceberg" => {
                Feature::Iceberg(Box::new(super::formations::Iceberg::parse(json, table)?))
            }
            "minecraft:spike" => {
                Feature::Spike(Box::new(super::formations::Spike::parse(json, table)?))
            }
            "minecraft:geode" => {
                let mut provider = |j: &Json| self.provider(j);
                Feature::Geode(Box::new(super::formations::Geode::parse(
                    json,
                    table,
                    &mut provider,
                )?))
            }
            "minecraft:underwater_magma" => Feature::UnderwaterMagma(Box::new(
                super::formations::UnderwaterMagma::parse(json, table)?,
            )),
            "minecraft:monster_room" => {
                Feature::MonsterRoom(Box::new(super::formations::MonsterRoom::new(table)?))
            }
            "minecraft:large_dripstone" => Feature::LargeDripstone(Box::new(
                super::speleothem::LargeDripstone::parse(json, table)?,
            )),
            "minecraft:speleothem_cluster" => Feature::SpeleothemCluster(Box::new(
                super::speleothem::SpeleothemCluster::parse(json, table)?,
            )),
            "minecraft:speleothem" => {
                Feature::Speleothem(Box::new(super::speleothem::Speleothem::parse(json, table)?))
            }
            "minecraft:multiface_growth" => Feature::MultifaceGrowth(Box::new(
                super::sculk::MultifaceGrowth::parse(json, table)?,
            )),
            "minecraft:sculk_patch" => {
                Feature::SculkPatch(Box::new(super::sculk::SculkPatch::parse(json, table)?))
            }
            "minecraft:template" => {
                let templates = self.templates.ok_or("no structure templates")?;
                Feature::Template(Box::new(super::template::TemplateFeature::parse(
                    json, table, templates,
                )?))
            }
            "minecraft:fossil" => {
                let templates = self.templates.ok_or("no structure templates")?;
                Feature::Fossil(Box::new(super::template::Fossil::parse(
                    json, table, templates,
                )?))
            }
            "minecraft:overlay" => Feature::Overlay(self.placed_list(json.field("features")?)?),
            "minecraft:delta_feature" => {
                Feature::Delta(Box::new(super::nether::Delta::parse(json, table)?))
            }
            "minecraft:stepped_column_cluster" => {
                let mut provider = |j: &Json| self.provider(j);
                Feature::SteppedColumnCluster(Box::new(super::nether::SteppedColumnCluster::parse(
                    json,
                    table,
                    &mut provider,
                )?))
            }
            "minecraft:single_block_pillar" => {
                let cap = json
                    .get("cap_feature")
                    .map(|c| self.placed(c))
                    .transpose()?;
                let mut provider = |j: &Json| self.provider(j);
                Feature::SingleBlockPillar(Box::new(super::nether::SingleBlockPillar::parse(
                    json,
                    table,
                    &mut provider,
                    cap,
                )?))
            }
            "minecraft:projected_random_patchy_square" => {
                let mut provider = |j: &Json| self.provider(j);
                Feature::PatchySquare(Box::new(super::nether::PatchySquare::parse(
                    json,
                    table,
                    &mut provider,
                )?))
            }
            "minecraft:netherrack_replace_blobs" => {
                Feature::ReplaceBlobs(super::nether::ReplaceBlobs::parse(json, table)?)
            }
            "minecraft:random_neighbor_spread" => {
                let mut provider = |j: &Json| self.provider(j);
                Feature::NeighborSpread(Box::new(super::nether::NeighborSpread::parse(
                    json,
                    table,
                    &mut provider,
                )?))
            }
            "minecraft:huge_fungus" => {
                Feature::HugeFungus(Box::new(super::nether::HugeFungus::parse(json, table)?))
            }
            "minecraft:scattered_ore" => {
                let (targets, size, discard) = ore_config(json, table)?;
                Feature::ScatteredOre(super::nether::ScatteredOre::new(targets, size, discard))
            }
            "minecraft:end_island" => Feature::EndIsland,
            "minecraft:end_spike" => Feature::EndSpikes(super::end::EndSpikes::parse(json)?),
            "minecraft:end_gateway" => Feature::EndGateway(super::end::EndGateway::parse(json)?),
            "minecraft:end_platform" => Feature::EndPlatform,
            "minecraft:chorus_plant" => Feature::ChorusPlant,
            "minecraft:no_op" => Feature::NoOp,
            "minecraft:tree" => {
                let mut provider = |j: &Json| self.provider(j);
                Feature::Tree(Box::new(super::tree::Tree::parse(
                    json,
                    table,
                    &mut provider,
                )?))
            }
            other => Feature::Unsupported(other.to_string()),
        };
        Ok(Arc::new(feature))
    }

    fn placed_list(&mut self, json: &Json) -> Result<Vec<Arc<PlacedFeature>>, String> {
        match json {
            Json::Array(items) => items.iter().map(|p| self.placed(p)).collect(),
            other => Ok(vec![self.placed(other)?]),
        }
    }
}

/// An ore feature's targets, size and discard chance on air exposure
/// (`AbstractOreFeature`).
type OreConfig = (Vec<(RuleTest, u16)>, i32, f32);

fn ore_config(json: &Json, table: &BlockTable) -> Result<OreConfig, String> {
    let targets = json
        .field("targets")?
        .as_array()?
        .iter()
        .map(|t| {
            Ok((
                RuleTest::parse(t.field("target")?, table)?,
                table.state(t.field("state")?)?,
            ))
        })
        .collect::<Result<_, String>>()?;
    let discard = match json.get("discard_chance_on_air_exposure") {
        Some(v) => v.as_f64()? as f32,
        None => 0.0,
    };
    Ok((targets, json.field("size")?.as_i32()?, discard))
}

/// The inputs `Decoration::parse` reads.
pub struct DecorationFacts<'a> {
    pub features: &'a Json,
    pub placed_features: &'a Json,
    pub block_state_providers: &'a Json,
    /// Vanilla's feature order for the biome source.
    pub order: &'a Json,
    pub biomes: &'a Json,
    /// The block rules, and structure templates when given (shared by every
    /// biome source's decoration).
    pub rules: Arc<Rules>,
    pub templates: Option<Arc<super::template::Templates>>,
    /// Biome registry ids by name, and the biome source's biomes.
    pub biome_ids: &'a dyn Fn(&str) -> Result<u16, String>,
    pub biome_count: usize,
    pub source_biomes: &'a [u16],
    pub climates: Vec<BiomeClimate>,
    /// Placed features to parse besides the order's: those jigsaw pools
    /// place (VMC-025f).
    pub extra_placed: &'a [String],
}

impl Decoration {
    pub fn parse(
        table: Arc<BlockTable>,
        facts: DecorationFacts,
        context: GenContext,
        dimension: (i32, i32),
    ) -> Result<Decoration, String> {
        let rules = facts.rules;
        let templates = facts.templates;
        let mut parser = Parser {
            table: &table,
            templates: templates.as_deref(),
            features_json: facts.features,
            placed_json: facts.placed_features,
            providers_json: facts.block_state_providers,
            features: HashMap::new(),
            placed: HashMap::new(),
            keys: HashMap::new(),
            providers: std::cell::RefCell::new(HashMap::new()),
        };
        let mut order = Vec::new();
        let mut index_of: HashMap<String, (usize, usize)> = HashMap::new();
        for (step, ids) in facts.order.as_array()?.iter().enumerate() {
            let mut list = Vec::new();
            for (index, id) in ids.as_array()?.iter().enumerate() {
                let id = id.as_str()?;
                list.push(parser.placed(&Json::String(id.to_string()))?);
                index_of.insert(id.to_string(), (step, index));
            }
            order.push(list);
        }
        for id in facts.extra_placed {
            parser.placed(&Json::String(id.clone()))?;
        }
        // A sapling grows any tree, placed by a biome or not (VMC-039a).
        for (id, feature) in facts.features.entries()? {
            if feature.get("type").and_then(|t| t.as_str().ok()) == Some("minecraft:tree") {
                parser.feature(&Json::String(id.clone()))?;
            }
        }
        let mut biome_steps = vec![Vec::new(); facts.biome_count];
        let mut biome_features = vec![Vec::new(); facts.biome_count];
        let mut precipitation = vec![true; facts.biome_count];
        for (name, biome) in facts.biomes.entries()? {
            let id = (facts.biome_ids)(name)? as usize;
            precipitation[id] = biome
                .get("has_precipitation")
                .map_or(Ok(true), Json::as_bool)?;
            let Some(steps) = biome.get("features") else {
                continue;
            };
            for (step, list) in steps.as_array()?.iter().enumerate() {
                let mut indices = Vec::new();
                for placed in list.as_array()? {
                    let placed = placed.as_str()?;
                    // Placed features the order does not name never take a
                    // biome check here.
                    if let Some(&key) = parser.keys.get(placed) {
                        let bits: &mut Vec<u64> = &mut biome_features[id];
                        let word = key as usize / 64;
                        if bits.len() <= word {
                            bits.resize(word + 1, 0);
                        }
                        bits[word] |= 1 << (key % 64);
                    }
                    if let Some(&(s, index)) = index_of.get(placed) {
                        if s == step {
                            indices.push(index);
                        }
                    }
                }
                biome_steps[id].push(indices);
            }
        }
        let mut source_biomes = vec![false; facts.biome_count];
        for &b in facts.source_biomes {
            source_biomes[b as usize] = true;
        }
        let known = Known {
            cave_air: table.default_state("cave_air")?,
            water: table.default_state("water")?,
            ice: table.default_state("ice")?,
            snow: table.default_state("snow")?,
            blue_ice: table.default_state("blue_ice")?,
            water_block: table.block("water")?,
            packed_ice_block: table.block("packed_ice")?,
            ice_block: table.block("ice")?,
            blue_ice_block: table.block("blue_ice")?,
            snow_block: table.block("snow")?,
            bedrock_block: table.block("bedrock")?,
            lava_block: table.block("lava")?,
            end_stone: table.default_state("end_stone")?,
            obsidian: table.default_state("obsidian")?,
            bedrock: table.default_state("bedrock")?,
            iron_bars: table.default_state("iron_bars")?,
            end_gateway: table.default_state("end_gateway")?,
        };
        // Trees' pale moss decorator places this feature by name.
        if facts.features.get("minecraft:pale_moss_patch").is_some() {
            parser.feature(&Json::String("minecraft:pale_moss_patch".into()))?;
        }
        let features = std::mem::take(&mut parser.features);
        let placed = std::mem::take(&mut parser.placed);
        drop(parser);
        Ok(Decoration {
            table,
            dimension,
            rules,
            templates,
            features,
            placed,
            order,
            biome_steps,
            biome_features,
            source_biomes,
            climates: facts.climates,
            precipitation,
            context,
            known: Arc::new(known),
        })
    }

    pub fn context(&self) -> GenContext {
        self.context
    }

    pub(crate) fn known(&self) -> &Known {
        &self.known
    }

    /// Whether `biome` is one of the biome source's biomes.
    pub fn has_source_biome(&self, biome: u16) -> bool {
        self.source_biomes.get(biome as usize) == Some(&true)
    }

    /// The decoration of a fixed biome source over `biome`, one of this
    /// source's biomes (VMC-028b, `FixedBiomeSource`): `FeatureSorter` over the
    /// one biome orders each step as the biome lists it, so a placed
    /// feature's index (its seed) is its place in that list.
    pub fn fixed(&self, biome: u16) -> Result<Decoration, String> {
        let b = biome as usize;
        if !self.has_source_biome(biome) {
            return Err(format!("biome {biome} is not one of the source's biomes"));
        }
        let steps = &self.biome_steps[b];
        let order: Vec<Vec<Arc<PlacedFeature>>> = (0..self.order.len())
            .map(|s| {
                steps.get(s).map_or_else(Vec::new, |indices| {
                    indices.iter().map(|&i| self.order[s][i].clone()).collect()
                })
            })
            .collect();
        let mut biome_steps = vec![Vec::new(); self.biome_steps.len()];
        biome_steps[b] = order.iter().map(|list| (0..list.len()).collect()).collect();
        let mut source_biomes = vec![false; self.source_biomes.len()];
        source_biomes[b] = true;
        Ok(Decoration {
            table: self.table.clone(),
            dimension: self.dimension,
            rules: self.rules.clone(),
            templates: self.templates.clone(),
            features: self.features.clone(),
            placed: self.placed.clone(),
            order,
            biome_steps,
            biome_features: self.biome_features.clone(),
            source_biomes,
            climates: self.climates.clone(),
            precipitation: self.precipitation.clone(),
            context: self.context,
            known: self.known.clone(),
        })
    }

    /// The structure templates features place.
    pub fn templates(&self) -> Result<&super::template::Templates, String> {
        self.templates
            .as_deref()
            .ok_or_else(|| "no structure templates".into())
    }

    /// `state.canSurvive(level, pos)` in decoration's light.
    pub fn survives(&self, region: &mut Region, state: u16, pos: [i32; 3]) -> bool {
        self.rules.survives(region, state, pos)
    }

    /// `state.updateShape(level, level, pos, d, …)` through the region (the
    /// cell at `replaced` reads as its given state): the new state, with the
    /// ticks it schedules (`Rules::update_shape`).
    pub fn update_shape(
        &self,
        region: &mut Region,
        state: u16,
        pos: [i32; 3],
        d: usize,
        replaced: Option<([i32; 3], u16)>,
    ) -> Result<u16, String> {
        self.rules.update_shape(region, state, pos, d, replaced)
    }

    /// Shape update parity cases (VMC-026a, `ShapeOracle code`): per case a
    /// state, a direction and its neighbours (offset, state; air elsewhere),
    /// updated at the centre of an otherwise empty chunk. Per case the new
    /// state and the ticks scheduled (offset, fluid, id).
    #[allow(clippy::type_complexity)]
    pub fn shape_cases(
        &self,
        cases: &[(u16, usize, Vec<([i32; 3], u16)>)],
    ) -> Result<Vec<(u16, Vec<([i32; 3], bool, u16)>)>, String> {
        let (min_y, height) = (-64, 384);
        let air = self.table.default_state("air")?;
        let chunk = super::region::ProtoChunk::new(
            0,
            0,
            (min_y, height),
            vec![air; 256 * height as usize],
            Arc::new(vec![0; (height / 16 * 64) as usize]),
            &self.table,
        );
        let mut area = super::region::Area::of(vec![chunk])?;
        let origin = [8, 64, 8];
        let mut out = Vec::with_capacity(cases.len());
        for (state, d, cells) in cases {
            let mut region = Region::new(&mut area, &self.table, (0, 0), 0, 0, 63)?;
            for (o, cell) in cells {
                region.set_raw(offset(origin, *o), *cell);
            }
            let new_state = self.update_shape(&mut region, *state, origin, *d, None)?;
            for (o, _) in cells {
                region.set_raw(offset(origin, *o), air);
            }
            let chunk = area.chunks[0].as_mut().ok_or("the case's chunk")?;
            let relative = |p: [i32; 3]| [p[0] - origin[0], p[1] - origin[1], p[2] - origin[2]];
            let mut ticks: Vec<_> = chunk
                .block_ticks
                .iter()
                .map(|(p, b)| (relative(*p), false, *b))
                .chain(
                    chunk
                        .fluid_ticks
                        .iter()
                        .map(|(p, f)| (relative(*p), true, *f as u16)),
                )
                .collect();
            ticks.sort_unstable();
            chunk.block_ticks.clear();
            chunk.fluid_ticks.clear();
            out.push((new_state, ticks));
        }
        Ok(out)
    }

    /// `BiomeGenerationSettings.hasFeature`, by placed feature key.
    pub fn biome_has_feature(&self, biome: u16, key: u32) -> bool {
        self.biome_features
            .get(biome as usize)
            .and_then(|bits| bits.get(key as usize / 64))
            .is_some_and(|word| word & (1 << (key % 64)) != 0)
    }

    fn temperature(&self, biome: u16, pos: [i32; 3]) -> f32 {
        temperature(
            &self.climates[biome as usize],
            pos[0],
            pos[1],
            pos[2],
            self.context.sea_level,
        )
    }

    /// `Biome.shouldFreeze(level, pos, false)`: cold, block light below 10
    /// (none while decorating), a water source block.
    fn should_freeze(&self, region: &mut Region, biome: u16, pos: [i32; 3]) -> bool {
        if self.temperature(biome, pos) >= 0.15 {
            return false;
        }
        if region.is_outside_build_height(pos[1]) {
            return false;
        }
        let state = region.get(pos);
        self.table.fluid(state) == FLUID_WATER && self.table.flag(state, LIQUID_BLOCK)
    }

    /// `Biome.shouldSnow`.
    fn should_snow(&self, region: &mut Region, biome: u16, pos: [i32; 3]) -> bool {
        if !self.precipitation[biome as usize] || self.temperature(biome, pos) >= 0.15 {
            return false;
        }
        if region.is_outside_build_height(pos[1]) {
            return false;
        }
        let state = region.get(pos);
        (self.table.is_air(state) || self.table.block_of(state) == self.known.snow_block)
            && self.survives(region, self.known.snow, pos)
    }

    /// `Feature.markAboveForPostProcessing`.
    pub(crate) fn mark_above(&self, region: &mut Region, pos: [i32; 3]) {
        let mut p = pos;
        for _ in 0..2 {
            p[1] += 1;
            if region.is_air_at(p) {
                return;
            }
            region.mark(p);
        }
    }

    /// `ChunkGenerator.applyBiomeDecoration` for the chunk at the region's
    /// centre, without structures; `included` limits the placed features
    /// (by step and global index) when set.
    pub fn decorate(
        &self,
        region: &mut Region,
        included: Option<&HashSet<(usize, usize)>>,
    ) -> Result<(), String> {
        self.decorate_with(region, included, None)
    }

    /// `decorate` with structures (VMC-025f): every step, the eleven of
    /// `GenerationStep.Decoration` at least, first places its structures
    /// through `structures` (given the step, the decoration random and
    /// seed), then its features.
    pub fn decorate_with(
        &self,
        region: &mut Region,
        included: Option<&HashSet<(usize, usize)>>,
        mut structures: Option<&mut StructureStep>,
    ) -> Result<(), String> {
        let (cx, cz) = region.centre;
        let origin = [cx * 16, region.min_y(), cz * 16];
        let mut random = Random::worldgen(0);
        let decoration_seed = random.set_decoration_seed(region.seed, origin[0], origin[2]);
        let mut possible = vec![false; self.source_biomes.len()];
        for dx in -1..=1 {
            for dz in -1..=1 {
                let chunk = region
                    .area
                    .chunk(cx + dx, cz + dz)
                    .ok_or("a neighbour chunk outside the area")?;
                for &b in chunk.biomes.iter() {
                    possible[b as usize] = self.source_biomes[b as usize];
                }
            }
        }
        let steps = match structures {
            Some(_) => self.order.len().max(11),
            None => self.order.len(),
        };
        for step in 0..steps {
            if let Some(place) = structures.as_deref_mut() {
                place(step, region, &mut random, decoration_seed)?;
                if let Some(fault) = &region.fault {
                    return Err(format!("structures of step {step}: {fault}"));
                }
            }
            let Some(features) = self.order.get(step) else {
                continue;
            };
            let mut indices: Vec<usize> = Vec::new();
            for (biome, &on) in possible.iter().enumerate() {
                if on {
                    if let Some(list) = self.biome_steps[biome].get(step) {
                        indices.extend(list);
                    }
                }
            }
            indices.sort_unstable();
            indices.dedup();
            for index in indices {
                if included.is_some_and(|set| !set.contains(&(step, index))) {
                    continue;
                }
                random.set_feature_seed(decoration_seed, index as i32, step as i32);
                features[index].place(self, region, &mut random, origin, true)?;
                if let Some(fault) = &region.fault {
                    return Err(format!(
                        "{}: {fault}",
                        features[index].id.as_deref().unwrap_or("feature")
                    ));
                }
            }
        }
        Ok(())
    }
}

/// A decoration step's structure placement (see `Decoration::decorate_with`).
pub type StructureStep<'s> =
    dyn FnMut(usize, &mut Region, &mut Random, i64) -> Result<(), String> + 's;

/// `VegetationPatchFeature` and its waterlogged variant.
#[derive(Debug)]
pub struct VegetationPatch {
    replaceable: BlockSet,
    ground: Arc<StateProvider>,
    vegetation: Arc<PlacedFeature>,
    /// The surface: a ceiling grows down from above, a floor up.
    ceiling: bool,
    depth: IntProvider,
    extra_bottom: f32,
    vertical_range: i32,
    vegetation_chance: f32,
    xz_radius: IntProvider,
    extra_edge: f32,
    waterlogged: bool,
}

impl VegetationPatch {
    /// The surface's direction (`CaveSurface.getDirection`) as an index.
    fn inwards(&self) -> usize {
        if self.ceiling {
            1
        } else {
            0
        }
    }

    fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let x_radius = self.xz_radius.sample(random) + 1;
        let z_radius = self.xz_radius.sample(random) + 1;
        let mut surface = self.ground_patch(d, region, random, origin, x_radius, z_radius);
        if self.waterlogged {
            surface = self.flood(d, region, &surface);
        }
        if surface.unordered {
            return Err("a vegetation patch's position set needs identity hash order".into());
        }
        for pos in surface.iter() {
            if self.vegetation_chance > 0.0 && random.next_float() < self.vegetation_chance {
                self.place_vegetation(d, region, random, pos)?;
            }
        }
        Ok(!surface.is_empty())
    }

    fn ground_patch(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
        x_radius: i32,
        z_radius: i32,
    ) -> JavaHashSet {
        let table = d.table.as_ref();
        let inwards = DIRECTIONS[self.inwards()];
        let outwards = DIRECTIONS[self.inwards() ^ 1];
        let mut surface = JavaHashSet::new();
        for dx in -x_radius..=x_radius {
            let x_edge = dx == -x_radius || dx == x_radius;
            for dz in -z_radius..=z_radius {
                let z_edge = dz == -z_radius || dz == z_radius;
                if x_edge && z_edge {
                    continue;
                }
                if (x_edge || z_edge)
                    && (self.extra_edge == 0.0 || random.next_float() > self.extra_edge)
                {
                    continue;
                }
                let mut pos = offset(origin, [dx, 0, dz]);
                let mut steps = 0;
                while region.is_air_at(pos) && steps < self.vertical_range {
                    pos = offset(pos, inwards);
                    steps += 1;
                }
                steps = 0;
                while !region.is_air_at(pos) && steps < self.vertical_range {
                    pos = offset(pos, outwards);
                    steps += 1;
                }
                let below = offset(pos, inwards);
                let below_state = region.get(below);
                if region.is_air_at(pos) && table.flag(below_state, STURDY << (self.inwards() ^ 1))
                {
                    let depth = self.depth.sample(random);
                    let extra = self.extra_bottom > 0.0 && random.next_float() < self.extra_bottom;
                    let depth = depth + i32::from(extra);
                    if self.place_ground(d, region, random, below, depth) {
                        surface.insert(below);
                    }
                }
            }
        }
        surface
    }

    fn place_ground(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        mut pos: [i32; 3],
        depth: i32,
    ) -> bool {
        let table = d.table.as_ref();
        for i in 0..depth {
            let state = self.ground.state(d, region, random, pos);
            let current = region.get(pos);
            if table.block_of(state) != table.block_of(current) {
                if !table.in_tag(current, &self.replaceable) {
                    return i != 0;
                }
                region.set(pos, state, 2);
                pos = offset(pos, DIRECTIONS[self.inwards()]);
            }
        }
        true
    }

    /// `WaterloggedVegetationPatchFeature.placeGroundPatch`: the enclosed
    /// surface positions become water.
    fn flood(&self, d: &Decoration, region: &mut Region, surface: &JavaHashSet) -> JavaHashSet {
        let table = d.table.as_ref();
        let mut water = JavaHashSet::new();
        for pos in surface.iter() {
            // North, east, south, west, down.
            let exposed = [2, 5, 3, 4, 0].iter().any(|&dir| {
                let state = region.get(offset(pos, DIRECTIONS[dir]));
                !table.flag(state, STURDY << (dir ^ 1))
            });
            if !exposed {
                water.insert(pos);
            }
        }
        for pos in water.iter() {
            region.set(pos, d.known.water, 2);
        }
        water
    }

    fn place_vegetation(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        pos: [i32; 3],
    ) -> Result<bool, String> {
        let outwards = DIRECTIONS[self.inwards() ^ 1];
        if !self.waterlogged {
            return self
                .vegetation
                .place(d, region, random, offset(pos, outwards), false);
        }
        let at = offset(offset(pos, [0, -1, 0]), outwards);
        if !self.vegetation.place(d, region, random, at, false)? {
            return Ok(false);
        }
        let table = d.table.as_ref();
        let placed = region.get(pos);
        if table.value(placed, "waterlogged") == Some("false") {
            let wet = table
                .with(placed, "waterlogged", "true")
                .ok_or("waterlogged")?;
            region.set(pos, wet, 2);
        }
        Ok(true)
    }
}

impl Feature {
    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        Ok(match self {
            Feature::Unsupported(kind) => {
                return Err(format!("feature type {kind} is not implemented"))
            }
            Feature::Tree(tree) => return tree.place(d, region, random, origin),
            Feature::VegetationPatch(patch) => return patch.place(d, region, random, origin),
            Feature::FallenTree(tree) => return tree.place(d, region, random, origin),
            Feature::HugeMushroom(m) => return m.place(d, region, random, origin),
            Feature::Bamboo(b) => return b.place(d, region, random, origin),
            Feature::RootSystem(f) => return f.place(d, region, random, origin),
            Feature::Vines(f) => return f.place(d, region, origin),
            Feature::CoralTree(f) => return f.place(d, region, random, origin),
            Feature::CoralClaw(f) => return f.place(d, region, random, origin),

            Feature::UnderwaterMagma(f) => return f.place(d, region, random, origin),
            Feature::MonsterRoom(f) => return f.place(d, region, random, origin),

            Feature::SpeleothemCluster(f) => return f.place(d, region, random, origin),
            Feature::Speleothem(f) => return f.place(d, region, random, origin),
            Feature::MultifaceGrowth(f) => return f.place(d, region, random, origin),

            Feature::Template(f) => return f.place(d, region, random, origin),
            Feature::Fossil(f) => return f.place(d, region, random, origin),
            Feature::Iceberg(f) => return f.place(d, region, random, origin),
            Feature::Spike(f) => return f.place(d, region, random, origin),
            Feature::Geode(f) => return f.place(d, region, random, origin),
            Feature::LargeDripstone(f) => return f.place(d, region, random, origin),
            Feature::SculkPatch(f) => return f.place(d, region, random, origin),
            Feature::Delta(f) => return f.place(d, region, random, origin),
            Feature::SteppedColumnCluster(f) => return f.place(d, region, random, origin),
            Feature::SingleBlockPillar(f) => return f.place(d, region, random, origin),
            Feature::PatchySquare(f) => return f.place(d, region, random, origin),
            Feature::ReplaceBlobs(f) => return f.place(d, region, random, origin),
            Feature::NeighborSpread(f) => return f.place(d, region, random, origin),
            Feature::HugeFungus(f) => return f.place(d, region, random, origin),
            Feature::ScatteredOre(f) => return f.place(d, region, random, origin),
            Feature::EndIsland => {
                super::end::place_island(d, region, random, origin);
                true
            }
            Feature::EndSpikes(f) => return f.place(d, region, random, origin),
            Feature::EndGateway(f) => return f.place(d, region, origin),
            Feature::EndPlatform => {
                super::end::place_platform(d, region, origin);
                true
            }
            Feature::ChorusPlant => d.rules.chorus.place_plant(d, region, random, origin),
            Feature::Overlay(features) => {
                let mut placed = false;
                for feature in features {
                    placed |= feature.place(d, region, random, origin, false)?;
                }
                placed
            }
            Feature::NoOp => true,
            Feature::Ore {
                targets,
                size,
                discard_on_air,
            } => place_ore(d, region, random, origin, targets, *size, *discard_on_air),
            Feature::Disk {
                provider,
                target,
                radius,
                half_height,
            } => {
                let mut placed = false;
                let top = origin[1] + half_height;
                let bottom = origin[1] - half_height - 1;
                let r = radius.sample(random);
                for z in origin[2] - r..=origin[2] + r {
                    for x in origin[0] - r..=origin[0] + r {
                        let (xd, zd) = (x - origin[0], z - origin[2]);
                        if xd * xd + zd * zd > r * r {
                            continue;
                        }
                        let mut placed_above = false;
                        for y in (bottom + 1..=top).rev() {
                            let pos = [x, y, z];
                            if target.test(d, region, pos) {
                                if let Some(state) = provider.optional_state(d, region, random, pos)
                                {
                                    region.set(pos, state, 2);
                                    if !placed_above {
                                        d.mark_above(region, pos);
                                    }
                                    placed = true;
                                    placed_above = true;
                                }
                            } else {
                                placed_above = false;
                            }
                        }
                    }
                }
                placed
            }
            Feature::Spring {
                state,
                fluid,
                requires_block_below,
                rock_count,
                hole_count,
                valid,
            } => {
                let is_valid = |region: &mut Region, p: [i32; 3]| {
                    let s = region.get(p);
                    table.in_tag(s, valid)
                };
                let below = offset(origin, [0, -1, 0]);
                if !is_valid(region, offset(origin, [0, 1, 0])) {
                    return Ok(false);
                }
                if *requires_block_below && !is_valid(region, below) {
                    return Ok(false);
                }
                let current = region.get(origin);
                if !table.is_air(current) && !table.in_tag(current, valid) {
                    return Ok(false);
                }
                let sides = [[-1, 0, 0], [1, 0, 0], [0, 0, -1], [0, 0, 1], [0, -1, 0]];
                let rocks = sides
                    .iter()
                    .filter(|s| is_valid(region, offset(origin, **s)))
                    .count() as i32;
                let holes = sides
                    .iter()
                    .filter(|s| region.is_air_at(offset(origin, **s)))
                    .count() as i32;
                if rocks == *rock_count && holes == *hole_count {
                    region.set(origin, *state, 2);
                    region.schedule_fluid_tick(origin, *fluid);
                    true
                } else {
                    false
                }
            }
            Feature::BlockPile { provider } => {
                if origin[1] < region.min_y() + 5 {
                    return Ok(false);
                }
                let xr = 2 + random.next_int_bounded(2);
                let zr = 2 + random.next_int_bounded(2);
                let dirt_path = table.block("dirt_path")?;
                // `BlockPos.betweenClosed`: x fastest, then y, then z.
                for z in origin[2] - zr..=origin[2] + zr {
                    for y in origin[1]..=origin[1] + 1 {
                        for x in origin[0] - xr..=origin[0] + xr {
                            let (xd, zd) = (origin[0] - x, origin[2] - z);
                            let near = ((xd * xd + zd * zd) as f32)
                                <= random.next_float() * 10.0 - random.next_float() * 6.0;
                            if !near && (random.next_float() as f64) >= 0.031 {
                                continue;
                            }
                            // `tryPlaceBlock`: into air, on a sturdy top (or
                            // on a path half of the time).
                            let pos = [x, y, z];
                            if !table.is_air(region.get(pos)) {
                                continue;
                            }
                            let below = region.get([x, y - 1, z]);
                            let on = if table.block_of(below) == dirt_path {
                                random.next_bool()
                            } else {
                                table.flag(below, STURDY << 1)
                            };
                            if on {
                                let state = provider.state(d, region, random, pos);
                                region.set(pos, state, 260);
                            }
                        }
                    }
                }
                true
            }
            Feature::SimpleBlock {
                provider,
                schedule_tick,
            } => {
                let Some(state) = provider.optional_state(d, region, random, origin) else {
                    return Ok(false);
                };
                if !d.survives(region, state, origin) {
                    return Ok(false);
                }
                if table.flag(state, DOUBLE_PLANT) {
                    let above = offset(origin, [0, 1, 0]);
                    let above_state = region.get(above);
                    let same_fluid = table.fluid(state) == table.fluid(above_state)
                        && table.fluid_level[state as usize]
                            == table.fluid_level[above_state as usize];
                    if !table.is_air(above_state)
                        && (!same_fluid || !table.flag(above_state, REPLACEABLE))
                    {
                        return Ok(false);
                    }
                    for (pos, half) in [(origin, "lower"), (above, "upper")] {
                        let mut s = table.with(state, "half", half).ok_or("double plant half")?;
                        if table.has_property(s, "waterlogged") {
                            let here = region.get(pos);
                            let water = table.fluid(here) == FLUID_WATER
                                || table.fluid(here) == super::blocks::FLUID_FLOWING_WATER;
                            s = table
                                .with(s, "waterlogged", if water { "true" } else { "false" })
                                .ok_or("waterlogged")?;
                        }
                        region.set(pos, s, 2);
                    }
                } else if table.flag(state, MOSSY_CARPET) {
                    super::multiface::MossyCarpet::new(table)?.place_at(region, origin);
                } else {
                    region.set(origin, state, 2);
                }
                if *schedule_tick {
                    let now = region.get(origin);
                    region.schedule_block_tick(origin, table.block_of(now));
                }
                true
            }
            Feature::RandomSelector { features, default } => {
                for (feature, chance) in features {
                    if random.next_float() < *chance {
                        return feature.place(d, region, random, origin, false);
                    }
                }
                return default.place(d, region, random, origin, false);
            }
            Feature::SimpleRandomSelector(features) => {
                let index = random.next_int_bounded(features.len() as i32) as usize;
                return features[index].place(d, region, random, origin, false);
            }
            Feature::WeightedRandomSelector(features) => {
                if features.is_empty() {
                    false
                } else {
                    let feature = features.pick(random).clone();
                    return feature.place(d, region, random, origin, false);
                }
            }
            Feature::RandomBooleanSelector(yes, no) => {
                let feature = if random.next_bool() { yes } else { no };
                return feature.place(d, region, random, origin, false);
            }
            Feature::Sequence(features) => {
                for feature in features {
                    if !feature.place(d, region, random, origin, false)? {
                        return Ok(false);
                    }
                }
                true
            }
            Feature::BlockColumn {
                layers,
                step,
                allowed,
                prioritize_tip,
            } => {
                let mut heights: Vec<i32> = Vec::with_capacity(layers.len());
                let mut total = 0;
                for (height, _) in layers {
                    let h = height.sample(random);
                    heights.push(h);
                    total += h;
                }
                if total == 0 {
                    return Ok(false);
                }
                let mut next = offset(origin, *step);
                for y in 0..total {
                    if !allowed.test(d, region, next) {
                        // `truncate`.
                        let mut remove = total - y;
                        let order: Vec<usize> = if *prioritize_tip {
                            (0..heights.len()).collect()
                        } else {
                            (0..heights.len()).rev().collect()
                        };
                        for i in order {
                            if remove <= 0 {
                                break;
                            }
                            let take = heights[i].min(remove);
                            remove -= take;
                            heights[i] -= take;
                        }
                        break;
                    }
                    next = offset(next, *step);
                }
                let mut place = origin;
                for (i, (_, provider)) in layers.iter().enumerate() {
                    for _ in 0..heights[i] {
                        let state = provider.state(d, region, random, place);
                        region.set(place, state, 2);
                        place = offset(place, *step);
                    }
                }
                true
            }
            Feature::Lake {
                fluid,
                barrier,
                can_place,
                can_replace_with_air_or_fluid,
                can_replace_with_barrier,
            } => place_lake(
                d,
                region,
                random,
                origin,
                fluid,
                barrier,
                can_place,
                can_replace_with_air_or_fluid,
                can_replace_with_barrier,
            )?,
            Feature::FreezeTopLayer => {
                for dx in 0..16 {
                    for dz in 0..16 {
                        let (x, z) = (origin[0] + dx, origin[2] + dz);
                        let y = region.height_at(Heightmap::MotionBlocking, x, z);
                        let top = [x, y, z];
                        let below = [x, y - 1, z];
                        let biome = region.biome(top);
                        if d.should_freeze(region, biome, below) {
                            region.set(below, d.known.ice, 2);
                        }
                        if d.should_snow(region, biome, top) {
                            region.set(top, d.known.snow, 2);
                            let below_state = region.get(below);
                            if let Some(snowy) = table.with(below_state, "snowy", "true") {
                                region.set(below, snowy, 2);
                            }
                        }
                    }
                }
                true
            }
            Feature::BlueIce => {
                if origin[1] > d.context.sea_level - 1 {
                    return Ok(false);
                }
                let k = &d.known;
                let at = table.block_of(region.get(origin));
                let below = table.block_of(region.get(offset(origin, [0, -1, 0])));
                if at != k.water_block && below != k.water_block {
                    return Ok(false);
                }
                let mut packed = false;
                for dir in &DIRECTIONS[1..] {
                    if table.block_of(region.get(offset(origin, *dir))) == k.packed_ice_block {
                        packed = true;
                        break;
                    }
                }
                if !packed {
                    return Ok(false);
                }
                region.set(origin, k.blue_ice, 2);
                for _ in 0..200 {
                    let y_off = random.next_int_bounded(5) - random.next_int_bounded(6);
                    let mut spread = 3;
                    if y_off < 2 {
                        spread += y_off / 2;
                    }
                    if spread >= 1 {
                        let dx = random.next_int_bounded(spread) - random.next_int_bounded(spread);
                        let dz = random.next_int_bounded(spread) - random.next_int_bounded(spread);
                        let pos = offset(origin, [dx, y_off, dz]);
                        let s = region.get(pos);
                        let b = table.block_of(s);
                        if table.is_air(s)
                            || b == k.water_block
                            || b == k.packed_ice_block
                            || b == k.ice_block
                        {
                            for dir in &DIRECTIONS {
                                if table.block_of(region.get(offset(pos, *dir))) == k.blue_ice_block
                                {
                                    region.set(pos, k.blue_ice, 2);
                                    break;
                                }
                            }
                        }
                    }
                }
                true
            }
            Feature::BlockBlob {
                state,
                can_place_on,
            } => {
                let mut origin = origin;
                let min = d.context.min_y;
                while origin[1] > min + 3
                    && !can_place_on.test(d, region, offset(origin, [0, -1, 0]))
                {
                    origin[1] -= 1;
                }
                if origin[1] <= min + 3 {
                    return Ok(false);
                }
                for _ in 0..3 {
                    let xr = random.next_int_bounded(2);
                    let yr = random.next_int_bounded(2);
                    let zr = random.next_int_bounded(2);
                    let tr = (xr + yr + zr) as f32 * 0.333 + 0.5;
                    let limit = (tr * tr) as f64;
                    for z in origin[2] - zr..=origin[2] + zr {
                        for y in origin[1] - yr..=origin[1] + yr {
                            for x in origin[0] - xr..=origin[0] + xr {
                                let (dx, dy, dz) = (
                                    (x - origin[0]) as f64,
                                    (y - origin[1]) as f64,
                                    (z - origin[2]) as f64,
                                );
                                if dx * dx + dy * dy + dz * dz <= limit {
                                    region.set([x, y, z], *state, 3);
                                }
                            }
                        }
                    }
                    origin = offset(
                        origin,
                        [
                            -1 + random.next_int_bounded(2),
                            -random.next_int_bounded(2),
                            -1 + random.next_int_bounded(2),
                        ],
                    );
                }
                true
            }
        })
    }
}

/// `OreFeature.place`.
fn place_ore(
    d: &Decoration,
    region: &mut Region,
    random: &mut Random,
    origin: [i32; 3],
    targets: &[(RuleTest, u16)],
    size: i32,
    discard: f32,
) -> bool {
    let table = d.table.as_ref();
    let dir = random.next_float() * std::f64::consts::PI as f32;
    let spread = size as f32 / 8.0;
    let max_radius = ((size as f32 / 16.0 * 2.0 + 1.0) / 2.0).ceil() as i32;
    let (sin, cos) = (super::java::sin(dir as f64), super::java::cos(dir as f64));
    let x0 = origin[0] as f64 + sin * spread as f64;
    let x1 = origin[0] as f64 - sin * spread as f64;
    let z0 = origin[2] as f64 + cos * spread as f64;
    let z1 = origin[2] as f64 - cos * spread as f64;
    let y0 = (origin[1] + random.next_int_bounded(3) - 2) as f64;
    let y1 = (origin[1] + random.next_int_bounded(3) - 2) as f64;
    let spread_ceil = spread.ceil() as i32;
    let x_start = origin[0] - spread_ceil - max_radius;
    let y_start = origin[1] - 2 - max_radius;
    let z_start = origin[2] - spread_ceil - max_radius;
    let size_xz = 2 * (spread_ceil + max_radius);
    let size_y = 2 * (2 + max_radius);
    for xp in x_start..=x_start + size_xz {
        for zp in z_start..=z_start + size_xz {
            if y_start <= region.height_at(Heightmap::OceanFloorWg, xp, zp) {
                return ore_do_place(
                    table,
                    region,
                    random,
                    size,
                    discard,
                    targets,
                    [x0, x1, z0, z1, y0, y1],
                    [x_start, y_start, z_start],
                    size_xz,
                    size_y,
                );
            }
        }
    }
    false
}

#[allow(clippy::too_many_arguments)]
fn ore_do_place(
    table: &BlockTable,
    region: &mut Region,
    random: &mut Random,
    size: i32,
    discard: f32,
    targets: &[(RuleTest, u16)],
    [x0, x1, z0, z1, y0, y1]: [f64; 6],
    [x_start, y_start, z_start]: [i32; 3],
    size_xz: i32,
    size_y: i32,
) -> bool {
    let n = size as usize;
    let mut data = vec![0.0f64; n * 4];
    let lerp = |t: f32, a: f64, b: f64| a + t as f64 * (b - a);
    for i in 0..n {
        let step = i as f32 / size as f32;
        let ss = random.next_double() * size as f64 / 16.0;
        let sin = super::carver::sin((std::f64::consts::PI as f32 * step) as f64);
        let r = (((sin + 1.0) as f64) * ss + 1.0) / 2.0;
        data[i * 4] = lerp(step, x0, x1);
        data[i * 4 + 1] = lerp(step, y0, y1);
        data[i * 4 + 2] = lerp(step, z0, z1);
        data[i * 4 + 3] = r;
    }
    for a in 0..n.saturating_sub(1) {
        if data[a * 4 + 3] <= 0.0 {
            continue;
        }
        for b in a + 1..n {
            if data[b * 4 + 3] <= 0.0 {
                continue;
            }
            let dx = data[a * 4] - data[b * 4];
            let dy = data[a * 4 + 1] - data[b * 4 + 1];
            let dz = data[a * 4 + 2] - data[b * 4 + 2];
            let dr = data[a * 4 + 3] - data[b * 4 + 3];
            if dr * dr > dx * dx + dy * dy + dz * dz {
                if dr > 0.0 {
                    data[b * 4 + 3] = -1.0;
                } else {
                    data[a * 4 + 3] = -1.0;
                }
            }
        }
    }
    // `BulkSectionAccess.getBlockState`: air outside the world's height.
    let air = region.air;
    let bulk = |region: &mut Region, p: [i32; 3]| {
        if region.is_outside_build_height(p[1]) {
            air
        } else {
            region.get(p)
        }
    };
    let mut tested: Vec<u64> = Vec::new();
    let mut placed = 0;
    for i in 0..n {
        let r = data[i * 4 + 3];
        if r < 0.0 {
            continue;
        }
        let (xx, yy, zz) = (data[i * 4], data[i * 4 + 1], data[i * 4 + 2]);
        let x_min = ((xx - r).floor() as i32).max(x_start);
        let y_min = ((yy - r).floor() as i32).max(y_start);
        let z_min = ((zz - r).floor() as i32).max(z_start);
        let x_max = ((xx + r).floor() as i32).max(x_min);
        let y_max = ((yy + r).floor() as i32).max(y_min);
        let z_max = ((zz + r).floor() as i32).max(z_min);
        for x in x_min..=x_max {
            let xd = (x as f64 + 0.5 - xx) / r;
            if xd * xd >= 1.0 {
                continue;
            }
            for y in y_min..=y_max {
                let yd = (y as f64 + 0.5 - yy) / r;
                if xd * xd + yd * yd >= 1.0 {
                    continue;
                }
                for z in z_min..=z_max {
                    let zd = (z as f64 + 0.5 - zz) / r;
                    if xd * xd + yd * yd + zd * zd >= 1.0 || region.is_outside_build_height(y) {
                        continue;
                    }
                    let bit = (x - x_start
                        + (y - y_start) * size_xz
                        + (z - z_start) * size_xz * size_y) as usize;
                    if tested.len() <= bit / 64 {
                        tested.resize(bit / 64 + 1, 0);
                    }
                    if tested[bit / 64] & (1 << (bit % 64)) != 0 {
                        continue;
                    }
                    tested[bit / 64] |= 1 << (bit % 64);
                    let pos = [x, y, z];
                    if !region.can_write(pos) {
                        continue;
                    }
                    let state = region.get(pos);
                    for (target, ore) in targets {
                        if !target.test(table, state, pos, random) {
                            continue;
                        }
                        let skip_air_check = if discard <= 0.0 {
                            true
                        } else if discard >= 1.0 {
                            false
                        } else {
                            random.next_float() >= discard
                        };
                        let ok = skip_air_check
                            || !DIRECTIONS
                                .iter()
                                .any(|dir| table.is_air(bulk(region, offset(pos, *dir))));
                        if ok {
                            region.set_raw(pos, *ore);
                            placed += 1;
                            break;
                        }
                    }
                }
            }
        }
    }
    placed > 0
}

#[allow(clippy::too_many_arguments)]
fn place_lake(
    d: &Decoration,
    region: &mut Region,
    random: &mut Random,
    origin: [i32; 3],
    fluid: &StateProvider,
    barrier: &StateProvider,
    can_place: &BlockPredicate,
    can_replace_with_air_or_fluid: &BlockPredicate,
    can_replace_with_barrier: &BlockPredicate,
) -> Result<bool, String> {
    let table = d.table.as_ref();
    if origin[1] <= d.context.min_y + 4 {
        return Ok(false);
    }
    let origin = offset(origin, [-8, -4, -8]);
    let mut grid = [false; 2048];
    let cell = |x: usize, z: usize, y: usize| (x * 16 + z) * 8 + y;
    let spots = random.next_int_bounded(4) + 4;
    for _ in 0..spots {
        let xr = random.next_double() * 6.0 + 3.0;
        let yr = random.next_double() * 4.0 + 2.0;
        let zr = random.next_double() * 6.0 + 3.0;
        let xp = random.next_double() * (16.0 - xr - 2.0) + 1.0 + xr / 2.0;
        let yp = random.next_double() * (8.0 - yr - 4.0) + 2.0 + yr / 2.0;
        let zp = random.next_double() * (16.0 - zr - 2.0) + 1.0 + zr / 2.0;
        for xx in 1..15 {
            for zz in 1..15 {
                for yy in 1..7 {
                    let xd = (xx as f64 - xp) / (xr / 2.0);
                    let yd = (yy as f64 - yp) / (yr / 2.0);
                    let zd = (zz as f64 - zp) / (zr / 2.0);
                    if xd * xd + yd * yd + zd * zd < 1.0 {
                        grid[cell(xx, zz, yy)] = true;
                    }
                }
            }
        }
    }
    let edge = |grid: &[bool; 2048], xx: usize, zz: usize, yy: usize| {
        !grid[cell(xx, zz, yy)]
            && (xx < 15 && grid[cell(xx + 1, zz, yy)]
                || xx > 0 && grid[cell(xx - 1, zz, yy)]
                || zz < 15 && grid[cell(xx, zz + 1, yy)]
                || zz > 0 && grid[cell(xx, zz - 1, yy)]
                || yy < 7 && grid[cell(xx, zz, yy + 1)]
                || yy > 0 && grid[cell(xx, zz, yy - 1)])
    };
    let fluid_state = fluid.state(d, region, random, origin);
    for xx in 0..16 {
        for zz in 0..16 {
            for yy in 0..8 {
                if edge(&grid, xx, zz, yy) {
                    let pos = offset(origin, [xx as i32, yy as i32, zz as i32]);
                    let state = region.get(pos);
                    if yy >= 4 && table.flag(state, LIQUID) {
                        return Ok(false);
                    }
                    if yy < 4 && !table.flag(state, SOLID) && state != fluid_state {
                        return Ok(false);
                    }
                    if !can_place.test(d, region, pos) {
                        return Ok(false);
                    }
                }
            }
        }
    }
    for xx in 0..16 {
        for zz in 0..16 {
            for yy in 0..8 {
                if grid[cell(xx, zz, yy)] {
                    let pos = offset(origin, [xx as i32, yy as i32, zz as i32]);
                    if can_replace_with_air_or_fluid.test(d, region, pos) {
                        let air = yy >= 4;
                        region.set(pos, if air { d.known.cave_air } else { fluid_state }, 2);
                        if air {
                            region.schedule_block_tick(pos, table.block_of(d.known.cave_air));
                            d.mark_above(region, pos);
                        }
                    }
                }
            }
        }
    }
    let barrier_state = barrier.state(d, region, random, origin);
    if !table.is_air(barrier_state) {
        for xx in 0..16 {
            for zz in 0..16 {
                for yy in 0..8 {
                    if edge(&grid, xx, zz, yy) && (yy < 4 || random.next_int_bounded(2) != 0) {
                        let pos = offset(origin, [xx as i32, yy as i32, zz as i32]);
                        let state = region.get(pos);
                        if table.flag(state, SOLID) && can_replace_with_barrier.test(d, region, pos)
                        {
                            region.set(pos, barrier_state, 2);
                            d.mark_above(region, pos);
                        }
                    }
                }
            }
        }
    }
    let water = table.fluid(fluid_state);
    if water == FLUID_WATER || water == super::blocks::FLUID_FLOWING_WATER {
        for xx in 0..16 {
            for zz in 0..16 {
                let pos = offset(origin, [xx, 4, zz]);
                let biome = region.biome(pos);
                if d.should_freeze(region, biome, pos)
                    && can_replace_with_air_or_fluid.test(d, region, pos)
                {
                    region.set(pos, d.known.ice, 2);
                }
            }
        }
    }
    Ok(true)
}
