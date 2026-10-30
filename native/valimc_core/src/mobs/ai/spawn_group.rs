//! A natural spawn's pack finishing as one group (`SpawnGroupData`): the
//! members of an aquatic pack run their `finalizeSpawn` in spawn order with
//! what the group shares (an axolotl group's two common variants, the
//! babies after the first member of an ageable group, a school's leader and
//! a tropical fish school's variant), each on its section's level random.
//! Ported from `Valimc.AI.SpawnGroup` (VMC-043e9).

use super::spawn;
use super::turn::Turn;
use crate::mobs::brains::axolotl::COMMONS;
use crate::mobs::sensing::Uuid;
use crate::mobs::term::{Atom, Value};
use crate::mobs::water::dolphin::MAX_AIR;
use crate::mobs::water::fish::{self, School};
use std::collections::HashMap;

/// The types whose packs finish as a group.
pub const TYPES: [&str; 8] = [
    "minecraft:axolotl",
    "minecraft:turtle",
    "minecraft:cod",
    "minecraft:salmon",
    "minecraft:tropical_fish",
    "minecraft:dolphin",
    "minecraft:squid",
    "minecraft:glow_squid",
];

/// What a pack's members share (`SpawnGroupData`).
#[derive(Clone, Debug, Default)]
pub struct Group {
    /// Members finished so far.
    count: i32,
    /// An axolotl group's two common variants.
    variants: Option<(i64, i64)>,
    /// A school's leader.
    leader: Option<Uuid>,
    /// A tropical fish school's variant.
    variant: Option<i64>,
}

/// The schools the packs made, by fish: its leader (None for a leader) and
/// the size it leads.
pub type Schools = HashMap<Uuid, School>;

/// One member's `finalizeSpawn` for `reason` on its turn, with its pack's
/// `group` (None for the first) and, for a tropical fish, the natural-spawn
/// kernel's school decision. Its pending reason is taken first.
pub fn finalize(
    t: &mut Turn,
    reason: &Atom,
    group: &mut Option<Group>,
    decision: Option<bool>,
    schools: &mut Schools,
) {
    let facts = t.level.facts;
    let name = facts
        .entities
        .name(t.type_id)
        .unwrap_or_default()
        .to_owned();
    match name.as_str() {
        "minecraft:axolotl" => axolotl(t, reason, group),
        "minecraft:turtle" => {
            let [x, y, z] = t.block();
            t.mob
                .body
                .data
                .set("home", Value::ivec3([x as i64, y as i64, z as i64]));
            ageable(t, reason, group, facts.animal.group_baby_chance as f64);
        }
        "minecraft:dolphin" => {
            t.mob.body.mob.living.air_supply = MAX_AIR;
            t.mob.body.pitch = 0.0;
            ageable(t, reason, group, water_chance(t));
        }
        "minecraft:squid" | "minecraft:glow_squid" => ageable(t, reason, group, water_chance(t)),
        "minecraft:tropical_fish" => tropical(t, reason, group, decision, schools),
        "minecraft:cod" | "minecraft:salmon" => {
            if name == "minecraft:salmon" {
                let n = t.int(95);
                let size = if n < 30 {
                    0
                } else if n < 80 {
                    1
                } else {
                    2
                };
                t.mob.body.data.set("size", Value::Int(size));
            }
            spawn::mob(t, reason);
            school(t, group, schools);
        }
        _ => spawn::mob(t, reason),
    }
}

fn water_chance(t: &Turn) -> f64 {
    t.level
        .facts
        .animal
        .water_ageable
        .get(&t.type_id)
        .map_or(0.0, |(chance, _)| *chance as f64)
}

/// `Axolotl.finalizeSpawn`: nothing for a bucket's release; else its
/// group's two common variants (drawn by the first), one of them its own,
/// a baby from the third member on, then `Mob`'s part.
fn axolotl(t: &mut Turn, reason: &Atom, group: &mut Option<Group>) {
    if reason.as_str() == "bucket" {
        return;
    }
    let g = group.get_or_insert_with(|| {
        let a = spawn::level_int(t, COMMONS.len() as i32) as usize;
        let b = spawn::level_int(t, COMMONS.len() as i32) as usize;
        Group {
            variants: Some((COMMONS[a], COMMONS[b])),
            ..Group::default()
        }
    });
    let (a, b) = g.variants.unwrap_or((0, 0));
    let i = spawn::level_int(t, 2);
    t.mob
        .body
        .data
        .set("variant", Value::Int(if i == 0 { a } else { b }));
    if g.count >= 2 {
        t.mob.body.data.set("age", Value::Int(-24_000));
    }
    g.count += 1;
    spawn::mob(t, reason);
}

/// `AgeableMob.finalizeSpawn`: after its group's first, a baby with the
/// group's chance; then `Mob`'s part.
fn ageable(t: &mut Turn, reason: &Atom, group: &mut Option<Group>, chance: f64) {
    let g = group.get_or_insert_with(Group::default);
    if g.count > 0 && spawn::level_float(t) <= chance {
        t.mob.body.data.set("age", Value::Int(-24_000));
    }
    spawn::mob(t, reason);
    g.count += 1;
}

/// `AbstractSchoolingFish.finalizeSpawn`'s group: the first leads, the
/// others follow it.
fn school(t: &mut Turn, group: &mut Option<Group>, schools: &mut Schools) {
    let me = t.uuid;
    match group {
        None => {
            *group = Some(Group {
                count: 1,
                leader: Some(me),
                ..Group::default()
            });
        }
        Some(g) => {
            if let Some(leader) = g.leader {
                schools.entry(me).or_default().leader = Some(leader);
                schools.entry(leader).or_default().school += 1;
            }
            g.count += 1;
        }
    }
}

/// `TropicalFish.finalizeSpawn`: `Mob`'s part and its school, then the
/// school's variant, or its own after the school decision (the kernel's,
/// else nine in ten from the level's random); a schooling first member
/// leads the school with its variant.
fn tropical(
    t: &mut Turn,
    reason: &Atom,
    group: &mut Option<Group>,
    decision: Option<bool>,
    schools: &mut Schools,
) {
    spawn::mob(t, reason);
    school(t, group, schools);
    let Some(g) = group.as_mut() else { return };
    if let Some(variant) = g.variant {
        t.mob.body.data.set("variant", Value::Int(variant));
        return;
    }
    let schooling = match decision {
        Some(d) => d,
        None => spawn::level_float(t) < crate::mobs::ai::fmath::f(0.9),
    };
    fish::spawn_variant(t, schooling);
    if schooling {
        g.leader = Some(t.uuid);
        g.count = 1;
        g.variant = t.mob.body.data.get("variant").and_then(Value::as_int);
    }
}
