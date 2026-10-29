//! The facts native mob AI reads (VMC-081d, `valimc_core::mobs::facts`),
//! installed once per VM by `Valimc.AI.NativeFacts.install!` from the
//! decoded generated files the Elixir AI decodes too.

use rustler::{Atom, NifResult, Term};
use std::sync::OnceLock;
use valimc_core::mobs::facts::MobFacts;

mod atoms {
    rustler::atoms! { ok, facts_missing }
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

static KINDS: OnceLock<valimc_core::mobs::kinds::Registry> = OnceLock::new();

/// The native families over the installed facts (`kinds::Registry`), made
/// on first use: each type's goals checked against vanilla's.
pub(crate) fn kinds() -> NifResult<&'static valimc_core::mobs::kinds::Registry> {
    if let Some(kinds) = KINDS.get() {
        return Ok(kinds);
    }
    let registry = valimc_core::mobs::kinds::Registry::new(facts()?).map_err(crate::raise)?;
    Ok(KINDS.get_or_init(|| registry))
}

/// The entity types whose families are native, sorted: `{:ok, [type]}`;
/// raises where a family's goals differ from vanilla's.
#[rustler::nif]
fn mob_kinds() -> NifResult<(Atom, Vec<String>)> {
    let facts = facts()?;
    let mut types: Vec<String> = kinds()?
        .types()
        .filter_map(|id| facts.entities.name(id).map(str::to_owned))
        .collect();
    types.sort();
    Ok((atoms::ok(), types))
}
