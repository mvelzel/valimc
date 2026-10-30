//! The brain families (VMC-081d), ported from `Valimc.AI.Brains` and their
//! mob modules: hoglins, piglins, axolotls and villagers think with a brain
//! (`mobs::ai::brain`) and register no goals. Each family is its `Kind`
//! (`Hooks::brain` gives its `BrainFamily`): its brain's sensors,
//! activities and behaviours in vanilla's order, its activity choice, its
//! reactions and its own behaviours.
//!
//! A brain's `RunOne` gates shuffle by randoms of their own, seeded from the
//! mob's uuid as the Elixir seeds them (`gates/1`); vanilla's are unseeded.

pub mod hoglin;

use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::Kind;
use crate::mobs::random::LegacyRandom;
use crate::mobs::sensing::Uuid;

/// Every brain family.
pub fn kinds(facts: &MobFacts) -> Result<Vec<Box<dyn Kind>>, String> {
    Ok(vec![Box::new(hoglin::Hoglin::new(facts)?)])
}

/// The two halves of a uuid (`<<a::64, b::64>>`).
fn halves(uuid: &Uuid) -> (u64, u64) {
    let mut a = [0u8; 8];
    let mut b = [0u8; 8];
    a.copy_from_slice(&uuid[..8]);
    b.copy_from_slice(&uuid[8..]);
    (u64::from_be_bytes(a), u64::from_be_bytes(b))
}

/// `gates/1`: a gate random per salt, `Random.new(a ^ (b * salt) ^ salt)`
/// (the state keeps the low 48 bits, which wrapping keeps).
pub fn gates<const N: usize>(uuid: &Uuid, salts: [u64; N]) -> [LegacyRandom; N] {
    let (a, b) = halves(uuid);
    salts.map(|salt| LegacyRandom::new((a ^ b.wrapping_mul(salt) ^ salt) as i64))
}

/// A sound's id, which the facts must hold.
pub fn sound(facts: &MobFacts, name: &str) -> Result<i32, String> {
    crate::mobs::monsters::sound(facts, name)
}
