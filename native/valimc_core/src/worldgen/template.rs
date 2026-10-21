//! Structure templates (VMC-025c): the templates features place (fossils,
//! the desert well, sulfur springs) as vanilla loads them
//! (`StructureTemplateOracle`, `priv/worldgen/templates.json`), processor
//! lists (`processor_lists.json`), `StructureTemplate.placeInWorld` with its
//! processors, waterlogging and shape updates, and the template and fossil
//! features.

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

use super::blocks::{
    BlockSet, BlockTable, Heightmap, FLUID_LAVA, FLUID_WATER, LIQUID_CONTAINER, SIMPLE_WATERLOGGED,
};
use super::feature::Decoration;
use super::json::Json;
use super::predicate::{offset, RuleTest};
use super::random::{position_seed, Random};
use super::region::Region;
use super::tree::{Shape, EAST, NORTH, SOUTH, WEST};

/// A template block's block entity data, with what processors added: its
/// loot table and seed, and its whole NBT as the template holds it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct EntityNbt {
    pub loot_table: Option<String>,
    pub loot_seed: Option<i64>,
    pub snbt: Option<Arc<str>>,
}

impl EntityNbt {
    /// The fields decoration reads from a template block's SNBT.
    fn parse(snbt: &str) -> EntityNbt {
        let after = |key: &str| {
            let at = snbt.find(&format!("{key}:"))?;
            Some(&snbt[at + key.len() + 1..])
        };
        let loot_table = after("LootTable")
            .and_then(|rest| rest.strip_prefix('"'))
            .and_then(|rest| rest.split('"').next())
            .map(str::to_string);
        let loot_seed = after("LootTableSeed").and_then(|rest| {
            let digits: String = rest
                .chars()
                .take_while(|c| c.is_ascii_digit() || *c == '-')
                .collect();
            digits.parse().ok()
        });
        EntityNbt {
            loot_table,
            loot_seed,
            snbt: Some(Arc::from(snbt)),
        }
    }
}

#[derive(Clone, Debug)]
pub struct TemplateBlock {
    pub pos: [i32; 3],
    pub state: u16,
    pub nbt: Option<EntityNbt>,
}

/// An entity a template holds: its position and block position in the
/// template, and its NBT.
#[derive(Clone, Debug)]
pub struct TemplateEntity {
    pub pos: [f64; 3],
    pub block_pos: [i32; 3],
    pub nbt: Arc<str>,
}

#[derive(Debug, Default)]
pub struct Template {
    pub size: [i32; 3],
    pub palettes: Vec<Vec<TemplateBlock>>,
    pub entities: Vec<TemplateEntity>,
}

impl Template {
    /// `getSize(rotation)`.
    pub fn size(&self, rotation: Rotation) -> [i32; 3] {
        match rotation {
            Rotation::Clockwise90 | Rotation::Counterclockwise90 => {
                [self.size[2], self.size[1], self.size[0]]
            }
            _ => self.size,
        }
    }

    /// `getBoundingBox(settings, position)`.
    pub fn bounding_box(&self, settings: &PlaceSettings, position: [i32; 3]) -> BoundingBox {
        let delta = [self.size[0] - 1, self.size[1] - 1, self.size[2] - 1];
        let a = transform(
            [0, 0, 0],
            settings.mirror,
            settings.rotation,
            settings.pivot,
        );
        let b = transform(delta, settings.mirror, settings.rotation, settings.pivot);
        BoundingBox::from_corners(a, b).moved(position)
    }

    /// `getZeroPositionWithTransform`.
    pub fn zero_position(&self, zero: [i32; 3], mirror: Mirror, rotation: Rotation) -> [i32; 3] {
        let (sx, sz) = (self.size[0] - 1, self.size[2] - 1);
        let mx = if mirror == Mirror::FrontBack { sx } else { 0 };
        let mz = if mirror == Mirror::LeftRight { sz } else { 0 };
        let d = match rotation {
            Rotation::Counterclockwise90 => [mz, 0, sx - mx],
            Rotation::Clockwise90 => [sz - mz, 0, mx],
            Rotation::Clockwise180 => [sx - mx, 0, sz - mz],
            Rotation::None => [mx, 0, mz],
        };
        offset(zero, d)
    }
}

/// `Rotation`, in vanilla's order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rotation {
    None,
    Clockwise90,
    Clockwise180,
    Counterclockwise90,
}

pub const ROTATIONS: [Rotation; 4] = [
    Rotation::None,
    Rotation::Clockwise90,
    Rotation::Clockwise180,
    Rotation::Counterclockwise90,
];

impl Rotation {
    fn parse(name: &str) -> Result<Rotation, String> {
        Ok(match name {
            "none" => Rotation::None,
            "clockwise_90" => Rotation::Clockwise90,
            "180" => Rotation::Clockwise180,
            "counterclockwise_90" => Rotation::Counterclockwise90,
            other => return Err(format!("unknown rotation {other}")),
        })
    }

    /// `rotate(Direction)` of a horizontal direction.
    fn rotate(self, d: usize) -> usize {
        let clockwise = super::tree::clockwise;
        match self {
            Rotation::None => d,
            Rotation::Clockwise90 => clockwise(d),
            Rotation::Clockwise180 => d ^ 1,
            Rotation::Counterclockwise90 => clockwise(d) ^ 1,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mirror {
    None,
    LeftRight,
    FrontBack,
}

/// `StructureTemplate.transform` of a block position.
pub fn transform(pos: [i32; 3], mirror: Mirror, rotation: Rotation, pivot: [i32; 3]) -> [i32; 3] {
    let [mut x, y, mut z] = pos;
    match mirror {
        Mirror::LeftRight => z = -z,
        Mirror::FrontBack => x = -x,
        Mirror::None => {}
    }
    let (px, pz) = (pivot[0], pivot[2]);
    match rotation {
        Rotation::Counterclockwise90 => [px - pz + z, y, px + pz - x],
        Rotation::Clockwise90 => [px + pz - z, y, pz - px + x],
        Rotation::Clockwise180 => [px + px - x, y, pz + pz - z],
        Rotation::None => [x, y, z],
    }
}

/// `BoundingBox`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BoundingBox {
    pub min: [i32; 3],
    pub max: [i32; 3],
}

impl BoundingBox {
    pub fn from_corners(a: [i32; 3], b: [i32; 3]) -> BoundingBox {
        BoundingBox {
            min: [a[0].min(b[0]), a[1].min(b[1]), a[2].min(b[2])],
            max: [a[0].max(b[0]), a[1].max(b[1]), a[2].max(b[2])],
        }
    }

    pub fn moved(self, by: [i32; 3]) -> BoundingBox {
        BoundingBox {
            min: offset(self.min, by),
            max: offset(self.max, by),
        }
    }

    pub fn inside(&self, p: [i32; 3]) -> bool {
        (0..3).all(|i| p[i] >= self.min[i] && p[i] <= self.max[i])
    }

    pub fn corners(&self) -> [[i32; 3]; 8] {
        let (a, b) = (self.min, self.max);
        [
            [a[0], a[1], a[2]],
            [a[0], a[1], b[2]],
            [a[0], b[1], a[2]],
            [a[0], b[1], b[2]],
            [b[0], a[1], a[2]],
            [b[0], a[1], b[2]],
            [b[0], b[1], a[2]],
            [b[0], b[1], b[2]],
        ]
    }
}

/// A rule's block entity modifier (`RuleBlockEntityModifier`).
#[derive(Clone, Debug)]
pub enum EntityModifier {
    Passthrough,
    /// A loot table, seeded from the rule's random.
    AppendLoot(String),
    Clear,
}

/// A rule's position predicate (`PosRuleTest`).
#[derive(Clone, Debug)]
pub enum PosTest {
    AlwaysTrue,
    /// Manhattan (linear) or along one axis (index), the chance lerped from
    /// `min_chance` to `max_chance` over `min_dist`..`max_dist` from the
    /// reference.
    Linear {
        axis: Option<usize>,
        min_chance: f32,
        max_chance: f32,
        min_dist: i32,
        max_dist: i32,
    },
}

impl PosTest {
    fn parse(json: &Json) -> Result<PosTest, String> {
        let f = |key: &str, default: f64| -> Result<f32, String> {
            Ok(json
                .get(key)
                .map(Json::as_f64)
                .transpose()?
                .unwrap_or(default) as f32)
        };
        let i = |key: &str| -> Result<i32, String> {
            Ok(json.get(key).map(Json::as_i32).transpose()?.unwrap_or(0))
        };
        Ok(match json.field("predicate_type")?.as_str()? {
            "minecraft:always_true" => PosTest::AlwaysTrue,
            kind @ ("minecraft:linear_pos" | "minecraft:axis_aligned_linear_pos") => {
                PosTest::Linear {
                    axis: match kind {
                        "minecraft:linear_pos" => None,
                        _ => Some(
                            match json
                                .get("axis")
                                .map(Json::as_str)
                                .transpose()?
                                .unwrap_or("y")
                            {
                                "x" => 0,
                                "y" => 1,
                                "z" => 2,
                                other => return Err(format!("unknown axis {other}")),
                            },
                        ),
                    },
                    min_chance: f("min_chance", 0.0)?,
                    max_chance: f("max_chance", 0.0)?,
                    min_dist: i("min_dist")?,
                    max_dist: i("max_dist")?,
                }
            }
            other => return Err(format!("position predicate {other} is not implemented")),
        })
    }

    fn test(&self, pos: [i32; 3], reference: [i32; 3], random: &mut Random) -> bool {
        match *self {
            PosTest::AlwaysTrue => true,
            PosTest::Linear {
                axis,
                min_chance,
                max_chance,
                min_dist,
                max_dist,
            } => {
                let dist = match axis {
                    None => (0..3).map(|i| (pos[i] - reference[i]).abs()).sum::<i32>(),
                    Some(a) => (pos[a] - reference[a]).abs(),
                };
                let roll = random.next_float();
                let t = (dist as f32 - min_dist as f32) / (max_dist as f32 - min_dist as f32);
                let chance = if t < 0.0 {
                    min_chance
                } else if t > 1.0 {
                    max_chance
                } else {
                    min_chance + t * (max_chance - min_chance)
                };
                roll <= chance
            }
        }
    }
}

#[derive(Clone, Debug)]
pub struct ProcessorRule {
    input: RuleTest,
    location: RuleTest,
    position: PosTest,
    output: u16,
    modifier: EntityModifier,
}

/// A structure processor (`StructureProcessor`).
#[derive(Clone, Debug)]
pub enum Processor {
    BlockRot {
        rottable: Option<BlockSet>,
        integrity: f32,
    },
    Protected(BlockSet),
    Rule(Vec<ProcessorRule>),
    /// Blocks dropped (`BlockIgnoreProcessor`).
    Ignore(BlockSet),
    /// To the heightmap plus an offset, keeping the height in the template.
    Gravity {
        heightmap: Heightmap,
        offset: i32,
    },
    /// Jigsaw blocks become their final state.
    JigsawReplacement,
    /// Stone bricks, stairs, slabs, walls and obsidian aged (`BlockAgeProcessor`).
    BlockAge(f32),
    /// The Nether's ruined portals in blackstone (`BlackstoneReplaceProcessor`).
    BlackstoneReplace(HashMap<u16, u16>),
    /// Lava stays where a block that is not full would replace it.
    LavaSubmerged,
    /// Its delegate, applied to at most `limit` blocks of the piece chosen
    /// from the seed at the piece's position.
    Capped {
        delegate: Box<Processor>,
        limit: super::providers::IntProvider,
    },
    Nop,
}

/// `BlackstoneReplaceProcessor`'s replacements.
const BLACKSTONE: [(&str, &str); 23] = [
    ("cobblestone", "blackstone"),
    ("mossy_cobblestone", "blackstone"),
    ("stone", "polished_blackstone"),
    ("stone_bricks", "polished_blackstone_bricks"),
    ("mossy_stone_bricks", "polished_blackstone_bricks"),
    ("cobblestone_stairs", "blackstone_stairs"),
    ("mossy_cobblestone_stairs", "blackstone_stairs"),
    ("stone_stairs", "polished_blackstone_stairs"),
    ("stone_brick_stairs", "polished_blackstone_brick_stairs"),
    (
        "mossy_stone_brick_stairs",
        "polished_blackstone_brick_stairs",
    ),
    ("cobblestone_slab", "blackstone_slab"),
    ("mossy_cobblestone_slab", "blackstone_slab"),
    ("smooth_stone_slab", "polished_blackstone_slab"),
    ("stone_slab", "polished_blackstone_slab"),
    ("stone_brick_slab", "polished_blackstone_brick_slab"),
    ("mossy_stone_brick_slab", "polished_blackstone_brick_slab"),
    ("stone_brick_wall", "polished_blackstone_brick_wall"),
    ("mossy_stone_brick_wall", "polished_blackstone_brick_wall"),
    ("cobblestone_wall", "blackstone_wall"),
    ("mossy_cobblestone_wall", "blackstone_wall"),
    ("chiseled_stone_bricks", "chiseled_polished_blackstone"),
    ("cracked_stone_bricks", "cracked_polished_blackstone_bricks"),
    ("iron_bars", "iron_chain"),
];

/// What processors see of a placement: the piece's position, the start's
/// reference position, the settings and, for structure pieces, no shared
/// random (each position seeds its own).
pub struct ProcessContext<'s> {
    pub position: [i32; 3],
    pub reference: [i32; 3],
    pub settings: &'s PlaceSettings,
    pub seed: i64,
}

impl Processor {
    fn parse(json: &Json, table: &BlockTable) -> Result<Processor, String> {
        Ok(match json.field("processor_type")?.as_str()? {
            "minecraft:block_rot" => Processor::BlockRot {
                rottable: json
                    .get("rottable_blocks")
                    .map(|b| table.block_set(b))
                    .transpose()?,
                integrity: json.field("integrity")?.as_f64()? as f32,
            },
            "minecraft:protected_blocks" => {
                Processor::Protected(table.block_set(json.field("value")?)?)
            }
            "minecraft:block_ignore" => Processor::Ignore(BlockSet::from_blocks(
                json.field("blocks")?
                    .as_array()?
                    .iter()
                    .map(|b| table.state(b).map(|s| table.block_of(s)))
                    .collect::<Result<Vec<_>, _>>()?,
            )),
            "minecraft:gravity" => Processor::Gravity {
                heightmap: Heightmap::parse(
                    json.get("heightmap")
                        .map(Json::as_str)
                        .transpose()?
                        .unwrap_or("WORLD_SURFACE_WG"),
                )?,
                offset: json
                    .get("offset")
                    .map(Json::as_i32)
                    .transpose()?
                    .unwrap_or(0),
            },
            "minecraft:jigsaw_replacement" => Processor::JigsawReplacement,
            "minecraft:block_age" => Processor::BlockAge(json.field("mossiness")?.as_f64()? as f32),
            "minecraft:blackstone_replace" => {
                let mut map = HashMap::new();
                for (from, to) in BLACKSTONE {
                    map.insert(table.block(from)?, table.block(to)?);
                }
                Processor::BlackstoneReplace(map)
            }
            "minecraft:lava_submerged_block" => Processor::LavaSubmerged,
            "minecraft:capped" => Processor::Capped {
                delegate: Box::new(Processor::parse(json.field("delegate")?, table)?),
                limit: super::providers::IntProvider::parse(json.field("limit")?)?,
            },
            "minecraft:nop" => Processor::Nop,
            "minecraft:rule" => Processor::Rule(
                json.field("rules")?
                    .as_array()?
                    .iter()
                    .map(|r| {
                        let modifier = match r.get("block_entity_modifier") {
                            None => EntityModifier::Passthrough,
                            Some(m) => match m.field("type")?.as_str()? {
                                "minecraft:passthrough" => EntityModifier::Passthrough,
                                "minecraft:append_loot" => EntityModifier::AppendLoot(
                                    m.field("loot_table")?.as_str()?.to_string(),
                                ),
                                "minecraft:append_static" => {
                                    return Err("append_static modifiers are not implemented".into())
                                }
                                "minecraft:clear" => EntityModifier::Clear,
                                other => return Err(format!("block entity modifier {other}")),
                            },
                        };
                        Ok(ProcessorRule {
                            input: RuleTest::parse(r.field("input_predicate")?, table)?,
                            location: RuleTest::parse(r.field("location_predicate")?, table)?,
                            position: match r.get("position_predicate") {
                                Some(p) => PosTest::parse(p)?,
                                None => PosTest::AlwaysTrue,
                            },
                            output: table.state(r.field("output_state")?)?,
                            modifier,
                        })
                    })
                    .collect::<Result<_, String>>()?,
            ),
            other => return Err(format!("structure processor {other} is not implemented")),
        })
    }
}

impl ProcessorRule {
    /// A rule replacing `from` (with a chance, when given) by `to`'s default
    /// state anywhere (`RuinedPortalPiece.getBlockReplaceRule`).
    pub fn replace(
        table: &BlockTable,
        from: &str,
        chance: Option<f32>,
        to: &str,
    ) -> Result<ProcessorRule, String> {
        let block = table.block(from)?;
        Ok(ProcessorRule {
            input: match chance {
                Some(p) => RuleTest::RandomBlock(block, p),
                None => RuleTest::Block(block),
            },
            location: RuleTest::AlwaysTrue,
            position: PosTest::AlwaysTrue,
            output: table.default_state(to)?,
            modifier: EntityModifier::Passthrough,
        })
    }
}

impl Processor {
    /// `BlackstoneReplaceProcessor`.
    pub fn blackstone(table: &BlockTable) -> Result<Processor, String> {
        let mut map = HashMap::new();
        for (from, to) in BLACKSTONE {
            map.insert(table.block(from)?, table.block(to)?);
        }
        Ok(Processor::BlackstoneReplace(map))
    }

    /// A rule replacing `candidate` with `replacement` and a loot table,
    /// capped at `limit` blocks of the piece (ocean ruins' suspicious sand
    /// and gravel).
    pub fn capped_rule(
        table: &BlockTable,
        candidate: &str,
        replacement: &str,
        loot_table: &str,
        limit: i32,
    ) -> Result<Processor, String> {
        Ok(Processor::Capped {
            delegate: Box::new(Processor::Rule(vec![ProcessorRule {
                input: RuleTest::Block(table.block(candidate)?),
                location: RuleTest::AlwaysTrue,
                position: PosTest::AlwaysTrue,
                output: table.default_state(replacement)?,
                modifier: EntityModifier::AppendLoot(loot_table.to_string()),
            }])),
            limit: super::providers::IntProvider::Constant(limit),
        })
    }
}

impl Processor {
    /// `processBlock`: the block as processed, or `None` when dropped.
    /// `shared` is the settings' random when set (features); otherwise each
    /// position seeds its own (`StructurePlaceSettings.getRandom`).
    fn process(
        &self,
        d: &Decoration,
        region: &mut Region,
        ctx: &ProcessContext,
        original: &TemplateBlock,
        info: BlockInfo,
        shared: Option<&mut Random>,
    ) -> Result<Option<BlockInfo>, String> {
        let table = d.table.as_ref();
        let p = info.pos;
        let mut own = Random::legacy(position_seed(p[0], p[1], p[2]));
        let settings_random = match shared {
            Some(r) => r,
            None => &mut own,
        };
        Ok(match self {
            Processor::BlockRot {
                rottable,
                integrity,
            } => {
                // The processed state (a jigsaw block's final state rots).
                let fixed = rottable
                    .as_ref()
                    .is_some_and(|set| !table.in_tag(info.state, set));
                (fixed || settings_random.next_float() <= *integrity).then_some(info)
            }
            Processor::Protected(set) => {
                let current = region.get(p);
                (!table.in_tag(current, set)).then_some(info)
            }
            Processor::Ignore(set) => (!set.contains(table.block_of(info.state))).then_some(info),
            Processor::Gravity { heightmap, offset } => {
                let height = region.height_at(*heightmap, p[0], p[2]) + offset;
                Some(BlockInfo {
                    pos: [p[0], height + original.pos[1], p[2]],
                    ..info
                })
            }
            Processor::JigsawReplacement => {
                if table.block_of(info.state) != table.block("jigsaw")? {
                    return Ok(Some(info));
                }
                let Some(nbt) = info.nbt.as_ref().and_then(|n| n.snbt.clone()) else {
                    return Ok(Some(info));
                };
                let final_state = snbt_string(&nbt, "final_state").unwrap_or("minecraft:air");
                // A final state of structure void leaves the position alone.
                match parse_state(table, final_state) {
                    Some(state) if table.block_of(state) == table.block("structure_void")? => None,
                    Some(state) => Some(BlockInfo {
                        pos: p,
                        state,
                        nbt: None,
                    }),
                    None => None,
                }
            }
            Processor::BlockAge(mossiness) => {
                block_age(d, info.state, *mossiness, settings_random)?
                    .map_or(Some(info.clone()), |state| {
                        Some(BlockInfo { state, ..info })
                    })
            }
            Processor::BlackstoneReplace(map) => match map.get(&table.block_of(info.state)) {
                None => Some(info),
                Some(&block) => {
                    let mut state = table.default_state_of(block);
                    for property in ["facing", "half", "type"] {
                        if let Some(v) = table.value(info.state, property) {
                            state = table.with(state, property, v).unwrap_or(state);
                        }
                    }
                    Some(BlockInfo { state, ..info })
                }
            },
            Processor::LavaSubmerged => {
                let lava = table.default_state("lava")?;
                let here = region.get(p);
                if table.block_of(here) == table.block_of(lava)
                    && !table.flag2(info.state, super::blocks::FULL_SHAPE)
                {
                    Some(BlockInfo {
                        state: lava,
                        ..info
                    })
                } else {
                    Some(info)
                }
            }
            Processor::Capped { .. } | Processor::Nop => Some(info),
            Processor::Rule(rules) => {
                let mut random = Random::legacy(position_seed(p[0], p[1], p[2]));
                for rule in rules {
                    if !rule.input.test(table, info.state, p, &mut random) {
                        continue;
                    }
                    let current = region.get(p);
                    if !rule.location.test(table, current, p, &mut random) {
                        continue;
                    }
                    if !rule.position.test(p, ctx.reference, &mut random) {
                        continue;
                    }
                    let nbt = match &rule.modifier {
                        EntityModifier::Passthrough => info.nbt,
                        EntityModifier::Clear => Some(EntityNbt {
                            snbt: Some(Arc::from("{}")),
                            ..EntityNbt::default()
                        }),
                        EntityModifier::AppendLoot(table_id) => {
                            let mut nbt = info.nbt.unwrap_or_default();
                            nbt.loot_table = Some(table_id.clone());
                            nbt.loot_seed = Some(random.next_long());
                            Some(nbt)
                        }
                    };
                    return Ok(Some(BlockInfo {
                        pos: p,
                        state: rule.output,
                        nbt,
                    }));
                }
                Some(info)
            }
        })
    }

    /// `finalizeProcessing`: a capped processor applies its delegate to the
    /// piece's processed blocks in an order shuffled from the seed at the
    /// piece's position, until `limit` of them changed.
    fn finalize(
        &self,
        d: &Decoration,
        region: &mut Region,
        ctx: &ProcessContext,
        original: &[&TemplateBlock],
        mut processed: Vec<BlockInfo>,
    ) -> Result<Vec<BlockInfo>, String> {
        let Processor::Capped { delegate, limit } = self else {
            return Ok(processed);
        };
        if limit.max_inclusive() == 0 || processed.is_empty() || original.len() != processed.len() {
            return Ok(processed);
        }
        let at = ctx.position;
        let mut random = Random::legacy(ctx.seed)
            .fork_positional()
            .at(at[0], at[1], at[2]);
        let most = limit.sample(&mut random).min(processed.len() as i32);
        if most < 1 {
            return Ok(processed);
        }
        let mut order: Vec<usize> = (0..processed.len()).collect();
        super::plants::shuffle(&mut order, &mut random);
        let mut replaced = 0;
        for index in order {
            if replaced >= most {
                break;
            }
            let current = processed[index].clone();
            if let Some(altered) =
                delegate.process(d, region, ctx, original[index], current.clone(), None)?
            {
                if altered != current {
                    replaced += 1;
                    processed[index] = altered;
                }
            }
        }
        Ok(processed)
    }
}

/// A top-level string field of an SNBT compound (`getStringOr`).
pub(crate) fn snbt_string<'a>(snbt: &'a str, key: &str) -> Option<&'a str> {
    let mut depth = 0;
    let bytes = snbt.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'{' | b'[' => depth += 1,
            b'}' | b']' => depth -= 1,
            b'"' => {
                // Skip a quoted string (a key or a value).
                let start = i + 1;
                i += 1;
                while i < bytes.len() && bytes[i] != b'"' {
                    if bytes[i] == b'\\' {
                        i += 1;
                    }
                    i += 1;
                }
                let _ = start;
            }
            _ if depth == 1 && snbt[i..].starts_with(key) => {
                let rest = &snbt[i + key.len()..];
                let prev = bytes[i - 1];
                if (prev == b'{' || prev == b',') && rest.starts_with(":\"") {
                    let value = &rest[2..];
                    return value.find('"').map(|end| &value[..end]);
                }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// The yaw of an entity's SNBT (`Rotation:[yaw,pitch]`).
fn snbt_rotation(snbt: &str) -> Option<f32> {
    let at = snbt.find("Rotation:[")?;
    let rest = &snbt[at + "Rotation:[".len()..];
    let end = rest.find([',', ']'])?;
    rest[..end].trim_end_matches(['f', 'F']).parse().ok()
}

/// A block state as `BlockStateParser` reads one: `id[key=value,…]`.
pub(crate) fn parse_state(table: &BlockTable, text: &str) -> Option<u16> {
    let (name, properties) = match text.split_once('[') {
        Some((name, rest)) => (name, rest.strip_suffix(']')?),
        None => (text, ""),
    };
    let mut state = table.default_state(name).ok()?;
    for pair in properties.split(',').filter(|p| !p.is_empty()) {
        let (key, value) = pair.split_once('=')?;
        state = table.with(state, key.trim(), value.trim())?;
    }
    Some(state)
}

/// `BlockAgeProcessor.processBlock`'s replacement of a state, if any.
fn block_age(
    d: &Decoration,
    state: u16,
    mossiness: f32,
    random: &mut Random,
) -> Result<Option<u16>, String> {
    let table = d.table.as_ref();
    let block = table.block_of(state);
    let is = |name: &str| table.block(name).is_ok_and(|b| b == block);
    let pick = |random: &mut Random, options: &[u16]| {
        options[random.next_int_bounded(options.len() as i32) as usize]
    };
    let with_properties = |target: &str| -> Result<u16, String> {
        // `withPropertiesOf`: the target's default with every property the
        // source shares.
        let mut out = table.default_state(target)?;
        for property in table.property_names(state) {
            if let Some(v) = table.value(state, property) {
                out = table.with(out, property, v).unwrap_or(out);
            }
        }
        Ok(out)
    };
    let random_stairs = |random: &mut Random, name: &str| -> Result<u16, String> {
        let facing = ["north", "east", "south", "west"][random.next_int_bounded(4) as usize];
        let half = ["top", "bottom"][random.next_int_bounded(2) as usize];
        let s = table.default_state(name)?;
        let s = table.with(s, "facing", facing).ok_or("stairs facing")?;
        table
            .with(s, "half", half)
            .ok_or_else(|| "stairs half".to_string())
    };
    let mossy_or = |random: &mut Random, mossy: &[u16], plain: &[u16]| {
        if random.next_float() < mossiness {
            pick(random, mossy)
        } else {
            pick(random, plain)
        }
    };
    Ok(
        if is("stone_bricks") || is("stone") || is("chiseled_stone_bricks") {
            if random.next_float() >= 0.5 {
                return Ok(None);
            }
            let plain = [
                table.default_state("cracked_stone_bricks")?,
                random_stairs(random, "stone_brick_stairs")?,
            ];
            let mossy = [
                table.default_state("mossy_stone_bricks")?,
                random_stairs(random, "mossy_stone_brick_stairs")?,
            ];
            Some(mossy_or(random, &mossy, &plain))
        } else if table.in_tag(state, table.tag("minecraft:stairs")?) {
            if random.next_float() >= 0.5 {
                return Ok(None);
            }
            let plain = [
                table.default_state("stone_slab")?,
                table.default_state("stone_brick_slab")?,
            ];
            let mossy = [
                with_properties("mossy_stone_brick_stairs")?,
                table.default_state("mossy_stone_brick_slab")?,
            ];
            Some(mossy_or(random, &mossy, &plain))
        } else if table.in_tag(state, table.tag("minecraft:slabs")?) {
            (random.next_float() < mossiness)
                .then(|| with_properties("mossy_stone_brick_slab"))
                .transpose()?
        } else if table.in_tag(state, table.tag("minecraft:walls")?) {
            (random.next_float() < mossiness)
                .then(|| with_properties("mossy_stone_brick_wall"))
                .transpose()?
        } else if is("obsidian") {
            (random.next_float() < 0.15)
                .then(|| table.default_state("crying_obsidian"))
                .transpose()?
        } else {
            None
        },
    )
}

/// Structure templates (each decoded on first use), processor lists and
/// state transforms.
#[derive(Debug, Default)]
pub struct Templates {
    templates: HashMap<String, TemplateEntry>,
    lists: HashMap<String, Arc<Vec<Processor>>>,
    /// Per state that changes: clockwise 90, 180, counterclockwise 90,
    /// mirrored left-right and front-back.
    transforms: HashMap<u16, [u16; 5]>,
}

/// A template as the facts give it.
#[derive(Debug)]
struct TemplateEntry {
    size: [i32; 3],
    palettes: Vec<CompactPalette>,
    entities: Vec<TemplateEntity>,
    decoded: OnceLock<Arc<Template>>,
}

/// A palette as the facts encode it: its distinct states (with whether
/// `StructureTemplate` lists them first, as full blocks), its volume in
/// (y, x, z) order as runs of state index + 1 (0 where the template has no
/// block), and its block entities' NBT by cell.
#[derive(Debug)]
struct CompactPalette {
    states: Vec<(u16, bool)>,
    runs: Vec<(u32, u32)>,
    nbt: HashMap<u32, Arc<str>>,
}

impl CompactPalette {
    fn parse(json: &Json, size: [i32; 3]) -> Result<CompactPalette, String> {
        let states = json
            .field("states")?
            .as_array()?
            .iter()
            .map(|row| {
                let row = row.as_array()?;
                Ok((row[0].as_i32()? as u16, row[1].as_i32()? != 0))
            })
            .collect::<Result<Vec<_>, String>>()?;
        let flat = json.field("volume")?.as_array()?;
        let mut runs = Vec::with_capacity(flat.len() / 2);
        for pair in flat.chunks(2) {
            runs.push((pair[0].as_i32()? as u32, pair[1].as_i32()? as u32));
        }
        let mut nbt = HashMap::new();
        if let Some(rows) = json.get("nbt") {
            for row in rows.as_array()? {
                let row = row.as_array()?;
                let (x, y, z) = (row[0].as_i32()?, row[1].as_i32()?, row[2].as_i32()?);
                let cell = ((y * size[0] + x) * size[2] + z) as u32;
                nbt.insert(cell, Arc::from(row[3].as_str()?));
            }
        }
        Ok(CompactPalette { states, runs, nbt })
    }

    /// The palette's blocks in `StructureTemplate`'s order: full blocks,
    /// other blocks, then blocks with NBT, each in volume order.
    fn blocks(&self, size: [i32; 3]) -> Vec<TemplateBlock> {
        let position = |cell: u32| {
            let cell = cell as i32;
            let z = cell % size[2];
            let x = (cell / size[2]) % size[0];
            let y = cell / (size[2] * size[0]);
            [x, y, z]
        };
        let mut lists: [Vec<TemplateBlock>; 3] = Default::default();
        let mut cell = 0u32;
        for &(index, count) in &self.runs {
            if index == 0 {
                cell += count;
                continue;
            }
            let (state, full) = self.states[index as usize - 1];
            for _ in 0..count {
                let nbt = self.nbt.get(&cell);
                let class = if nbt.is_some() {
                    2
                } else if full {
                    0
                } else {
                    1
                };
                lists[class].push(TemplateBlock {
                    pos: position(cell),
                    state,
                    nbt: nbt.map(|s| EntityNbt::parse(s)),
                });
                cell += 1;
            }
        }
        let [mut full, other, entities] = lists;
        full.extend(other);
        full.extend(entities);
        full
    }
}

impl Templates {
    /// Every template of the vanilla data pack (`structure_templates.json`),
    /// the state transforms (`block_transforms.json`) and the processor
    /// lists (`processor_lists.json`).
    pub fn parse(
        templates: &Json,
        transforms: &Json,
        lists: &Json,
        table: &BlockTable,
    ) -> Result<Templates, String> {
        let mut out = Templates::default();
        for (id, entry) in templates.entries()? {
            let size = entry.field("size")?.as_array()?;
            let size = [size[0].as_i32()?, size[1].as_i32()?, size[2].as_i32()?];
            let palettes = entry
                .field("blocks")?
                .as_array()?
                .iter()
                .map(|p| CompactPalette::parse(p, size))
                .collect::<Result<Vec<_>, _>>()?;
            let entities = match entry.get("entities") {
                None => Vec::new(),
                Some(rows) => rows
                    .as_array()?
                    .iter()
                    .map(|row| {
                        let r = row.as_array()?;
                        Ok(TemplateEntity {
                            pos: [r[0].as_f64()?, r[1].as_f64()?, r[2].as_f64()?],
                            block_pos: [r[3].as_i32()?, r[4].as_i32()?, r[5].as_i32()?],
                            nbt: Arc::from(r[6].as_str()?),
                        })
                    })
                    .collect::<Result<Vec<_>, String>>()?,
            };
            out.templates.insert(
                id.clone(),
                TemplateEntry {
                    size,
                    palettes,
                    entities,
                    decoded: OnceLock::new(),
                },
            );
        }
        for row in transforms.field("transforms")?.as_array()? {
            let row = row.as_array()?;
            let id = |i: usize| row[i].as_i32().map(|v| v as u16);
            out.transforms
                .insert(id(0)?, [id(1)?, id(2)?, id(3)?, id(4)?, id(5)?]);
        }
        for (id, list) in lists.entries()? {
            // A list that this slice cannot place stays out; naming it fails.
            if let Ok(processors) = Self::parse_list(list, table) {
                out.lists.insert(id.clone(), Arc::new(processors));
            }
        }
        Ok(out)
    }

    fn parse_list(json: &Json, table: &BlockTable) -> Result<Vec<Processor>, String> {
        let items = match json {
            Json::Array(_) => json,
            _ => json.field("processors")?,
        };
        items
            .as_array()?
            .iter()
            .map(|p| Processor::parse(p, table))
            .collect()
    }

    /// A processor list: an identifier or an inline list.
    pub fn processors(
        &self,
        json: &Json,
        table: &BlockTable,
    ) -> Result<Arc<Vec<Processor>>, String> {
        match json {
            Json::String(id) => self
                .lists
                .get(id)
                .cloned()
                .ok_or_else(|| format!("processor list {id} is not available")),
            other => Ok(Arc::new(Self::parse_list(other, table)?)),
        }
    }

    /// A template, decoded once; one the pack lacks is empty, as
    /// `StructureTemplateManager.getOrCreate` makes it.
    /// A processor list's processors (an identifier or an inline list), as
    /// a structure piece's settings take them.
    pub fn processor_list(
        &self,
        json: &Json,
        table: &BlockTable,
    ) -> Result<Vec<Processor>, String> {
        Ok(self.processors(json, table)?.as_ref().clone())
    }

    pub fn template(&self, id: &str) -> Result<Arc<Template>, String> {
        let Some(entry) = self.templates.get(id) else {
            return Ok(Arc::new(Template::default()));
        };
        Ok(entry
            .decoded
            .get_or_init(|| {
                Arc::new(Template {
                    size: entry.size,
                    palettes: entry
                        .palettes
                        .iter()
                        .map(|p| p.blocks(entry.size))
                        .collect(),
                    entities: entry.entities.clone(),
                })
            })
            .clone())
    }

    /// `state.mirror(mirror).rotate(rotation)`; states without a row are
    /// their own transforms.
    pub fn transform_state(&self, state: u16, mirror: Mirror, rotation: Rotation) -> u16 {
        if mirror == Mirror::None && rotation == Rotation::None {
            return state;
        }
        let mirrored = match (mirror, self.transforms.get(&state)) {
            (Mirror::LeftRight, Some(row)) => row[3],
            (Mirror::FrontBack, Some(row)) => row[4],
            _ => state,
        };
        match (rotation, self.transforms.get(&mirrored)) {
            (Rotation::Clockwise90, Some(row)) => row[0],
            (Rotation::Clockwise180, Some(row)) => row[1],
            (Rotation::Counterclockwise90, Some(row)) => row[2],
            _ => mirrored,
        }
    }
}

/// `StructureTemplate.StructureBlockInfo`.
#[derive(Clone, Debug, PartialEq)]
struct BlockInfo {
    pos: [i32; 3],
    state: u16,
    nbt: Option<EntityNbt>,
}

/// A fluid as template placement reads it: source water and lava matter.
fn is_source(fluid: u8) -> bool {
    fluid == FLUID_WATER || fluid == FLUID_LAVA
}

/// `StructurePlaceSettings`.
pub struct PlaceSettings {
    pub mirror: Mirror,
    pub rotation: Rotation,
    pub pivot: [i32; 3],
    pub bounding_box: Option<BoundingBox>,
    pub processors: Arc<Vec<Processor>>,
    /// `setRandom`: features set the feature's random (palette and
    /// processors draw from it); structure pieces leave it unset, and each
    /// position seeds its own.
    pub shared_random: bool,
    pub ignore_entities: bool,
    pub finalize_entities: bool,
    /// `setKnownShape`: no shape updates after placing (jigsaw pieces).
    pub known_shape: bool,
    /// `LiquidSettings.APPLY_WATERLOGGING`.
    pub waterlogging: bool,
}

impl PlaceSettings {
    /// Settings as a feature makes them: its random shared, entities
    /// placed unfinalized, shapes updated, waterlogging applied.
    pub fn feature(
        rotation: Rotation,
        bounding_box: Option<BoundingBox>,
        processors: Arc<Vec<Processor>>,
    ) -> PlaceSettings {
        PlaceSettings {
            mirror: Mirror::None,
            rotation,
            pivot: [0, 0, 0],
            bounding_box,
            processors,
            shared_random: true,
            ignore_entities: false,
            finalize_entities: false,
            known_shape: false,
            waterlogging: true,
        }
    }

    /// Settings as a structure piece makes them: no shared random.
    pub fn piece(
        mirror: Mirror,
        rotation: Rotation,
        pivot: [i32; 3],
        processors: Vec<Processor>,
    ) -> PlaceSettings {
        PlaceSettings {
            mirror,
            rotation,
            pivot,
            bounding_box: None,
            processors: Arc::new(processors),
            shared_random: false,
            ignore_entities: false,
            finalize_entities: false,
            known_shape: false,
            waterlogging: true,
        }
    }

    /// `getRandom(pos)` when no random is shared.
    fn positional(pos: [i32; 3]) -> Random {
        Random::legacy(position_seed(pos[0], pos[1], pos[2]))
    }
}

/// `StructureTemplate.transform` of an entity position.
pub fn transform_vec(
    pos: [f64; 3],
    mirror: Mirror,
    rotation: Rotation,
    pivot: [i32; 3],
) -> [f64; 3] {
    let [mut x, y, mut z] = pos;
    match mirror {
        Mirror::LeftRight => z = 1.0 - z,
        Mirror::FrontBack => x = 1.0 - x,
        Mirror::None => {}
    }
    let (px, pz) = (pivot[0] as f64, pivot[2] as f64);
    match rotation {
        Rotation::Counterclockwise90 => [px - pz + z, y, px + pz + 1.0 - x],
        Rotation::Clockwise90 => [px + pz + 1.0 - z, y, pz - px + x],
        Rotation::Clockwise180 => [px + px + 1.0 - x, y, pz + pz + 1.0 - z],
        Rotation::None => [x, y, z],
    }
}

/// Block entities that take a loot seed when a template places them
/// (`RandomizableContainer`).
const RANDOMIZABLE: [&str; 9] = [
    "minecraft:chest",
    "minecraft:trapped_chest",
    "minecraft:barrel",
    "minecraft:dispenser",
    "minecraft:dropper",
    "minecraft:hopper",
    "minecraft:shulker_box",
    "minecraft:decorated_pot",
    "minecraft:crafter",
];

/// `Mth.wrapDegrees`.
fn wrap_degrees(angle: f32) -> f32 {
    let mut a = angle % 360.0;
    if a >= 180.0 {
        a -= 360.0;
    }
    if a < -180.0 {
        a += 360.0;
    }
    a
}

impl Templates {
    /// `StructureTemplate.processBlockInfos`: every block of the palette
    /// through the processors, then each processor's `finalizeProcessing`.
    fn process_blocks(
        &self,
        d: &Decoration,
        region: &mut Region,
        ctx: &ProcessContext,
        palette: &[TemplateBlock],
        random: &mut Random,
    ) -> Result<Vec<BlockInfo>, String> {
        let settings = ctx.settings;
        let mut original: Vec<&TemplateBlock> = Vec::with_capacity(palette.len());
        let mut processed = Vec::with_capacity(palette.len());
        // Only the blocks in the settings' box, unless a processor weighs
        // the whole piece (a capped processor).
        let whole = settings
            .processors
            .iter()
            .any(|p| matches!(p, Processor::Capped { .. }));
        for block in palette {
            let pos = offset(
                transform(
                    block.pos,
                    settings.mirror,
                    settings.rotation,
                    settings.pivot,
                ),
                ctx.position,
            );
            if !whole && settings.bounding_box.is_some_and(|b| !b.inside(pos)) {
                continue;
            }
            let mut info = Some(BlockInfo {
                pos,
                state: block.state,
                nbt: block.nbt.clone(),
            });
            for processor in settings.processors.iter() {
                let Some(current) = info else {
                    break;
                };
                let shared = settings.shared_random.then_some(&mut *random);
                info = processor.process(d, region, ctx, block, current, shared)?;
            }
            if let Some(info) = info {
                processed.push(info);
                original.push(block);
            }
        }
        for processor in settings.processors.iter() {
            processed = processor.finalize(d, region, ctx, &original, processed)?;
        }
        Ok(processed)
    }

    /// `StructureTemplate.placeInWorld`: a palette (the shared random's
    /// draw, or the position's) through the processors, its blocks inside
    /// the settings' box placed with their block entities, waterlogged as
    /// the fluid there allows, shapes updated at its edges unless known,
    /// then its entities.
    #[allow(clippy::too_many_arguments)]
    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        template: &Template,
        position: [i32; 3],
        reference: [i32; 3],
        settings: &PlaceSettings,
        random: &mut Random,
        update_mode: i32,
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        if template.palettes.is_empty() {
            return Ok(false);
        }
        let count = template.palettes.len() as i32;
        let index = if settings.shared_random {
            random.next_int_bounded(count)
        } else {
            PlaceSettings::positional(position).next_int_bounded(count)
        };
        let palette = &template.palettes[index as usize];
        let has_entities = !settings.ignore_entities && !template.entities.is_empty();
        if (palette.is_empty() && !has_entities) || template.size.iter().any(|&s| s < 1) {
            return Ok(false);
        }
        let ctx = ProcessContext {
            position,
            reference,
            settings,
            seed: region.seed,
        };
        let processed = self.process_blocks(d, region, &ctx, palette, random)?;
        let barrier = table.default_state("barrier")?;
        let mut to_fill: Vec<[i32; 3]> = Vec::new();
        let mut locked: Vec<[i32; 3]> = Vec::new();
        let mut placed: Vec<[i32; 3]> = Vec::new();
        let mut min = [i32::MAX; 3];
        let mut max = [i32::MIN; 3];
        for info in processed {
            let pos = info.pos;
            if settings.bounding_box.is_some_and(|b| !b.inside(pos)) {
                continue;
            }
            let previous = settings.waterlogging.then(|| table.fluid(region.get(pos)));
            let state = self.transform_state(info.state, settings.mirror, settings.rotation);
            if info.nbt.is_some() {
                region.set(pos, barrier, 820);
            }
            if !region.set(pos, state, update_mode) {
                continue;
            }
            for i in 0..3 {
                min[i] = min[i].min(pos[i]);
                max[i] = max[i].max(pos[i]);
            }
            placed.push(pos);
            if let Some(nbt) = &info.nbt {
                if let Some(be) = region.block_entity(pos)? {
                    let mut seed = nbt.loot_seed;
                    if RANDOMIZABLE.contains(&be.kind) {
                        seed = Some(random.next_long());
                    }
                    be.loot_table = nbt.loot_table.clone();
                    // A container loads the seed only with a loot table.
                    be.loot_seed = if be.loot_table.is_some() {
                        seed.unwrap_or(0)
                    } else {
                        0
                    };
                    be.nbt = nbt.snbt.clone();
                }
            }
            if let Some(previous) = previous {
                if is_source(table.fluid(state)) {
                    locked.push(pos);
                } else if table.flag(state, LIQUID_CONTAINER) {
                    self.place_liquid(table, region, pos, state, previous);
                    if !is_source(previous) {
                        to_fill.push(pos);
                    }
                }
            }
        }
        let mut filled = true;
        while filled && !to_fill.is_empty() {
            filled = false;
            let mut i = 0;
            while i < to_fill.len() {
                let pos = to_fill[i];
                let mut fluid = table.fluid(region.get(pos));
                for dir in [1, NORTH, EAST, SOUTH, WEST] {
                    if is_source(fluid) {
                        break;
                    }
                    let n = offset(pos, super::tree::STEP[dir]);
                    let neighbour = table.fluid(region.get(n));
                    if is_source(neighbour) && !locked.contains(&n) {
                        fluid = neighbour;
                    }
                }
                if is_source(fluid) {
                    let state = region.get(pos);
                    if table.flag(state, LIQUID_CONTAINER) {
                        self.place_liquid(table, region, pos, state, fluid);
                        filled = true;
                        to_fill.remove(i);
                        continue;
                    }
                }
                i += 1;
            }
        }
        if min[0] <= max[0] && !settings.known_shape {
            let mut shape = Shape::new(min, max);
            for pos in &placed {
                shape.fill(*pos);
            }
            super::tree::update_shape_at_edge(d, region, &shape)?;
            for pos in placed {
                let state = region.get(pos);
                let mut new_state = state;
                for dir in [WEST, EAST, NORTH, SOUTH, 0, 1] {
                    new_state = d.update_shape(region, new_state, pos, dir, None)?;
                }
                if state != new_state {
                    region.set(pos, new_state, (update_mode & !1) | 16);
                }
            }
        }
        if has_entities {
            self.place_entities(region, template, position, settings)?;
        }
        Ok(true)
    }

    /// `placeEntities`: each entity inside the box, its position and yaw
    /// turned with the template, recorded (type, position, yaw). Finalizing
    /// mobs is not modelled.
    fn place_entities(
        &self,
        region: &mut Region,
        template: &Template,
        position: [i32; 3],
        settings: &PlaceSettings,
    ) -> Result<(), String> {
        for entity in &template.entities {
            let block = offset(
                transform(
                    entity.block_pos,
                    settings.mirror,
                    settings.rotation,
                    settings.pivot,
                ),
                position,
            );
            if settings.bounding_box.is_some_and(|b| !b.inside(block)) {
                continue;
            }
            let rel = transform_vec(
                entity.pos,
                settings.mirror,
                settings.rotation,
                settings.pivot,
            );
            let pos = [
                rel[0] + position[0] as f64,
                rel[1] + position[1] as f64,
                rel[2] + position[2] as f64,
            ];
            let kind = snbt_string(&entity.nbt, "id").ok_or("a template entity without an id")?;
            let yaw = snbt_rotation(&entity.nbt).unwrap_or(0.0);
            // `Entity.rotate` and `mirror` (hanging entities turn by their
            // direction instead; none of the templates holds one).
            let mut turned = wrap_degrees(yaw)
                + match settings.rotation {
                    Rotation::None => 0.0,
                    Rotation::Clockwise90 => 90.0,
                    Rotation::Clockwise180 => 180.0,
                    Rotation::Counterclockwise90 => 270.0,
                };
            let mirrored = match settings.mirror {
                Mirror::None => wrap_degrees(yaw),
                Mirror::LeftRight => 180.0 - wrap_degrees(yaw),
                Mirror::FrontBack => -wrap_degrees(yaw),
            };
            turned += mirrored - yaw;
            region.add_entity(super::region::Entity {
                kind: super::region::entity_kind(kind),
                pos,
                yaw: turned,
            });
            if settings.finalize_entities {
                super::structure::mobs::finalize_template(region, kind, &entity.nbt)?;
            }
        }
        Ok(())
    }
}

impl Templates {
    /// `StructureTemplate.filterBlocks`: the blocks of `block` in the
    /// palette placement picks (by the position, structure pieces share no
    /// random), at their world positions, inside the settings' box.
    pub fn filter_blocks(
        &self,
        table: &BlockTable,
        template: &Template,
        position: [i32; 3],
        settings: &PlaceSettings,
        block: u16,
    ) -> Vec<([i32; 3], u16, Option<EntityNbt>)> {
        if template.palettes.is_empty() {
            return Vec::new();
        }
        let count = template.palettes.len() as i32;
        let palette = &template.palettes
            [PlaceSettings::positional(position).next_int_bounded(count) as usize];
        palette
            .iter()
            .filter(|b| table.block_of(b.state) == block)
            .filter_map(|b| {
                let pos = offset(
                    transform(b.pos, settings.mirror, settings.rotation, settings.pivot),
                    position,
                );
                if settings.bounding_box.is_some_and(|bb| !bb.inside(pos)) {
                    return None;
                }
                let state = self.transform_state(b.state, Mirror::None, settings.rotation);
                Some((pos, state, b.nbt.clone()))
            })
            .collect()
    }

    /// `LiquidBlockContainer.placeLiquid`: a simple waterlogged block takes
    /// source water; other containers take nothing.
    fn place_liquid(
        &self,
        table: &BlockTable,
        region: &mut Region,
        pos: [i32; 3],
        state: u16,
        fluid: u8,
    ) {
        if !table.flag(state, SIMPLE_WATERLOGGED) || fluid != FLUID_WATER {
            return;
        }
        if table.value(state, "waterlogged") != Some("false") {
            return;
        }
        if let Some(wet) = table.with(state, "waterlogged", "true") {
            region.set(pos, wet, 3);
            region.schedule_fluid_tick(pos, FLUID_WATER);
        }
    }
}

/// `TemplateFeature`.
#[derive(Debug)]
pub struct TemplateFeature {
    entries: Vec<(String, Vec<Rotation>, i32)>,
    total: i32,
    processors: Arc<Vec<Processor>>,
}

impl TemplateFeature {
    pub fn parse(
        json: &Json,
        table: &BlockTable,
        templates: &Templates,
    ) -> Result<TemplateFeature, String> {
        let mut entries = Vec::new();
        let mut total = 0;
        for entry in json.field("templates")?.as_array()? {
            let data = entry.field("data")?;
            let id = data.field("id")?.as_str()?.to_string();
            templates.template(&id)?;
            let rotations = match data.get("rotations") {
                Some(list) => list
                    .as_array()?
                    .iter()
                    .map(|r| Rotation::parse(r.as_str()?))
                    .collect::<Result<_, _>>()?,
                None => ROTATIONS.to_vec(),
            };
            let weight = entry.field("weight")?.as_i32()?;
            total += weight;
            entries.push((id, rotations, weight));
        }
        Ok(TemplateFeature {
            entries,
            total,
            processors: match json.get("processors") {
                Some(p) => templates.processors(p, table)?,
                None => Arc::new(Vec::new()),
            },
        })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let mut pick = random.next_int_bounded(self.total);
        let (id, rotations, _) = self
            .entries
            .iter()
            .find(|(_, _, w)| {
                pick -= w;
                pick < 0
            })
            .ok_or("template weights")?;
        let rotation = rotations[random.next_int_bounded(rotations.len() as i32) as usize];
        let templates = d.templates()?;
        let template = templates.template(id)?;
        let step = |dir: usize, n: i32| {
            let s = super::tree::STEP[rotation.rotate(dir)];
            [s[0] * n, s[1] * n, s[2] * n]
        };
        let pos = offset(
            offset(origin, step(WEST, template.size[0] / 2)),
            step(NORTH, template.size[2] / 2),
        );
        let settings = PlaceSettings::feature(rotation, None, self.processors.clone());
        templates.place(d, region, &template, pos, pos, &settings, random, 3)
    }
}

/// `FossilFeature`.
#[derive(Debug)]
pub struct Fossil {
    fossils: Vec<String>,
    overlays: Vec<String>,
    fossil_processors: Arc<Vec<Processor>>,
    overlay_processors: Arc<Vec<Processor>>,
    max_empty_corners: i32,
    water: u16,
    lava: u16,
}

impl Fossil {
    pub fn parse(json: &Json, table: &BlockTable, templates: &Templates) -> Result<Fossil, String> {
        let ids = |k: &str| -> Result<Vec<String>, String> {
            json.field(k)?
                .as_array()?
                .iter()
                .map(|t| {
                    let id = t.as_str()?.to_string();
                    templates.template(&id)?;
                    Ok(id)
                })
                .collect()
        };
        Ok(Fossil {
            fossils: ids("fossil_structures")?,
            overlays: ids("overlay_structures")?,
            fossil_processors: templates.processors(json.field("fossil_processors")?, table)?,
            overlay_processors: templates.processors(json.field("overlay_processors")?, table)?,
            max_empty_corners: json.field("max_empty_corners_allowed")?.as_i32()?,
            water: table.block("water")?,
            lava: table.block("lava")?,
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
        let rotation = ROTATIONS[random.next_int_bounded(4) as usize];
        let index = random.next_int_bounded(self.fossils.len() as i32) as usize;
        let templates = d.templates()?;
        let base = templates.template(&self.fossils[index])?;
        let overlay = templates.template(&self.overlays[index])?;
        let (cx, cz) = (origin[0] >> 4, origin[2] >> 4);
        let min_y = region.min_y();
        let max_y = min_y + region.height() - 1;
        let bounding_box = BoundingBox {
            min: [cx * 16 - 16, min_y, cz * 16 - 16],
            max: [cx * 16 + 15 + 16, max_y, cz * 16 + 15 + 16],
        };
        let mut settings =
            PlaceSettings::feature(rotation, Some(bounding_box), Arc::new(Vec::new()));
        let size = base.size(rotation);
        let low = offset(origin, [-size[0] / 2, 0, -size[2] / 2]);
        let mut lowest = origin[1];
        for x in 0..size[0] {
            for z in 0..size[2] {
                lowest =
                    lowest.min(region.height_at(Heightmap::OceanFloorWg, low[0] + x, low[2] + z));
            }
        }
        let target_y = (lowest - 15 - random.next_int_bounded(10)).max(min_y + 10);
        let target = base.zero_position([low[0], target_y, low[2]], Mirror::None, rotation);
        let empty = base
            .bounding_box(&settings, target)
            .corners()
            .iter()
            .filter(|&&c| {
                let s = region.get(c);
                let b = table.block_of(s);
                table.is_air(s) || b == self.lava || b == self.water
            })
            .count() as i32;
        if empty > self.max_empty_corners {
            return Ok(false);
        }
        settings.processors = self.fossil_processors.clone();
        templates.place(d, region, &base, target, target, &settings, random, 260)?;
        settings.processors = self.overlay_processors.clone();
        templates.place(d, region, &overlay, target, target, &settings, random, 260)?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transforms_follow_vanilla() {
        let p = [2, 5, 3];
        let pivot = [0, 0, 0];
        assert_eq!(transform(p, Mirror::None, Rotation::None, pivot), p);
        assert_eq!(
            transform(p, Mirror::None, Rotation::Clockwise90, pivot),
            [-3, 5, 2]
        );
        assert_eq!(
            transform(p, Mirror::None, Rotation::Clockwise180, pivot),
            [-2, 5, -3]
        );
        assert_eq!(
            transform(p, Mirror::None, Rotation::Counterclockwise90, pivot),
            [3, 5, -2]
        );
        assert_eq!(
            transform(p, Mirror::LeftRight, Rotation::None, pivot),
            [2, 5, -3]
        );
        assert_eq!(
            transform(p, Mirror::FrontBack, Rotation::None, pivot),
            [-2, 5, 3]
        );
        // Rotations of horizontal directions (north, east, south, west).
        assert_eq!(Rotation::Clockwise90.rotate(NORTH), EAST);
        assert_eq!(Rotation::Counterclockwise90.rotate(NORTH), WEST);
        assert_eq!(Rotation::Counterclockwise90.rotate(WEST), SOUTH);
        assert_eq!(Rotation::Clockwise180.rotate(EAST), WEST);
    }

    #[test]
    fn zero_positions_and_boxes() {
        let template = Template {
            size: [3, 2, 5],
            palettes: vec![],
            entities: vec![],
        };
        let zero = [10, 0, 20];
        assert_eq!(
            template.zero_position(zero, Mirror::None, Rotation::None),
            zero
        );
        assert_eq!(
            template.zero_position(zero, Mirror::None, Rotation::Clockwise90),
            [14, 0, 20]
        );
        assert_eq!(
            template.zero_position(zero, Mirror::None, Rotation::Clockwise180),
            [12, 0, 24]
        );
        assert_eq!(
            template.zero_position(zero, Mirror::None, Rotation::Counterclockwise90),
            [10, 0, 22]
        );
        let settings = PlaceSettings::feature(Rotation::Clockwise90, None, Arc::new(Vec::new()));
        let b = template.bounding_box(&settings, [14, 0, 20]);
        assert_eq!(b.min, [10, 0, 20]);
        assert_eq!(b.max, [14, 1, 22]);
        assert_eq!(template.size(Rotation::Clockwise90), [5, 2, 3]);
    }

    #[test]
    fn entity_nbt_reads_loot() {
        let nbt = EntityNbt::parse(
            r#"{LootTable:"minecraft:chests/x",LootTableSeed:-42L,id:"minecraft:chest"}"#,
        );
        assert_eq!(nbt.loot_table.as_deref(), Some("minecraft:chests/x"));
        assert_eq!(nbt.loot_seed, Some(-42));
        let empty = EntityNbt::parse(r#"{components:{},id:"minecraft:brushable_block"}"#);
        assert!(empty.loot_table.is_none() && empty.loot_seed.is_none());
    }
}
