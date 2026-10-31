//! The `mob_effects` stage's native side (VMC-037p), built only with the
//! `parity` feature: a fresh mob of a type takes a script of effect
//! operations through the living rules (`addEffect`, `removeEffect`,
//! `removeAllEffects`, `setHealth` and the effect tick), and its state is
//! read after each.

use crate::mob_section;
use rustler::types::tuple::get_tuple;
use rustler::{Atom, Encoder, Env, NifResult, Term};
use valimc_core::mobs::living::body as living_body;
use valimc_core::mobs::living::mob as living_mob;
use valimc_core::mobs::model::{NativeMob, Rung};
use valimc_core::mobs::vitals;

mod atoms {
    rustler::atoms! { add, remove, clear, tick, health }
}

type Rungs = Vec<(i32, i32, bool, bool, bool)>;
type State = (bool, Vec<(i32, Rungs)>, f64, f64, f64, f64);

fn bad() -> rustler::Error {
    rustler::Error::BadArg
}

/// After each of `ops`: `{changed, effects, health, maximum, absorption,
/// movement speed}`, the effects as `[{id, [{ticks, amplifier, ambient,
/// particles, icon}]}]`.
#[rustler::nif]
fn mob_effect_parity<'a>(
    env: Env<'a>,
    entity_type: String,
    ops: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    let rules = mob_section::rules()?;
    let ty = rules.of(&entity_type).ok_or_else(bad)?;
    let speed = rules.facts.attributes.id("movement_speed").ok_or_else(bad)?;
    let mut mob = NativeMob {
        uuid: [0; 16],
        position: [0.0; 3],
        hops: 0,
        body: living_body::fresh(&rules, ty),
    };
    let mut out: Vec<State> = Vec::with_capacity(ops.len());
    for op in ops {
        let t = get_tuple(op)?;
        let tag: Atom = t.first().ok_or_else(bad)?.decode()?;
        let arg = |i: usize| t.get(i).copied().ok_or_else(bad);
        let living = &mut mob.body.mob;
        let changed = if tag == atoms::add() {
            let id: i32 = arg(1)?.decode()?;
            let (ticks, amplifier, ambient, particles, icon) = arg(2)?.decode()?;
            let rung = Rung {
                ticks,
                amplifier,
                ambient,
                particles,
                icon,
            };
            let added = living_mob::add_effect(rules.facts, ty.id, living, id, rung);
            living_mob::reconcile_max_health(rules.living, rules.facts, ty, living);
            added
        } else if tag == atoms::remove() {
            let removed = living_mob::remove_effect(rules.facts, living, arg(1)?.decode()?);
            living_mob::reconcile_max_health(rules.living, rules.facts, ty, living);
            removed
        } else if tag == atoms::clear() {
            let cleared = living_mob::clear_effects(rules.facts, living);
            living_mob::reconcile_max_health(rules.living, rules.facts, ty, living);
            cleared
        } else if tag == atoms::health() {
            let value: f64 = arg(1)?.decode()?;
            let health = &mut living.living.health;
            health.value = value.clamp(0.0, health.maximum);
            false
        } else if tag == atoms::tick() {
            let count: i32 = arg(1)?.decode()?;
            for _ in 0..count {
                vitals::base_tick(&rules, &mut mob);
            }
            false
        } else {
            return Err(bad());
        };
        let living = &mob.body.mob;
        let effects = living
            .living
            .effects
            .0
            .iter()
            .map(|(id, rungs)| {
                let rungs = rungs
                    .iter()
                    .map(|r| {
                        (
                            r.ticks,
                            i32::from(r.amplifier),
                            r.ambient,
                            r.particles,
                            r.icon,
                        )
                    })
                    .collect();
                (*id, rungs)
            })
            .collect();
        out.push((
            changed,
            effects,
            living.living.health.value,
            living.living.health.maximum,
            living.living.absorption,
            living_mob::value(rules.living, rules.facts, ty, living, speed),
        ));
    }
    Ok(out.encode(env))
}
