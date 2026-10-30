//! Native mobs (VMC-081d, `valimc_core::mobs`). For now: the record codec's
//! facts and a round trip through the native model, which checks that a
//! native mob writes exactly the record an Elixir one does.

use rustler::{Atom, Encoder, Env, NifResult, ResourceArc, Term};
use valimc_core::mobs::record::{self, RecordError, RecordFacts, TypeFacts};
use valimc_core::mobs::term::Value;

use crate::mob_term;

mod atoms {
    rustler::atoms! { ok, error, invalid, unsupported }
}

/// What the record codec knows of entity types and effects.
pub struct MobRecordFacts(pub(crate) RecordFacts);

#[rustler::resource_impl]
impl rustler::Resource for MobRecordFacts {}

/// The codec's facts from `%{effect_count, absorption_effect,
/// max_absorption, types: [{name, living, max_health, data_keys}]}`.
#[rustler::nif]
fn mob_record_facts(facts: Term) -> NifResult<(Atom, ResourceArc<MobRecordFacts>)> {
    let facts = mob_term::decode(facts)?;
    let parsed = parse_facts(&facts).ok_or(rustler::Error::BadArg)?;
    Ok((atoms::ok(), ResourceArc::new(MobRecordFacts(parsed))))
}

pub(crate) fn parse_facts(facts: &Value) -> Option<RecordFacts> {
    let map = facts.as_map()?;
    let int = |key| i32::try_from(map.get_atom(key)?.as_int()?).ok();
    let mut out = RecordFacts::new(
        int("effect_count")?,
        int("absorption_effect")?,
        map.get_atom("max_absorption")?.as_number()?,
    );
    for entry in map.get_atom("types")?.as_list()? {
        let [name, living, max_health, keys] = entry.as_tuple_n::<4>()?;
        let name = std::str::from_utf8(name.as_binary()?).ok()?;
        let data_keys = keys
            .as_list()?
            .iter()
            .map(|k| k.as_atom().cloned())
            .collect::<Option<Vec<_>>>()?;
        out.insert_type(
            name,
            TypeFacts {
                living: living.as_bool()?,
                max_health: max_health.as_number()?,
                data_keys,
            },
        );
    }
    Some(out)
}

/// A store record read into a native mob and written back: `{:ok, record}`,
/// or `{:error, {:invalid | :unsupported, check}}`.
#[rustler::nif]
fn mob_record_roundtrip<'a>(
    env: Env<'a>,
    facts: ResourceArc<MobRecordFacts>,
    record: Term<'a>,
) -> NifResult<Term<'a>> {
    let value = mob_term::decode(record)?;
    match record::restore(&value, &facts.0) {
        Ok(mob) => Ok((atoms::ok(), mob_term::encode(env, &record::record(&mob))?).encode(env)),
        Err(error) => {
            let (kind, check) = match error {
                RecordError::Invalid(check) => (atoms::invalid(), check),
                RecordError::Unsupported(check) => (atoms::unsupported(), check),
            };
            Ok((atoms::error(), (kind, check)).encode(env))
        }
    }
}
