//! Ambient families (VMC-081d), ported from `Valimc.AI.Mobs`' ambient
//! module: the bat, built as the hostile families are (`monsters`), whose
//! helpers it shares.

pub mod bat;

use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::Kind;

/// Every ported ambient family.
pub fn kinds(facts: &MobFacts) -> Result<Vec<Box<dyn Kind>>, String> {
    Ok(vec![Box::new(bat::Bat::new(facts)?)])
}
