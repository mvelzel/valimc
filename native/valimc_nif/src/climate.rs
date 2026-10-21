//! Climate at a block (VMC-077e): vanilla's fuzzed biome zoom and
//! `Biome.getTemperature`, pure functions for readers of the biomes region
//! owners publish beside their snapshots.

use crate::atoms;
use rustler::Atom;
use valimc_core::worldgen::surface::{self, BiomeClimate};

/// The quart whose biome `Level.getBiome` reads at a block (`BiomeManager`'s
/// fuzzed zoom with the world's hashed seed).
#[rustler::nif]
fn biome_zoom(zoom_seed: i64, x: i32, y: i32, z: i32) -> (Atom, (i32, i32, i32)) {
    (atoms::ok(), surface::zoom(zoom_seed, x, y, z))
}

/// `Biome.getTemperature` at a block, for a biome of base `temperature`
/// (`frozen`: its `temperature_modifier`) under a generator with `sea_level`.
#[rustler::nif]
fn biome_temperature(
    temperature: f64,
    frozen: bool,
    x: i32,
    y: i32,
    z: i32,
    sea_level: i32,
) -> (Atom, f64) {
    let climate = BiomeClimate {
        temperature: temperature as f32,
        frozen,
    };
    let value = surface::temperature(&climate, x, y, z, sea_level);
    (atoms::ok(), value as f64)
}
