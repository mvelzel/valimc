//! Structure placements (vanilla's `StructurePlacement` types): random
//! spread grids and concentric rings, with their frequency reduction and
//! exclusion zones.

use super::super::carver::set_large_feature_seed;
use super::super::json::Json;
use super::super::random::Random;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpreadType {
    Linear,
    Triangular,
}

impl SpreadType {
    fn evaluate(self, random: &mut Random, limit: i32) -> i32 {
        match self {
            SpreadType::Linear => random.next_int_bounded(limit),
            SpreadType::Triangular => {
                (random.next_int_bounded(limit) + random.next_int_bounded(limit)) / 2
            }
        }
    }
}

/// `FrequencyReductionMethod`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reducer {
    Default,
    LegacyType1,
    LegacyType2,
    LegacyType3,
}

/// `WorldgenRandom.setLargeFeatureWithSalt` on a legacy source.
pub fn set_large_feature_with_salt(random: &mut Random, seed: i64, x: i32, z: i32, salt: i32) {
    random.set_seed(
        (x as i64)
            .wrapping_mul(341_873_128_712)
            .wrapping_add((z as i64).wrapping_mul(132_897_987_541))
            .wrapping_add(seed)
            .wrapping_add(salt as i64),
    );
}

impl Reducer {
    fn should_generate(self, seed: i64, salt: i32, x: i32, z: i32, probability: f32) -> bool {
        let mut random = Random::legacy(0);
        match self {
            // Vanilla passes the salt as the X coordinate.
            Reducer::Default => {
                set_large_feature_with_salt(&mut random, seed, salt, x, z);
                random.next_float() < probability
            }
            Reducer::LegacyType1 => {
                let (cx, cz) = (x >> 4, z >> 4);
                random.set_seed((cx ^ (cz << 4)) as i64 ^ seed);
                random.next_int();
                random.next_int_bounded((1.0f32 / probability) as i32) == 0
            }
            Reducer::LegacyType2 => {
                set_large_feature_with_salt(&mut random, seed, x, z, 10_387_320);
                random.next_float() < probability
            }
            Reducer::LegacyType3 => {
                set_large_feature_seed(&mut random, seed, x, z);
                random.next_double() < probability as f64
            }
        }
    }
}

/// The fields every spreading placement has.
#[derive(Clone, Debug)]
pub struct Spreading {
    pub locate_offset: [i32; 3],
    pub reducer: Reducer,
    pub frequency: f32,
    pub salt: i32,
    /// Another structure set (by index) and its chunk distance.
    pub exclusion: Option<(usize, i32)>,
}

impl Spreading {
    /// `applyAdditionalChunkRestrictions`.
    pub fn frequency_allows(&self, seed: i64, x: i32, z: i32) -> bool {
        self.frequency >= 1.0
            || self
                .reducer
                .should_generate(seed, self.salt, x, z, self.frequency)
    }
}

#[derive(Clone, Debug)]
pub enum Placement {
    RandomSpread {
        common: Spreading,
        spacing: i32,
        separation: i32,
        spread: SpreadType,
    },
    ConcentricRings {
        common: Spreading,
        distance: i32,
        spread: i32,
        count: i32,
        /// Preferred biomes by registry id.
        preferred: Vec<u16>,
    },
}

impl Placement {
    /// Parses a placement; `set_index` resolves an exclusion zone's set and
    /// `biome` a biome identifier.
    pub fn parse(
        json: &Json,
        set_index: &dyn Fn(&str) -> Result<usize, String>,
        biome: &dyn Fn(&str) -> Result<u16, String>,
    ) -> Result<Placement, String> {
        let int_or = |key: &str, default: i32| -> Result<i32, String> {
            json.get(key).map_or(Ok(default), Json::as_i32)
        };
        let locate_offset = match json.get("locate_offset") {
            None => [0, 0, 0],
            Some(offset) => {
                let v = offset.as_array()?;
                if v.len() != 3 {
                    return Err("a locate offset has three values".into());
                }
                [v[0].as_i32()?, v[1].as_i32()?, v[2].as_i32()?]
            }
        };
        let reducer = match json.get("frequency_reduction_method").map(Json::as_str) {
            None => Reducer::Default,
            Some(name) => match name? {
                "default" => Reducer::Default,
                "legacy_type_1" => Reducer::LegacyType1,
                "legacy_type_2" => Reducer::LegacyType2,
                "legacy_type_3" => Reducer::LegacyType3,
                other => return Err(format!("unknown frequency reduction method {other}")),
            },
        };
        let exclusion = match json.get("exclusion_zone") {
            None => None,
            Some(zone) => Some((
                set_index(zone.field("other_set")?.as_str()?)?,
                zone.field("chunk_count")?.as_i32()?,
            )),
        };
        let common = Spreading {
            locate_offset,
            reducer,
            frequency: json.get("frequency").map_or(Ok(1.0), Json::as_f64)? as f32,
            salt: json.field("salt")?.as_i32()?,
            exclusion,
        };
        match json.field("type")?.as_str()? {
            "minecraft:random_spread" => {
                let spacing = json.field("spacing")?.as_i32()?;
                let separation = json.field("separation")?.as_i32()?;
                if spacing <= separation {
                    return Err("spacing has to be larger than separation".into());
                }
                let spread = match json.get("spread_type").map(Json::as_str) {
                    None => SpreadType::Linear,
                    Some(name) => match name? {
                        "linear" => SpreadType::Linear,
                        "triangular" => SpreadType::Triangular,
                        other => return Err(format!("unknown spread type {other}")),
                    },
                };
                Ok(Placement::RandomSpread {
                    common,
                    spacing,
                    separation,
                    spread,
                })
            }
            "minecraft:concentric_rings" => Ok(Placement::ConcentricRings {
                common,
                distance: json.field("distance")?.as_i32()?,
                spread: json.field("spread")?.as_i32()?,
                count: int_or("count", 1)?,
                preferred: json
                    .field("preferred_biomes")?
                    .as_array()?
                    .iter()
                    .map(|b| biome(b.as_str()?))
                    .collect::<Result<_, _>>()?,
            }),
            other => Err(format!("unsupported structure placement {other}")),
        }
    }

    pub fn common(&self) -> &Spreading {
        match self {
            Placement::RandomSpread { common, .. } | Placement::ConcentricRings { common, .. } => {
                common
            }
        }
    }

    /// `RandomSpreadStructurePlacement.getPotentialStructureChunk`; `None`
    /// for other placements.
    pub fn potential_chunk(&self, seed: i64, x: i32, z: i32) -> Option<(i32, i32)> {
        let Placement::RandomSpread {
            common,
            spacing,
            separation,
            spread,
        } = self
        else {
            return None;
        };
        let grid_x = x.div_euclid(*spacing);
        let grid_z = z.div_euclid(*spacing);
        let mut random = Random::legacy(0);
        set_large_feature_with_salt(&mut random, seed, grid_x, grid_z, common.salt);
        let limit = spacing - separation;
        let spread_x = spread.evaluate(&mut random, limit);
        let spread_z = spread.evaluate(&mut random, limit);
        Some((grid_x * spacing + spread_x, grid_z * spacing + spread_z))
    }
}

/// `Math.round(double)` as Java defines it.
pub fn java_round(value: f64) -> i64 {
    if value.is_nan() {
        0
    } else {
        (value + 0.5).floor() as i64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spread(salt: i32, spacing: i32, separation: i32, spread: SpreadType) -> Placement {
        spread_with(salt, spacing, separation, spread, Reducer::Default, 1.0)
    }

    fn spread_with(
        salt: i32,
        spacing: i32,
        separation: i32,
        spread: SpreadType,
        reducer: Reducer,
        frequency: f32,
    ) -> Placement {
        Placement::RandomSpread {
            common: Spreading {
                locate_offset: [0, 0, 0],
                reducer,
                frequency,
                salt,
                exclusion: None,
            },
            spacing,
            separation,
            spread,
        }
    }

    /// Chunks in -20..20 where a set places at seed 20261020 (StructureOracle).
    fn placed(placement: &Placement) -> Vec<(i32, i32)> {
        let seed = 20_261_020;
        let mut out = Vec::new();
        for z in -20..20 {
            for x in -20..20 {
                if placement.potential_chunk(seed, x, z) == Some((x, z))
                    && placement.common().frequency_allows(seed, x, z)
                {
                    out.push((x, z));
                }
            }
        }
        out
    }

    #[test]
    fn random_spread_grids_equal_vanilla() {
        let villages = spread(10_387_312, 34, 8, SpreadType::Linear);
        assert_eq!(placed(&villages), [(17, 14), (-14, 16)]);
        let monuments = spread(10_387_313, 32, 5, SpreadType::Triangular);
        assert_eq!(placed(&monuments), [(12, -12), (8, 10), (-10, 16)]);
        let mansions = spread(10_387_319, 80, 20, SpreadType::Triangular);
        assert_eq!(placed(&mansions), []);
    }

    #[test]
    fn frequency_reducers_equal_vanilla() {
        let mineshafts = spread_with(0, 1, 0, SpreadType::Linear, Reducer::LegacyType3, 0.004);
        assert_eq!(placed(&mineshafts)[..3], [(9, -19), (16, -19), (8, -8)]);
        let buried = spread_with(0, 1, 0, SpreadType::Linear, Reducer::LegacyType2, 0.01);
        assert_eq!(placed(&buried)[..3], [(-17, -17), (-4, -16), (13, -12)]);
    }

    #[test]
    fn java_round_rounds_halves_up() {
        assert_eq!(java_round(-2.5), -2);
        assert_eq!(java_round(2.5), 3);
        assert_eq!(java_round(-2.6), -3);
        assert_eq!(java_round(f64::NAN), 0);
    }
}
