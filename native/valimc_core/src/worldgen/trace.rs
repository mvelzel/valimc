//! Parity probes against vanilla: operation traces over random sources
//! (`RandomOracle` runs the same operations on vanilla's classes), noise
//! samples (`NoiseOracle`) and density function samples (`DensityOracle`).
//!
//! Random operations: `int`, `bounded:N`, `long`, `bool`, `float`, `double`,
//! `gaussian`, `consume:N`, `fork` (continue on the fork), `at:X,Y,Z`,
//! `hash:TEXT` and `seed:N` (continue on that random of a positional factory
//! forked from the current source). Floats and doubles are their raw bits.

use super::compiler::Worldgen;
use super::noise::{BlendedParameters, NoiseParameters, NormalNoise, Normalization, Stack};
use super::random::Random;
use super::sampler::Context;
use super::volume::Volume;

fn random(kind: &str, seed: i64) -> Result<Random, String> {
    match kind {
        "xoroshiro" => Ok(Random::xoroshiro(seed)),
        "legacy" => Ok(Random::legacy(seed)),
        other => Err(format!("unknown kind {other}")),
    }
}

pub fn run(kind: &str, seed: i64, ops: &[String]) -> Result<Vec<String>, String> {
    let mut random = random(kind, seed)?;
    let mut out = Vec::with_capacity(ops.len());
    for op in ops {
        let (name, arg) = op.split_once(':').unwrap_or((op.as_str(), ""));
        let number = |text: &str| {
            text.parse::<i64>()
                .map_err(|_| format!("bad argument in {op}"))
        };
        let value = match name {
            "int" => random.next_int().to_string(),
            "bounded" => random.next_int_bounded(number(arg)? as i32).to_string(),
            "long" => random.next_long().to_string(),
            "bool" => random.next_bool().to_string(),
            "float" => format!("{:08x}", random.next_float().to_bits()),
            "double" => format!("{:016x}", random.next_double().to_bits()),
            "gaussian" => format!("{:016x}", random.next_gaussian().to_bits()),
            "consume" => {
                random.consume_count(number(arg)? as i32);
                "-".to_string()
            }
            "fork" => {
                random = random.fork();
                "-".to_string()
            }
            "at" => {
                let parts: Vec<i32> = arg.split(',').map(|p| p.parse().unwrap_or(0)).collect();
                random = random.fork_positional().at(parts[0], parts[1], parts[2]);
                "-".to_string()
            }
            "hash" => {
                random = random.fork_positional().from_hash_of(arg);
                "-".to_string()
            }
            "seed" => {
                random = random.fork_positional().from_seed(number(arg)?);
                "-".to_string()
            }
            other => return Err(format!("unknown operation {other}")),
        };
        out.push(value);
    }
    Ok(out)
}

/// Raw float bits of a noise's samples: 3D points, 2D points (X and Z of the
/// same points) and whole volumes (zeroed, then `add_to_volume` at amplitude 1,
/// as vanilla's noise sampler does).
pub struct NoiseSamples {
    pub points: Vec<u32>,
    pub points_2d: Vec<u32>,
    pub volumes: Vec<Vec<u32>>,
}

/// A volume to sample: size, minimum and step (X, Y, Z each), then the XZ and
/// Y scales.
pub type VolumeProbe = ([i32; 9], f64, f64);

/// Samples a noise built from `random` (`kind`, `seed`; with `source`
/// `hash:NAME`, the random a positional fork derives from NAME).
///
/// Noises and their `params`: `normal` and `legacy_nether` take the base
/// amplitude, base octave, octave count, normalisation (0 disabled, 1 enabled,
/// 2 legacy) and amplitude modifiers; `blended_min`, `blended_max` and
/// `blended_main` (one stack of the blended noise's octave set) take the XZ
/// and Y scales and factors and the smear scale multiplier.
pub fn noise(
    (kind, seed, source): (&str, i64, &str),
    noise: &str,
    params: &[f64],
    points: &[(f64, f64, f64)],
    volumes: &[VolumeProbe],
) -> Result<NoiseSamples, String> {
    let mut random = random(kind, seed)?;
    if let Some(name) = source.strip_prefix("hash:") {
        random = random.fork_positional().from_hash_of(name);
    } else if !source.is_empty() {
        return Err(format!("unknown random source {source}"));
    }
    let stack = build(&mut random, noise, params)?;
    let mut samples = NoiseSamples {
        points: points
            .iter()
            .map(|&(x, y, z)| stack.get(x, y, z).to_bits())
            .collect(),
        points_2d: points
            .iter()
            .map(|&(x, _, z)| stack.get_2d(x, z).to_bits())
            .collect(),
        volumes: Vec::with_capacity(volumes.len()),
    };
    for (v, xz_scale, y_scale) in volumes {
        let volume = Volume::new([v[0], v[1], v[2]], [v[3], v[4], v[5]], [v[6], v[7], v[8]])?;
        if volume.len() > 1 << 20 {
            return Err("volume too large".into());
        }
        let mut buffer = vec![0.0f32; volume.len()];
        stack.add_to_volume(&mut buffer, &volume, *xz_scale, *y_scale, 1.0);
        samples
            .volumes
            .push(buffer.into_iter().map(f32::to_bits).collect());
    }
    Ok(samples)
}

fn build(random: &mut Random, noise: &str, params: &[f64]) -> Result<Stack, String> {
    match (noise, params) {
        ("normal" | "legacy_nether", [amplitude, octave, count, normalize, modifiers @ ..]) => {
            let normal = NormalNoise::new(NoiseParameters {
                base_amplitude: *amplitude,
                base_octave: *octave as i32,
                octave_count: *count as i32,
                normalize: match *normalize as i32 {
                    0 => Normalization::Disabled,
                    1 => Normalization::Enabled,
                    _ => Normalization::Legacy,
                },
                amplitude_modifiers: modifiers.to_vec(),
            })?;
            if noise == "normal" {
                Ok(normal.create(random))
            } else {
                normal.create_legacy_nether(random)
            }
        }
        (
            "blended_min" | "blended_max" | "blended_main",
            &[xz_scale, y_scale, xz_factor, y_factor, smear],
        ) => {
            let set = BlendedParameters {
                xz_scale,
                y_scale,
                xz_factor,
                y_factor,
                smear_scale_multiplier: smear,
            }
            .fbm_set(random);
            Ok(match noise {
                "blended_min" => set.min_limit,
                "blended_max" => set.max_limit,
                _ => set.main,
            })
        }
        _ => Err(format!(
            "unknown noise {noise} or bad parameters {params:?}"
        )),
    }
}

/// Samples a named function (`Worldgen::named`) through one sampling context,
/// cached or not, in order: each op is a point (x, y, z) or a volume (size,
/// minimum and step per axis). Returns the raw float bits per op.
pub fn density(
    worldgen: &mut Worldgen,
    function: &str,
    cached: bool,
    ops: &[Vec<i32>],
) -> Result<Vec<Vec<u32>>, String> {
    let named = worldgen.named(function)?;
    let sampler = worldgen.sampler(&named)?;
    let mut ctx = if cached {
        Context::cached()
    } else {
        Context::uncached()
    };
    ops.iter()
        .map(|op| match op[..] {
            [x, y, z] => Ok(vec![sampler.value(&mut ctx, x, y, z).to_bits()]),
            [sx, sy, sz, mx, my, mz, tx, ty, tz] => {
                let volume = Volume::new([sx, sy, sz], [mx, my, mz], [tx, ty, tz])?;
                if volume.len() > 1 << 22 {
                    return Err("volume too large".into());
                }
                let mut out = vec![0.0f32; volume.len()];
                sampler.fill(&mut ctx, &mut out, &volume);
                Ok(out.into_iter().map(f32::to_bits).collect())
            }
            _ => Err(format!("bad density op {op:?}")),
        })
        .collect()
}
