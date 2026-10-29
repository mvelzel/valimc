//! The living rules' facts (VMC-081d, `valimc_core::mobs::living::facts`),
//! installed once per VM by `Valimc.Entity.NativeLiving.install!` after the
//! mob facts, from the decoded generated files the Elixir decodes too.

use rustler::{Atom, NifResult, Term};
use std::sync::OnceLock;
use valimc_core::mobs::living::LivingFacts;

mod atoms {
    rustler::atoms! { living_facts_missing }
}

pub(crate) static LIVING_FACTS: OnceLock<LivingFacts> = OnceLock::new();

/// Install the living facts (a map of the files' decoded JSON) over the
/// installed mob facts; a second install keeps the first. `{:ok,
/// installed}`; facts that do not parse raise with the reason.
#[rustler::nif(schedule = "DirtyCpu")]
fn mob_living_facts_init(facts: Term) -> NifResult<(Atom, bool)> {
    crate::reply((|| {
        if LIVING_FACTS.get().is_some() {
            return Ok(false);
        }
        let mob = crate::mob_facts::MOB_FACTS
            .get()
            .ok_or("mob facts are not installed")?;
        let json = crate::worldgen::json_of(facts)?;
        Ok(LIVING_FACTS.set(LivingFacts::parse(&json, mob)?).is_ok())
    })())
}

/// The installed facts, or `{:error, :living_facts_missing}`.
#[allow(dead_code)]
pub(crate) fn facts() -> NifResult<&'static LivingFacts> {
    LIVING_FACTS.get().ok_or(rustler::Error::Term(
        Box::new(atoms::living_facts_missing()),
    ))
}
