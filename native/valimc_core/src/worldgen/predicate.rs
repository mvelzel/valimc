//! Vanilla's block predicates (`levelgen.blockpredicates`) and rule tests
//! (`structure.templatesystem`), as 26.3's codecs write them.

use super::blocks::{BlockSet, BlockTable, REPLACEABLE, SOLID, STURDY};
use super::feature::Decoration;
use super::json::Json;
use super::random::Random;
use super::region::Region;
use super::surface::Anchor;

/// `Direction` by its serialized name, as an index (down, up, north, south,
/// west, east) and step.
pub fn direction(name: &str) -> Result<(usize, [i32; 3]), String> {
    Ok(match name {
        "down" => (0, [0, -1, 0]),
        "up" => (1, [0, 1, 0]),
        "north" => (2, [0, 0, -1]),
        "south" => (3, [0, 0, 1]),
        "west" => (4, [-1, 0, 0]),
        "east" => (5, [1, 0, 0]),
        other => return Err(format!("unknown direction {other}")),
    })
}

pub fn offset(pos: [i32; 3], by: [i32; 3]) -> [i32; 3] {
    [pos[0] + by[0], pos[1] + by[1], pos[2] + by[2]]
}

fn vec3(json: Option<&Json>) -> Result<[i32; 3], String> {
    match json {
        None => Ok([0; 3]),
        Some(v) => {
            let v = v.as_array()?;
            Ok([v[0].as_i32()?, v[1].as_i32()?, v[2].as_i32()?])
        }
    }
}

#[derive(Clone, Debug)]
pub enum BlockPredicate {
    True,
    Not(Box<BlockPredicate>),
    AllOf(Vec<BlockPredicate>),
    AnyOf(Vec<BlockPredicate>),
    MatchingBlocks([i32; 3], BlockSet),
    MatchingFluids([i32; 3], Vec<u8>),
    Replaceable([i32; 3]),
    Solid([i32; 3]),
    HasSturdyFace([i32; 3], usize),
    WouldSurvive([i32; 3], u16),
    InsideWorldBounds([i32; 3]),
    Unobstructed,
    HeightRange(Anchor, Anchor),
    VolumeMatch([i32; 3], [i32; 3], Box<BlockPredicate>),
}

impl BlockPredicate {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<BlockPredicate, String> {
        let off = || vec3(json.get("offset"));
        let list = |key: &str| {
            json.field(key)?
                .as_array()?
                .iter()
                .map(|p| BlockPredicate::parse(p, table))
                .collect::<Result<Vec<_>, _>>()
        };
        Ok(match json.field("type")?.as_str()? {
            "minecraft:true" => BlockPredicate::True,
            "minecraft:not" => BlockPredicate::Not(Box::new(BlockPredicate::parse(
                json.field("predicate")?,
                table,
            )?)),
            "minecraft:all_of" => BlockPredicate::AllOf(list("predicates")?),
            "minecraft:any_of" => BlockPredicate::AnyOf(list("predicates")?),
            "minecraft:matching_blocks" => {
                BlockPredicate::MatchingBlocks(off()?, table.block_set(json.field("blocks")?)?)
            }
            "minecraft:matching_block_tag" => BlockPredicate::MatchingBlocks(
                off()?,
                table.tag(json.field("tag")?.as_str()?)?.clone(),
            ),
            "minecraft:matching_fluids" => {
                BlockPredicate::MatchingFluids(off()?, table.fluid_set(json.field("fluids")?)?)
            }
            "minecraft:replaceable" => BlockPredicate::Replaceable(off()?),
            "minecraft:solid" => BlockPredicate::Solid(off()?),
            "minecraft:has_sturdy_face" => BlockPredicate::HasSturdyFace(
                off()?,
                direction(json.field("direction")?.as_str()?)?.0,
            ),
            "minecraft:would_survive" => {
                BlockPredicate::WouldSurvive(off()?, table.state(json.field("state")?)?)
            }
            "minecraft:inside_world_bounds" => BlockPredicate::InsideWorldBounds(off()?),
            "minecraft:unobstructed" => BlockPredicate::Unobstructed,
            "minecraft:height_range" => BlockPredicate::HeightRange(
                Anchor::parse_json(json.field("min_inclusive")?)?,
                Anchor::parse_json(json.field("max_inclusive")?)?,
            ),
            "minecraft:volume_match" => BlockPredicate::VolumeMatch(
                vec3(Some(json.field("min")?))?,
                vec3(Some(json.field("max")?))?,
                Box::new(BlockPredicate::parse(json.field("match")?, table)?),
            ),
            other => return Err(format!("unknown block predicate {other}")),
        })
    }

    pub fn test(&self, d: &Decoration, region: &mut Region, pos: [i32; 3]) -> bool {
        match self {
            BlockPredicate::True | BlockPredicate::Unobstructed => true,
            BlockPredicate::Not(p) => !p.test(d, region, pos),
            BlockPredicate::AllOf(ps) => ps.iter().all(|p| p.test(d, region, pos)),
            BlockPredicate::AnyOf(ps) => ps.iter().any(|p| p.test(d, region, pos)),
            BlockPredicate::MatchingBlocks(o, set) => {
                let state = region.get(offset(pos, *o));
                d.table.in_tag(state, set)
            }
            BlockPredicate::MatchingFluids(o, fluids) => {
                let state = region.get(offset(pos, *o));
                fluids.contains(&d.table.fluid(state))
            }
            BlockPredicate::Replaceable(o) => {
                let state = region.get(offset(pos, *o));
                d.table.flag(state, REPLACEABLE)
            }
            BlockPredicate::Solid(o) => {
                let state = region.get(offset(pos, *o));
                d.table.flag(state, SOLID)
            }
            BlockPredicate::HasSturdyFace(o, dir) => {
                let state = region.get(offset(pos, *o));
                d.table.flag(state, STURDY << dir)
            }
            BlockPredicate::WouldSurvive(o, state) => d.survives(region, *state, offset(pos, *o)),
            BlockPredicate::InsideWorldBounds(o) => !region.is_outside_build_height(pos[1] + o[1]),
            BlockPredicate::HeightRange(min, max) => {
                let c = d.context();
                pos[1] >= c.resolve(*min) && pos[1] <= c.resolve(*max)
            }
            BlockPredicate::VolumeMatch(min, max, p) => {
                for ox in min[0]..=max[0] {
                    for oz in min[2]..=max[2] {
                        for oy in min[1]..=max[1] {
                            if !p.test(d, region, offset(pos, [ox, oy, oz])) {
                                return false;
                            }
                        }
                    }
                }
                true
            }
        }
    }
}

/// A rule test (`RuleTest`), testing a state at a position.
#[derive(Clone, Debug)]
pub enum RuleTest {
    AlwaysTrue,
    AllOf(Vec<RuleTest>),
    AnyOf(Vec<RuleTest>),
    Not(Box<RuleTest>),
    Block(u16),
    State(u16),
    Tag(BlockSet),
    Height(i32, i32),
    RandomBlock(u16, f32),
    RandomState(u16, f32),
}

impl RuleTest {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<RuleTest, String> {
        let list = || {
            json.field("rules")?
                .as_array()?
                .iter()
                .map(|r| RuleTest::parse(r, table))
                .collect::<Result<Vec<_>, _>>()
        };
        let probability = || Ok::<f32, String>(json.field("probability")?.as_f64()? as f32);
        Ok(match json.field("predicate_type")?.as_str()? {
            "minecraft:always_true" => RuleTest::AlwaysTrue,
            "minecraft:all_of" => RuleTest::AllOf(list()?),
            "minecraft:any_of" => RuleTest::AnyOf(list()?),
            "minecraft:not" => {
                RuleTest::Not(Box::new(RuleTest::parse(json.field("rule")?, table)?))
            }
            "minecraft:block_match" => {
                RuleTest::Block(table.block(json.field("block")?.as_str()?)?)
            }
            "minecraft:blockstate_match" => {
                RuleTest::State(table.state(json.field("block_state")?)?)
            }
            "minecraft:tag_match" => {
                RuleTest::Tag(table.tag(json.field("tag")?.as_str()?)?.clone())
            }
            "minecraft:height_match" => RuleTest::Height(
                json.field("min_inclusive")?.as_i32()?,
                json.field("max_inclusive")?.as_i32()?,
            ),
            "minecraft:random_block_match" => {
                RuleTest::RandomBlock(table.block(json.field("block")?.as_str()?)?, probability()?)
            }
            "minecraft:random_blockstate_match" => {
                RuleTest::RandomState(table.state(json.field("block_state")?)?, probability()?)
            }
            other => return Err(format!("unknown rule test {other}")),
        })
    }

    pub fn test(&self, table: &BlockTable, state: u16, pos: [i32; 3], random: &mut Random) -> bool {
        match self {
            RuleTest::AlwaysTrue => true,
            RuleTest::AllOf(rules) => rules.iter().all(|r| r.test(table, state, pos, random)),
            RuleTest::AnyOf(rules) => rules.iter().any(|r| r.test(table, state, pos, random)),
            RuleTest::Not(rule) => !rule.test(table, state, pos, random),
            RuleTest::Block(block) => table.block_of(state) == *block,
            RuleTest::State(s) => state == *s,
            RuleTest::Tag(set) => table.in_tag(state, set),
            RuleTest::Height(min, max) => *min <= pos[1] && pos[1] <= *max,
            RuleTest::RandomBlock(block, p) => {
                table.block_of(state) == *block && random.next_float() < *p
            }
            RuleTest::RandomState(s, p) => state == *s && random.next_float() < *p,
        }
    }
}
