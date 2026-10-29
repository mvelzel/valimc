//! The living rules of native mobs (VMC-081d), ported from `Valimc.Living`
//! as they apply to mobs (players keep the Elixir rules): health and its
//! hurt window (`health`), status effects and their ticking (`effects`),
//! attributes with equipment and effect modifiers (`attributes`, `mob`),
//! damage, its sources and enchantment protection (`damage`,
//! `enchantments`), burning, air, freezing, falls and landings (`burning`,
//! `air`, `fall`), knockback (`melee`), item wear (`durability`), the local
//! difficulty (`difficulty`) and explosions (`explosions`); and the body's
//! own rules (`body`: its timers, `/kill`, pushes, entity data values,
//! dimensions and box). The facts beyond `mobs::facts` these read are
//! `LivingFacts` (`facts`).
//!
//! Exactness: numbers keep the Elixir representation, an `f64` rounded to a
//! Java float exactly where the Elixir calls `Float32.round` (`f`); Erlang's
//! `min` and `max` answer their first argument on a tie (`emin`, `emax`),
//! which decides signed zeros; integers wrap where Java's would.

pub mod air;
pub mod attributes;
pub mod body;
pub mod burning;
pub mod damage;
pub mod difficulty;
pub mod durability;
pub mod effects;
pub mod enchantments;
pub mod explosions;
pub mod facts;
pub mod fall;
pub mod health;
pub mod items;
pub mod melee;
pub mod mob;

pub use facts::LivingFacts;

/// `Float32.round`: `(float) value`, widened back.
#[inline]
pub fn f(value: f64) -> f64 {
    value as f32 as f64
}

/// Erlang's `min/2`: the first argument unless the second is smaller.
#[inline]
pub fn emin(a: f64, b: f64) -> f64 {
    if b < a {
        b
    } else {
        a
    }
}

/// Erlang's `max/2`: the first argument unless the second is larger.
#[inline]
pub fn emax(a: f64, b: f64) -> f64 {
    if b > a {
        b
    } else {
        a
    }
}

/// `Float.MAX_VALUE` widened.
pub const FLOAT_MAX: f64 = 3.4028234663852886e38;

/// A draw of `Math.random()`: vanilla's global random, which nothing in the
/// world can observe (knockback's direction for a hit straight from above).
/// A per-thread xorshift seeded from the process's hash seed.
pub fn math_random() -> f64 {
    use std::cell::Cell;
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    thread_local! {
        static STATE: Cell<u64> = Cell::new({
            let mut h = RandomState::new().build_hasher();
            h.write_u64(0x9E37_79B9_7F4A_7C15);
            h.finish() | 1
        });
    }
    STATE.with(|s| {
        let mut x = s.get();
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        s.set(x);
        (x >> 11) as f64 * (1.0 / (1u64 << 53) as f64)
    })
}

#[cfg(test)]
mod tests;
