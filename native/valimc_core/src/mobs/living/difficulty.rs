//! `Valimc.Living.LocalDifficulty` (`DifficultyInstance`): the world's
//! difficulty scaled up by the world's age, the chunk's inhabited time and
//! the moon's brightness, in float arithmetic.

use super::super::level::Difficulty;
use super::{emax, emin, f};

/// `DimensionType.MOON_BRIGHTNESS_PER_PHASE`, from the full moon.
const MOON: [f64; 8] = [1.0, 0.75, 0.5, 0.25, 0.0, 0.25, 0.5, 0.75];

/// A local difficulty: the world's and its effective value.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LocalDifficulty {
    pub difficulty: Difficulty,
    pub effective: f64,
}

fn level(difficulty: Difficulty) -> f64 {
    match difficulty {
        Difficulty::Peaceful => 0.0,
        Difficulty::Easy => 1.0,
        Difficulty::Normal => 2.0,
        Difficulty::Hard => 3.0,
    }
}

fn clamp(v: f64) -> f64 {
    emin(emax(v, 0.0), 1.0)
}

impl LocalDifficulty {
    /// `new DifficultyInstance(base, totalGameTime, localGameTime,
    /// moonBrightness)`.
    pub fn new(difficulty: Difficulty, total: i64, inhabited: i64, moon: f64) -> LocalDifficulty {
        let effective = if difficulty == Difficulty::Peaceful {
            0.0
        } else {
            let hard = difficulty == Difficulty::Hard;
            let global = clamp(f(f(f(total as f64) + -72_000.0) / 1_440_000.0));
            let global = f(global * 0.25);
            let scale = f(0.75 + global);
            let local = clamp(f(f(inhabited as f64) / 3_600_000.0));
            let local = f(local * if hard { 1.0 } else { 0.75 });
            let local = f(local + emin(emax(f(moon * 0.25), 0.0), global));
            let local = if difficulty == Difficulty::Easy {
                f(local * 0.5)
            } else {
                local
            };
            let scale = f(scale + local);
            f(level(difficulty) * scale)
        };
        LocalDifficulty {
            difficulty,
            effective,
        }
    }

    /// `ServerLevel.getCurrentDifficultyAt` at overworld clock `ticks`.
    pub fn at(difficulty: Difficulty, ticks: i64, inhabited: i64) -> LocalDifficulty {
        LocalDifficulty::new(difficulty, ticks, inhabited, moon_brightness(ticks))
    }

    /// `getSpecialMultiplier`: 0 below an effective 2, 1 above 4.
    pub fn special(&self) -> f64 {
        let e = self.effective;
        if e < 2.0 {
            0.0
        } else if e > 4.0 {
            1.0
        } else {
            f(f(e - 2.0) / 2.0)
        }
    }
}

/// The moon's brightness on the day of `ticks` of the overworld clock.
pub fn moon_brightness(ticks: i64) -> f64 {
    MOON[((ticks.max(0) / 24_000) % 8) as usize]
}
