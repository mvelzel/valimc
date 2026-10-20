//! Vanilla's value providers (`util.valueproviders`, `levelgen.heightproviders`)
//! and weighted lists, as 26.3's codecs write them, sampling in vanilla's order
//! of random draws and float arithmetic.

use super::json::Json;
use super::random::Random;
use super::surface::Anchor;

/// `Mth.randomBetweenInclusive`.
pub fn between_inclusive(random: &mut Random, min: i32, max: i32) -> i32 {
    random.next_int_bounded(max - min + 1) + min
}

/// `Mth.nextInt`: `min` when the range is empty.
pub fn next_int(random: &mut Random, min: i32, max: i32) -> i32 {
    if min >= max {
        min
    } else {
        random.next_int_bounded(max - min + 1) + min
    }
}

/// `Mth.normal`.
pub fn normal(random: &mut Random, mean: f32, deviation: f32) -> f32 {
    mean + random.next_gaussian() as f32 * deviation
}

/// Java's `(int)` of a float: truncation, NaN to 0, saturating.
pub fn float_to_int(value: f32) -> i32 {
    value as i32
}

/// A `WeightedList`: entries with positive total weight, picked by
/// `nextInt(total)` against the running weights (both of vanilla's selectors
/// agree on that).
#[derive(Clone, Debug)]
pub struct Weighted<T> {
    pub entries: Vec<(T, i32)>,
    pub total: i32,
}

impl<T> Weighted<T> {
    pub fn parse(json: &Json, item: impl Fn(&Json) -> Result<T, String>) -> Result<Self, String> {
        let mut entries = Vec::new();
        let mut total = 0i32;
        for entry in json.as_array()? {
            let weight = entry.field("weight")?.as_i32()?;
            total = total
                .checked_add(weight)
                .ok_or("weighted list total overflows")?;
            entries.push((item(entry.field("data")?)?, weight));
        }
        Ok(Self { entries, total })
    }

    pub fn is_empty(&self) -> bool {
        self.total == 0
    }

    /// `getRandomOrThrow`.
    pub fn pick(&self, random: &mut Random) -> &T {
        let mut selection = random.next_int_bounded(self.total);
        for (item, weight) in &self.entries {
            selection -= weight;
            if selection < 0 {
                return item;
            }
        }
        unreachable!("selection below the total weight")
    }
}

#[derive(Clone, Debug)]
pub enum IntProvider {
    Constant(i32),
    Uniform(i32, i32),
    BiasedToBottom(i32, i32),
    VeryBiasedToBottom(i32, i32),
    Clamped(Box<IntProvider>, i32, i32),
    ClampedNormal {
        mean: f32,
        deviation: f32,
        min: i32,
        max: i32,
    },
    WeightedList(Weighted<IntProvider>),
    Trapezoid {
        min: i32,
        max: i32,
        plateau: i32,
    },
}

impl IntProvider {
    pub fn parse(json: &Json) -> Result<IntProvider, String> {
        if let Json::Number(_) = json {
            return Ok(IntProvider::Constant(json.as_i32()?));
        }
        let i = |k: &str| json.field(k)?.as_i32();
        let f = |k: &str| Ok::<f32, String>(json.field(k)?.as_f64()? as f32);
        Ok(match json.field("type")?.as_str()? {
            "minecraft:constant" => IntProvider::Constant(i("value")?),
            "minecraft:uniform" => IntProvider::Uniform(i("min_inclusive")?, i("max_inclusive")?),
            "minecraft:biased_to_bottom" => {
                IntProvider::BiasedToBottom(i("min_inclusive")?, i("max_inclusive")?)
            }
            "minecraft:very_biased_to_bottom" => {
                IntProvider::VeryBiasedToBottom(i("min_inclusive")?, i("max_inclusive")?)
            }
            "minecraft:clamped" => IntProvider::Clamped(
                Box::new(IntProvider::parse(json.field("source")?)?),
                i("min_inclusive")?,
                i("max_inclusive")?,
            ),
            "minecraft:clamped_normal" => IntProvider::ClampedNormal {
                mean: f("mean")?,
                deviation: f("deviation")?,
                min: i("min_inclusive")?,
                max: i("max_inclusive")?,
            },
            "minecraft:weighted_list" => IntProvider::WeightedList(Weighted::parse(
                json.field("distribution")?,
                IntProvider::parse,
            )?),
            "minecraft:trapezoid" => IntProvider::Trapezoid {
                min: i("min")?,
                max: i("max")?,
                plateau: i("plateau")?,
            },
            other => return Err(format!("unknown int provider {other}")),
        })
    }

    pub fn sample(&self, random: &mut Random) -> i32 {
        match self {
            IntProvider::Constant(v) => *v,
            IntProvider::Uniform(min, max) => between_inclusive(random, *min, *max),
            IntProvider::BiasedToBottom(min, max) => {
                let inner = random.next_int_bounded(max - min + 1) + 1;
                min + random.next_int_bounded(inner)
            }
            IntProvider::VeryBiasedToBottom(min, max) => {
                let a = random.next_int_bounded(max - min + 1) + 1;
                let b = random.next_int_bounded(a) + 1;
                min + random.next_int_bounded(b)
            }
            IntProvider::Clamped(source, min, max) => source.sample(random).clamp(*min, *max),
            IntProvider::ClampedNormal {
                mean,
                deviation,
                min,
                max,
            } => {
                let value = normal(random, *mean, *deviation);
                float_to_int(super::java::clamp(value, *min as f32, *max as f32))
            }
            IntProvider::WeightedList(list) => list.pick(random).sample(random),
            IntProvider::Trapezoid { min, max, plateau } => {
                if *plateau == 0 && *max == -*min {
                    return random.next_int_bounded(max + 1) - random.next_int_bounded(max + 1);
                }
                let range = max - min;
                if *plateau == range {
                    return between_inclusive(random, *min, *max);
                }
                let start = (range - plateau) / 2;
                let end = range - start;
                min + between_inclusive(random, 0, end) + between_inclusive(random, 0, start)
            }
        }
    }

    pub fn min_inclusive(&self) -> i32 {
        match self {
            IntProvider::Constant(v) => *v,
            IntProvider::Uniform(min, _)
            | IntProvider::BiasedToBottom(min, _)
            | IntProvider::VeryBiasedToBottom(min, _) => *min,
            IntProvider::Clamped(source, min, _) => (*min).max(source.min_inclusive()),
            IntProvider::ClampedNormal { min, .. } => *min,
            IntProvider::WeightedList(list) => list
                .entries
                .iter()
                .map(|(p, _)| p.min_inclusive())
                .min()
                .unwrap_or(i32::MAX),
            IntProvider::Trapezoid { min, .. } => *min,
        }
    }

    pub fn max_inclusive(&self) -> i32 {
        match self {
            IntProvider::Constant(v) => *v,
            IntProvider::Uniform(_, max)
            | IntProvider::BiasedToBottom(_, max)
            | IntProvider::VeryBiasedToBottom(_, max) => *max,
            IntProvider::Clamped(source, _, max) => (*max).min(source.max_inclusive()),
            IntProvider::ClampedNormal { max, .. } => *max,
            IntProvider::WeightedList(list) => list
                .entries
                .iter()
                .map(|(p, _)| p.max_inclusive())
                .max()
                .unwrap_or(i32::MIN),
            IntProvider::Trapezoid { max, .. } => *max,
        }
    }
}

#[derive(Clone, Debug)]
pub enum FloatProvider {
    Constant(f32),
    Uniform {
        min: f32,
        max: f32,
    },
    ClampedNormal {
        mean: f32,
        deviation: f32,
        min: f32,
        max: f32,
    },
    Trapezoid {
        min: f32,
        max: f32,
        plateau: f32,
    },
}

impl FloatProvider {
    pub fn parse(json: &Json) -> Result<FloatProvider, String> {
        if let Json::Number(n) = json {
            return Ok(FloatProvider::Constant(*n as f32));
        }
        let f = |k: &str| Ok::<f32, String>(json.field(k)?.as_f64()? as f32);
        Ok(match json.field("type")?.as_str()? {
            "minecraft:constant" => FloatProvider::Constant(f("value")?),
            "minecraft:uniform" => FloatProvider::Uniform {
                min: f("min_inclusive")?,
                max: f("max_exclusive")?,
            },
            "minecraft:clamped_normal" => FloatProvider::ClampedNormal {
                mean: f("mean")?,
                deviation: f("deviation")?,
                min: f("min")?,
                max: f("max")?,
            },
            "minecraft:trapezoid" => FloatProvider::Trapezoid {
                min: f("min")?,
                max: f("max")?,
                plateau: f("plateau")?,
            },
            other => return Err(format!("unknown float provider {other}")),
        })
    }

    pub fn sample(&self, random: &mut Random) -> f32 {
        match *self {
            FloatProvider::Constant(v) => v,
            // `Mth.randomBetween`.
            FloatProvider::Uniform { min, max } => random.next_float() * (max - min) + min,
            FloatProvider::ClampedNormal {
                mean,
                deviation,
                min,
                max,
            } => super::java::clamp(normal(random, mean, deviation), min, max),
            FloatProvider::Trapezoid { min, max, plateau } => {
                let range = max - min;
                let start = (range - plateau) / 2.0;
                let end = range - start;
                min + random.next_float() * end + random.next_float() * start
            }
        }
    }
}

/// What height providers and anchors resolve against
/// (`WorldGenerationContext`).
#[derive(Clone, Copy, Debug)]
pub struct GenContext {
    pub min_y: i32,
    pub height: i32,
    pub sea_level: i32,
}

impl GenContext {
    pub fn resolve(self, anchor: Anchor) -> i32 {
        anchor.resolve(self.min_y, self.height, self.sea_level)
    }
}

#[derive(Clone, Debug)]
pub enum HeightProvider {
    Constant(Anchor),
    Uniform(Anchor, Anchor),
    BiasedToBottom(Anchor, Anchor, i32),
    VeryBiasedToBottom(Anchor, Anchor, i32),
    Trapezoid(Anchor, Anchor, i32),
    WeightedList(Weighted<HeightProvider>),
}

impl HeightProvider {
    pub fn parse(json: &Json) -> Result<HeightProvider, String> {
        let Some(kind) = json.get("type") else {
            return Ok(HeightProvider::Constant(Anchor::parse_json(json)?));
        };
        let a = |k: &str| Anchor::parse_json(json.field(k)?);
        let inner = |k: &str, default: i32| match json.get(k) {
            Some(v) => v.as_i32(),
            None => Ok(default),
        };
        Ok(match kind.as_str()? {
            "minecraft:constant" => HeightProvider::Constant(a("value")?),
            "minecraft:uniform" => {
                HeightProvider::Uniform(a("min_inclusive")?, a("max_inclusive")?)
            }
            "minecraft:biased_to_bottom" => HeightProvider::BiasedToBottom(
                a("min_inclusive")?,
                a("max_inclusive")?,
                inner("inner", 1)?,
            ),
            "minecraft:very_biased_to_bottom" => HeightProvider::VeryBiasedToBottom(
                a("min_inclusive")?,
                a("max_inclusive")?,
                inner("inner", 1)?,
            ),
            "minecraft:trapezoid" => HeightProvider::Trapezoid(
                a("min_inclusive")?,
                a("max_inclusive")?,
                inner("plateau", 0)?,
            ),
            "minecraft:weighted_list" => HeightProvider::WeightedList(Weighted::parse(
                json.field("distribution")?,
                HeightProvider::parse,
            )?),
            other => return Err(format!("unknown height provider {other}")),
        })
    }

    pub fn sample(&self, random: &mut Random, c: GenContext) -> i32 {
        match self {
            HeightProvider::Constant(anchor) => c.resolve(*anchor),
            HeightProvider::Uniform(min, max) => {
                let (min, max) = (c.resolve(*min), c.resolve(*max));
                if min > max {
                    min
                } else {
                    between_inclusive(random, min, max)
                }
            }
            HeightProvider::BiasedToBottom(min, max, inner) => {
                let (min, max) = (c.resolve(*min), c.resolve(*max));
                if max - min - inner < 0 {
                    return min;
                }
                let limit = random.next_int_bounded(max - min - inner + 1);
                random.next_int_bounded(limit + inner) + min
            }
            HeightProvider::VeryBiasedToBottom(min, max, inner) => {
                let (min, max) = (c.resolve(*min), c.resolve(*max));
                if max - min - inner < 0 {
                    return min;
                }
                let upper = next_int(random, min + inner, max);
                let biased = next_int(random, min, upper - 1);
                next_int(random, min, biased - 1 + inner)
            }
            HeightProvider::Trapezoid(min, max, plateau) => {
                let (min, max) = (c.resolve(*min), c.resolve(*max));
                if min > max {
                    return min;
                }
                let range = max - min;
                if *plateau >= range {
                    return between_inclusive(random, min, max);
                }
                let start = (range - plateau) / 2;
                let end = range - start;
                min + between_inclusive(random, 0, end) + between_inclusive(random, 0, start)
            }
            HeightProvider::WeightedList(list) => list.pick(random).sample(random, c),
        }
    }
}
