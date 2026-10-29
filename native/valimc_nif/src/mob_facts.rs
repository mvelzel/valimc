//! The facts native mob AI reads (VMC-081d, `valimc_core::mobs::facts`),
//! installed once per VM by `Valimc.AI.NativeFacts.install!` from the
//! decoded generated files the Elixir AI decodes too.

use rustler::{Atom, NifResult, Term};
use std::sync::OnceLock;
use valimc_core::mobs::facts::MobFacts;

mod atoms {
    rustler::atoms! { facts_missing }
}

pub(crate) static MOB_FACTS: OnceLock<MobFacts> = OnceLock::new();

/// Install the mob facts (a map of the files' decoded JSON); a second
/// install keeps the first. `{:ok, installed}`; facts that do not parse
/// raise with the reason.
#[rustler::nif(schedule = "DirtyCpu")]
fn mob_facts_init(facts: Term) -> NifResult<(Atom, bool)> {
    crate::reply((|| {
        if MOB_FACTS.get().is_some() {
            return Ok(false);
        }
        let json = crate::worldgen::json_of(facts)?;
        Ok(MOB_FACTS.set(MobFacts::parse(&json)?).is_ok())
    })())
}

/// The installed facts, or `{:error, :facts_missing}`.
#[allow(dead_code)]
pub(crate) fn facts() -> NifResult<&'static MobFacts> {
    MOB_FACTS
        .get()
        .ok_or(rustler::Error::Term(Box::new(atoms::facts_missing())))
}
