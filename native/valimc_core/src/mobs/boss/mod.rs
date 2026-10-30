//! Boss families (VMC-081d): the ender dragon, ported from
//! `Valimc.Entity.Dragon` and `Valimc.AI.Dragon`.

pub mod dragon;

use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::Kind;

/// Every ported boss family (none without the dragon's facts).
pub fn kinds(facts: &MobFacts) -> Result<Vec<Box<dyn Kind>>, String> {
    Ok(match &facts.dragon {
        Some(_) => vec![Box::new(dragon::Dragon::new(facts))],
        None => Vec::new(),
    })
}
