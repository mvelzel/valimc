//! What a living entity's effects do as it goes and as it is hurt
//! (`MobEffect.onMobRemoved` with `KILLED`, `onMobHurt`), drawn from its
//! own random. The owner acts on the world: a wind burst, cobwebs on the
//! cells that take them, slimes up to the cramming limit, silverfish.

use super::super::ai::fmath::{f, java_sin_cos, view_vector};
use super::super::model::Effects;
use super::super::random::LegacyRandom;
use super::facts::EffectIds;

/// What one effect does as its entity is removed.
#[derive(Clone, Debug, PartialEq)]
pub enum Removed {
    /// `WindChargedMobEffect`: a burst of strength `3 + 2r` at the middle of
    /// its box.
    WindBurst(f32),
    /// `WeavingMobEffect`: up to `count` cobwebs on the first of `cells`
    /// (`BlockPos.randomInCube(random, 15, pos, 1)`, in draw order) that
    /// can be replaced over a sturdy floor.
    Cobwebs { count: i32, cells: Vec<[i32; 3]> },
    /// `OozingMobEffect`: this many slimes of size 2 asked for.
    Slimes(i32),
}

/// `triggerOnDeathMobEffects` with `KILLED`: each effect's action in id
/// order (vanilla walks its effect map's own order, which no run fixes).
/// Weaving needs `mob_griefing` unless the entity is a player.
pub fn removed(
    ids: &EffectIds,
    effects: &Effects,
    random: &mut LegacyRandom,
    [x, y, z]: [i32; 3],
    player: bool,
    griefing: bool,
) -> Vec<Removed> {
    let mut out = Vec::new();
    for (id, _) in &effects.0 {
        if *id == ids.wind_charged {
            out.push(Removed::WindBurst(3.0 + random.float() * 2.0));
        } else if *id == ids.weaving && (player || griefing) {
            let count = random.int(2) + 2;
            let cells = (0..15)
                .map(|_| {
                    let cx = x - 1 + random.int(3);
                    let cy = y - 1 + random.int(3);
                    [cx, cy, z - 1 + random.int(3)]
                })
                .collect();
            out.push(Removed::Cobwebs { count, cells });
        } else if *id == ids.oozing {
            out.push(Removed::Slimes(2));
        }
    }
    out
}

/// `InfestedMobEffect.onMobHurt`: one hurt in ten releases one or two
/// silverfish, each moving along the entity's look (`getLookAngle`, scaled
/// by 0.3 and its rise by 1.5) turned by a random angle within a quarter
/// turn either way (JOML's `rotateY`, in floats). Their velocities.
pub fn infested(random: &mut LegacyRandom, pitch: f64, yaw: f64) -> Vec<[f64; 3]> {
    if random.float() > 0.1 {
        return Vec::new();
    }
    let count = random.int(2) + 1;
    let half = std::f32::consts::FRAC_PI_2;
    let look = view_vector(pitch, yaw);
    let [lx, ly, lz] = [look[0] as f32, look[1] as f32, look[2] as f32];
    let (vx, vy, vz) = (lx * 0.3, ly * 0.3 * 1.5, lz * 0.3);
    (0..count)
        .map(|_| {
            let angle = random.float() * (half - -half) + -half;
            let sin = java_sin_cos(f64::from(angle)).0 as f32;
            let cos = (1.0 - sin * sin).sqrt();
            let x = vx * cos + vz * sin;
            let z = -vx * sin + vz * cos;
            [f(f64::from(x)), f(f64::from(vy)), f(f64::from(z))]
        })
        .collect()
}
