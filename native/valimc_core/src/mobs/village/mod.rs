//! Village mobs with goals (VMC-081d), ported from `Valimc.AI.Mobs`: iron
//! golems and wandering traders. Each is a `Kind` built as the hostile
//! families are (`monsters`), its own data the Elixir family's atom-keyed
//! map. Villagers think with a brain and move with the brain families.

pub mod iron_golem;
pub mod merchant;
pub mod wandering_trader;

use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::Kind;

/// Every ported village family.
pub fn kinds(facts: &MobFacts) -> Result<Vec<Box<dyn Kind>>, String> {
    Ok(vec![
        Box::new(iron_golem::IronGolem::new(facts)?),
        Box::new(wandering_trader::WanderingTrader::new(facts)?),
    ])
}
