//! Placed features and placement modifiers (`levelgen.placement`), and
//! vanilla's `FeaturePlacer`: modifiers applied depth first, each modifier
//! producing all its positions before the first is followed further.

use std::sync::Arc;

use super::blocks::{BlockTable, Heightmap};
use super::feature::{Decoration, Feature};
use super::json::Json;
use super::predicate::BlockPredicate;
use super::providers::{HeightProvider, IntProvider};
use super::random::Random;
use super::region::Region;

#[derive(Debug)]
pub enum Modifier {
    Count(IntProvider),
    InSquare,
    Biome,
    Heightmap(Heightmap),
    HeightRange(HeightProvider),
    Rarity(i32),
    Offset(IntProvider, IntProvider, IntProvider),
    Filter(BlockPredicate),
    SurfaceWaterDepth(i32),
    EnvironmentScan {
        step: [i32; 3],
        target: BlockPredicate,
        allowed: BlockPredicate,
        max_steps: i32,
    },
    NoiseThresholdCount {
        level: f64,
        below: i32,
        above: i32,
    },
    NoiseBasedCount {
        ratio: i32,
        factor: f64,
        offset: f64,
    },
    SurfaceRelativeThreshold {
        heightmap: Heightmap,
        min: i32,
        max: i32,
    },
    RandomChance(f32),
    Fixed(Vec<[i32; 3]>),
    RandomlySelected(Vec<Modifier>),
    /// A modifier this slice does not implement; applying it fails.
    Unsupported(String),
}

impl Modifier {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<Modifier, String> {
        let i = |k: &str| json.field(k)?.as_i32();
        Ok(match json.field("type")?.as_str()? {
            "minecraft:count" => Modifier::Count(IntProvider::parse(json.field("count")?)?),
            "minecraft:in_square" => Modifier::InSquare,
            "minecraft:biome" => Modifier::Biome,
            "minecraft:heightmap" => {
                Modifier::Heightmap(Heightmap::parse(json.field("heightmap")?.as_str()?)?)
            }
            "minecraft:height_range" => {
                Modifier::HeightRange(HeightProvider::parse(json.field("height")?)?)
            }
            "minecraft:rarity_filter" => Modifier::Rarity(i("chance")?),
            "minecraft:offset" => {
                let p = |k: &str| match json.get(k) {
                    Some(v) => IntProvider::parse(v),
                    None => Ok(IntProvider::Constant(0)),
                };
                Modifier::Offset(p("x")?, p("y")?, p("z")?)
            }
            "minecraft:block_predicate_filter" => {
                Modifier::Filter(BlockPredicate::parse(json.field("predicate")?, table)?)
            }
            "minecraft:surface_water_depth_filter" => {
                Modifier::SurfaceWaterDepth(i("max_water_depth")?)
            }
            "minecraft:environment_scan" => Modifier::EnvironmentScan {
                step: super::predicate::direction(json.field("direction_of_search")?.as_str()?)?.1,
                target: BlockPredicate::parse(json.field("target_condition")?, table)?,
                allowed: match json.get("allowed_search_condition") {
                    Some(p) => BlockPredicate::parse(p, table)?,
                    None => BlockPredicate::True,
                },
                max_steps: i("max_steps")?,
            },
            "minecraft:noise_threshold_count" => Modifier::NoiseThresholdCount {
                level: json.field("noise_level")?.as_f64()?,
                below: i("below_noise")?,
                above: i("above_noise")?,
            },
            "minecraft:noise_based_count" => Modifier::NoiseBasedCount {
                ratio: i("noise_to_count_ratio")?,
                factor: json.field("noise_factor")?.as_f64()?,
                offset: json.get("noise_offset").map_or(Ok(0.0), Json::as_f64)?,
            },
            "minecraft:surface_relative_threshold_filter" => Modifier::SurfaceRelativeThreshold {
                heightmap: Heightmap::parse(json.field("heightmap")?.as_str()?)?,
                min: json
                    .get("min_inclusive")
                    .map_or(Ok(i32::MIN), Json::as_i32)?,
                max: json
                    .get("max_inclusive")
                    .map_or(Ok(i32::MAX), Json::as_i32)?,
            },
            "minecraft:random_chance" => {
                Modifier::RandomChance(json.field("chance")?.as_f64()? as f32)
            }
            "minecraft:fixed_placement" => Modifier::Fixed(
                json.field("positions")?
                    .as_array()?
                    .iter()
                    .map(|p| {
                        let p = p.as_array()?;
                        Ok([p[0].as_i32()?, p[1].as_i32()?, p[2].as_i32()?])
                    })
                    .collect::<Result<_, String>>()?,
            ),
            "minecraft:randomly_selected" => Modifier::RandomlySelected(
                json.field("placements")?
                    .as_array()?
                    .iter()
                    .map(|m| Modifier::parse(m, table))
                    .collect::<Result<_, _>>()?,
            ),
            other => Modifier::Unsupported(other.to_string()),
        })
    }

    /// `modify`: the positions this modifier makes of `origin`, appended to
    /// `out` in vanilla's order.
    pub fn modify(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
        top: Option<&str>,
        out: &mut Vec<[i32; 3]>,
    ) -> Result<(), String> {
        match self {
            Modifier::Count(count) => {
                let n = count.sample(random);
                out.extend(std::iter::repeat_n(origin, n.max(0) as usize));
            }
            Modifier::InSquare => {
                let x = random.next_int_bounded(16) + origin[0];
                let z = random.next_int_bounded(16) + origin[2];
                out.push([x, origin[1], z]);
            }
            Modifier::Biome => {
                let top = top.ok_or("biome check of a feature without a registry entry")?;
                let biome = region.biome(origin);
                if d.biome_has_feature(biome, top) {
                    out.push(origin);
                }
            }
            Modifier::Heightmap(kind) => {
                let height = region.height_at(*kind, origin[0], origin[2]);
                if height > region.min_y() {
                    out.push([origin[0], height, origin[2]]);
                }
            }
            Modifier::HeightRange(height) => {
                let y = height.sample(random, d.context());
                out.push([origin[0], y, origin[2]]);
            }
            Modifier::Rarity(chance) => {
                if random.next_float() < 1.0 / *chance as f32 {
                    out.push(origin);
                }
            }
            Modifier::Offset(x, y, z) => {
                let (dx, dy, dz) = (x.sample(random), y.sample(random), z.sample(random));
                out.push([origin[0] + dx, origin[1] + dy, origin[2] + dz]);
            }
            Modifier::Filter(predicate) => {
                if predicate.test(d, region, origin) {
                    out.push(origin);
                }
            }
            Modifier::SurfaceWaterDepth(max) => {
                let floor = region.height_at(Heightmap::OceanFloor, origin[0], origin[2]);
                let surface = region.height_at(Heightmap::WorldSurface, origin[0], origin[2]);
                if surface - floor <= *max {
                    out.push(origin);
                }
            }
            Modifier::EnvironmentScan {
                step,
                target,
                allowed,
                max_steps,
            } => {
                let mut pos = origin;
                if allowed.test(d, region, pos) {
                    for _ in 0..*max_steps {
                        if target.test(d, region, pos) {
                            out.push(pos);
                            return Ok(());
                        }
                        pos = [pos[0] + step[0], pos[1] + step[1], pos[2] + step[2]];
                        if region.is_outside_build_height(pos[1]) {
                            return Ok(());
                        }
                        if !allowed.test(d, region, pos) {
                            break;
                        }
                    }
                    if target.test(d, region, pos) {
                        out.push(pos);
                    }
                }
            }
            Modifier::NoiseThresholdCount {
                level,
                below,
                above,
            } => {
                let noise = super::surface::biome_info_noise(
                    origin[0] as f64 / 200.0,
                    origin[2] as f64 / 200.0,
                ) as f64;
                let n = if noise < *level { *below } else { *above };
                out.extend(std::iter::repeat_n(origin, n.max(0) as usize));
            }
            Modifier::NoiseBasedCount {
                ratio,
                factor,
                offset,
            } => {
                let noise = super::surface::biome_info_noise(
                    origin[0] as f64 / factor,
                    origin[2] as f64 / factor,
                ) as f64;
                let n = ((noise + offset) * *ratio as f64).ceil() as i32;
                out.extend(std::iter::repeat_n(origin, n.max(0) as usize));
            }
            Modifier::SurfaceRelativeThreshold {
                heightmap,
                min,
                max,
            } => {
                let surface = region.height_at(*heightmap, origin[0], origin[2]) as i64;
                let y = origin[1] as i64;
                if surface + *min as i64 <= y && y <= surface + *max as i64 {
                    out.push(origin);
                }
            }
            Modifier::RandomChance(chance) => {
                if random.next_float() < *chance {
                    out.push(origin);
                }
            }
            Modifier::Fixed(positions) => {
                let (cx, cz) = (origin[0] >> 4, origin[2] >> 4);
                out.extend(
                    positions
                        .iter()
                        .filter(|p| p[0] >> 4 == cx && p[2] >> 4 == cz),
                );
            }
            Modifier::Unsupported(kind) => {
                return Err(format!("placement modifier {kind} is not implemented"));
            }
            Modifier::RandomlySelected(placements) => {
                let pick = random.next_int_bounded(placements.len() as i32) as usize;
                placements[pick].modify(d, region, random, origin, top, out)?;
            }
        }
        Ok(())
    }
}

#[derive(Debug)]
pub struct PlacedFeature {
    /// The registry identifier, for top-level biome checks.
    pub id: Option<String>,
    pub feature: Arc<Feature>,
    pub placement: Vec<Modifier>,
}

impl PlacedFeature {
    /// `FeaturePlacer.place`: `top` is the placed feature's identifier when
    /// the biome is checked (`placeWithBiomeCheck`).
    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
        biome_check: bool,
    ) -> Result<bool, String> {
        let top = if biome_check {
            self.id.as_deref()
        } else {
            None
        };
        if self.placement.is_empty() {
            return self.feature.place(d, region, random, origin);
        }
        let mut placed = false;
        let mut stack: Vec<([i32; 3], usize)> = vec![(origin, 0)];
        let mut out = Vec::new();
        while let Some((pos, index)) = stack.pop() {
            out.clear();
            self.placement[index].modify(d, region, random, pos, top, &mut out)?;
            if index + 1 < self.placement.len() {
                for p in out.iter().rev() {
                    stack.push((*p, index + 1));
                }
            } else {
                for p in out.iter() {
                    placed |= self.feature.place(d, region, random, *p)?;
                }
            }
        }
        Ok(placed)
    }
}
