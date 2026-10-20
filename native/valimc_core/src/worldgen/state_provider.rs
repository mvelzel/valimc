//! Vanilla's block state providers (`feature.stateproviders`): a plain state
//! or a typed provider, by registry reference or inline.

use std::sync::Arc;

use super::blocks::BlockTable;
use super::feature::Decoration;
use super::json::Json;
use super::noise::{NormalNoise, Stack};
use super::predicate::BlockPredicate;
use super::providers::{IntProvider, Weighted};
use super::random::Random;
use super::region::Region;

#[derive(Debug)]
pub enum StateProvider {
    Simple(u16),
    Weighted(Weighted<u16>),
    RuleBased {
        fallback: Option<Arc<StateProvider>>,
        rules: Vec<(BlockPredicate, Arc<StateProvider>)>,
    },
    Rotated {
        state: Arc<StateProvider>,
        /// A fixed direction index, or a random one.
        direction: Option<usize>,
    },
    RandomizedInt {
        source: Arc<StateProvider>,
        property: String,
        values: IntProvider,
    },
    Noise {
        noise: Stack,
        scale: f32,
        states: Vec<u16>,
    },
    NoiseThreshold {
        noise: Stack,
        scale: f32,
        threshold: f32,
        high_chance: f32,
        default: u16,
        low: Vec<u16>,
        high: Vec<u16>,
    },
    DualNoise {
        variety: (i32, i32),
        slow: Stack,
        slow_scale: f32,
        noise: Stack,
        scale: f32,
        states: Vec<u16>,
    },
    RandomBlock(Vec<u16>),
    CopyProperties(Arc<StateProvider>),
}

/// Parses a provider: a state, a typed provider, or a registry identifier.
pub fn parse(
    json: &Json,
    table: &BlockTable,
    registry: &dyn Fn(&str) -> Result<Arc<StateProvider>, String>,
) -> Result<Arc<StateProvider>, String> {
    if let Json::String(id) = json {
        // A registry reference or a block's default state.
        if let Ok(provider) = registry(id) {
            return Ok(provider);
        }
        return Ok(Arc::new(StateProvider::Simple(table.state(json)?)));
    }
    let Some(kind) = json.get("type") else {
        return Ok(Arc::new(StateProvider::Simple(table.state(json)?)));
    };
    let sub = |key: &str| parse(json.field(key)?, table, registry);
    let states = |key: &str| {
        json.field(key)?
            .as_array()?
            .iter()
            .map(|s| table.state(s))
            .collect::<Result<Vec<_>, _>>()
    };
    let noise = |key: &str| -> Result<Stack, String> {
        let seed = json.field("seed")?.as_f64()? as i64;
        Ok(NormalNoise::parse(json.field(key)?)?.create(&mut Random::legacy(seed)))
    };
    let float = |key: &str| Ok::<f32, String>(json.field(key)?.as_f64()? as f32);
    Ok(Arc::new(match kind.as_str()? {
        "minecraft:simple" => StateProvider::Simple(table.state(json.field("state")?)?),
        "minecraft:weighted" => {
            StateProvider::Weighted(Weighted::parse(json.field("entries")?, |s| table.state(s))?)
        }
        "minecraft:rule_based" => StateProvider::RuleBased {
            fallback: match json.get("fallback") {
                Some(f) => Some(parse(f, table, registry)?),
                None => None,
            },
            rules: json
                .field("rules")?
                .as_array()?
                .iter()
                .map(|rule| {
                    Ok((
                        BlockPredicate::parse(rule.field("if_true")?, table)?,
                        parse(rule.field("then")?, table, registry)?,
                    ))
                })
                .collect::<Result<_, String>>()?,
        },
        "minecraft:rotated" => StateProvider::Rotated {
            state: sub("state")?,
            direction: match json.get("direction") {
                Some(d) => Some(super::predicate::direction(d.as_str()?)?.0),
                None => None,
            },
        },
        "minecraft:randomized_int" => StateProvider::RandomizedInt {
            source: sub("source")?,
            property: json.field("property")?.as_str()?.to_string(),
            values: IntProvider::parse(json.field("values")?)?,
        },
        "minecraft:noise" => StateProvider::Noise {
            noise: noise("noise")?,
            scale: float("scale")?,
            states: states("states")?,
        },
        "minecraft:noise_threshold" => StateProvider::NoiseThreshold {
            noise: noise("noise")?,
            scale: float("scale")?,
            threshold: float("threshold")?,
            high_chance: float("high_chance")?,
            default: table.state(json.field("default_state")?)?,
            low: states("low_states")?,
            high: states("high_states")?,
        },
        "minecraft:dual_noise" => {
            let variety = json.field("variety")?.as_array()?;
            StateProvider::DualNoise {
                variety: (variety[0].as_i32()?, variety[1].as_i32()?),
                slow: noise("slow_noise")?,
                slow_scale: float("slow_scale")?,
                noise: noise("noise")?,
                scale: float("scale")?,
                states: states("states")?,
            }
        }
        "minecraft:random_block" => {
            // The holder set's elements in order.
            let blocks = match json.field("blocks")? {
                Json::String(s) if s.starts_with('#') => table
                    .tag_blocks(&s[1..])?
                    .iter()
                    .map(|&b| table.default[b as usize])
                    .collect(),
                Json::String(s) => vec![table.default_state(s)?],
                Json::Array(items) => items
                    .iter()
                    .map(|b| table.default_state(b.as_str()?))
                    .collect::<Result<_, _>>()?,
                _ => return Err("random_block blocks".into()),
            };
            StateProvider::RandomBlock(blocks)
        }
        "minecraft:copy_properties" => StateProvider::CopyProperties(sub("source")?),
        other => return Err(format!("unknown state provider {other}")),
    }))
}

/// `NoiseProvider.getRandomState` from a noise value.
fn noise_pick(states: &[u16], value: f32) -> u16 {
    let placement = super::java::clamp((1.0 + value) / 2.0, 0.0, 0.9999);
    states[(placement * states.len() as f32) as usize]
}

fn noise_at(noise: &Stack, pos: [i32; 3], scale: f64) -> f32 {
    noise.get(
        pos[0] as f64 * scale,
        pos[1] as f64 * scale,
        pos[2] as f64 * scale,
    )
}

impl StateProvider {
    /// `getState`.
    pub fn state(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        pos: [i32; 3],
    ) -> u16 {
        match self {
            StateProvider::RuleBased { .. } | StateProvider::RandomBlock(_) => {
                match self.optional_state(d, region, random, pos) {
                    Some(state) => state,
                    None => region.get(pos),
                }
            }
            _ => self
                .optional_state(d, region, random, pos)
                .expect("a state"),
        }
    }

    /// `getOptionalState`: `None` where vanilla returns null.
    pub fn optional_state(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        pos: [i32; 3],
    ) -> Option<u16> {
        let table = d.table.as_ref();
        Some(match self {
            StateProvider::Simple(state) => *state,
            StateProvider::Weighted(list) => *list.pick(random),
            StateProvider::RuleBased { fallback, rules } => {
                for (predicate, then) in rules {
                    if predicate.test(d, region, pos) {
                        if let Some(state) = then.optional_state(d, region, random, pos) {
                            return Some(state);
                        }
                    }
                }
                return fallback
                    .as_ref()
                    .and_then(|f| f.optional_state(d, region, random, pos));
            }
            StateProvider::Rotated { state, direction } => {
                let direction = match direction {
                    Some(d) => *d,
                    None => random.next_int_bounded(6) as usize,
                };
                let base = state.state(d, region, random, pos);
                let axis = ["y", "y", "z", "z", "x", "x"][direction];
                let facing = ["down", "up", "north", "south", "west", "east"][direction];
                let mut s = table.with(base, "axis", axis).unwrap_or(base);
                // `FACING` (six directions), then `HORIZONTAL_FACING` for a
                // horizontal direction; other "facing" properties (hoppers)
                // stay.
                let values = table.properties[table.block_of(s) as usize]
                    .iter()
                    .find(|p| p.name == "facing")
                    .map_or(0, |p| p.values.len());
                if values == 6 || (values == 4 && direction >= 2) {
                    s = table.with(s, "facing", facing).unwrap_or(s);
                }
                s
            }
            StateProvider::RandomizedInt {
                source,
                property,
                values,
            } => {
                let base = source.state(d, region, random, pos);
                if !table.has_property(base, property) {
                    return Some(base);
                }
                let value = values.sample(random);
                table
                    .with(base, property, &value.to_string())
                    .unwrap_or(base)
            }
            StateProvider::Noise {
                noise,
                scale,
                states,
            } => noise_pick(states, noise_at(noise, pos, *scale as f64)),
            StateProvider::NoiseThreshold {
                noise,
                scale,
                threshold,
                high_chance,
                default,
                low,
                high,
            } => {
                let value = noise_at(noise, pos, *scale as f64) as f64;
                if value < *threshold as f64 {
                    low[random.next_int_bounded(low.len() as i32) as usize]
                } else if random.next_float() < *high_chance {
                    high[random.next_int_bounded(high.len() as i32) as usize]
                } else {
                    *default
                }
            }
            StateProvider::DualNoise {
                variety,
                slow,
                slow_scale,
                noise,
                scale,
                states,
            } => {
                let slow_at = |p: [i32; 3]| {
                    slow.get(
                        p[0] as f64 * *slow_scale as f64,
                        p[1] as f64 * *slow_scale as f64,
                        p[2] as f64 * *slow_scale as f64,
                    )
                };
                let variety_noise = slow_at(pos) as f64;
                let local = clamped_map(
                    variety_noise,
                    -1.0,
                    1.0,
                    variety.0 as f64,
                    (variety.1 + 1) as f64,
                ) as i32;
                let possible: Vec<u16> = (0..local)
                    .map(|i| {
                        noise_pick(
                            states,
                            slow_at([pos[0] + i * 54545, pos[1], pos[2] + i * 34234]),
                        )
                    })
                    .collect();
                noise_pick(&possible, noise_at(noise, pos, *scale as f64))
            }
            StateProvider::RandomBlock(blocks) => {
                if blocks.is_empty() {
                    return None;
                }
                blocks[random.next_int_bounded(blocks.len() as i32) as usize]
            }
            StateProvider::CopyProperties(source) => {
                let base = source.state(d, region, random, pos);
                let existing = region.get(pos);
                copy_properties(table, base, existing)
            }
        })
    }
}

/// `Mth.clampedMap` (doubles).
fn clamped_map(value: f64, from_min: f64, from_max: f64, to_min: f64, to_max: f64) -> f64 {
    let factor = (value - from_min) / (from_max - from_min);
    if factor < 0.0 {
        to_min
    } else if factor > 1.0 {
        to_max
    } else {
        to_min + factor * (to_max - to_min)
    }
}

/// `withPropertiesOf`: the properties both blocks share, from `from`.
fn copy_properties(table: &BlockTable, state: u16, from: u16) -> u16 {
    let mut out = state;
    let block = table.block_of(from) as usize;
    for property in &table.properties[block] {
        if let Some(value) = table.value(from, &property.name) {
            if let Some(next) = table.with(out, &property.name, value) {
                out = next;
            }
        }
    }
    out
}
