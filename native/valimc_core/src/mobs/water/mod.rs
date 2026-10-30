//! Water families (VMC-081d), ported from `Valimc.AI.Mobs`' water modules:
//! fish (cod, salmon, pufferfish, tropical fish), squid (glow squid),
//! guardians (elder guardians) and dolphins. Each is a `Kind` built as the
//! hostile families are (`monsters`), whose helpers they share.

pub mod dolphin;
pub mod fish;

use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::Kind;

pub use crate::mobs::monsters::{effect, entity, fields, flag, int, item, sound, value};

/// Every ported water family.
pub fn kinds(facts: &MobFacts) -> Result<Vec<Box<dyn Kind>>, String> {
    use fish::{Fish, FishKind};
    Ok(vec![
        Box::new(Fish::new(facts, FishKind::Plain)?),
        Box::new(Fish::new(facts, FishKind::Pufferfish)?),
        Box::new(Fish::new(facts, FishKind::Tropical)?),
        Box::new(dolphin::Dolphin::new(facts)?),
    ])
}
