//! `Mob.finalizeSpawn` (VMC-081d), ported from `Valimc.AI.Spawn`: what a mob
//! decides as it enters the world, run before anything else in its first
//! tick (`think::think`) for the reason it was made. The level's random
//! draws what vanilla draws from `level.getRandom()`, the mob's own what it
//! draws from `this.random`. `mob` is `Mob`'s own part (a follow range
//! bonus, handedness); families add theirs (`Kind::finalize`).

use super::turn::Turn;
use crate::mobs::ai::fmath::f;
use crate::mobs::model::{Mob, Modifier, Number};
use crate::mobs::random::LegacyRandom;
use crate::mobs::term::Atom;

pub const FOLLOW: &str = "minecraft:follow_range";
pub const BONUS: &str = "minecraft:random_spawn_bonus";

/// `Spawn.mob/2` on a turn: `mob_parts` with the level's random.
pub fn mob(t: &mut Turn, _reason: &Atom) {
    mob_parts(&mut t.mob.body.mob, &mut t.level.random);
}

/// `Spawn.mob/2`: a follow range bonus (a triangle of two doubles) unless
/// it has one, and left-handedness one time in twenty, from the level's
/// `random`.
pub fn mob_parts(mob: &mut Mob, random: &mut LegacyRandom) {
    if !has_modifier(mob, FOLLOW, BONUS) {
        let a = random.double();
        let b = random.double();
        add_modifier(mob, FOLLOW, BONUS, 0.11485000000000001 * (a - b), 1);
    }
    let roll = random.float() as f64;
    mob.left_handed = roll < f(0.05);
}

/// `has_modifier?/3`: attribute `name` has modifier `id`.
pub fn has_modifier(mob: &Mob, name: &str, id: &str) -> bool {
    mob.attributes
        .get(name)
        .is_some_and(|o| o.modifiers.iter().any(|m| m.id == id))
}

/// `addOrReplacePermanentModifier`: `{id, amount, operation}` on attribute
/// `name`, after its others.
pub fn add_modifier(mob: &mut Mob, name: &str, id: &str, amount: f64, operation: i32) {
    let entry = mob.attributes.entry(name);
    entry.modifiers.retain(|m| m.id != id);
    entry.modifiers.push(Modifier {
        id: id.to_owned(),
        amount: Number::Float(amount),
        operation,
    });
}

/// `setBaseValue` of attribute `name`.
pub fn set_base(mob: &mut Mob, name: &str, base: f64) {
    mob.attributes.entry(name).base = Some(base);
}

/// `level.getRandom().nextInt(bound)` (`Spawn.level_int/2`).
pub fn level_int(t: &mut Turn, bound: i32) -> i32 {
    t.level.random.int(bound)
}

/// `level.getRandom().nextFloat()`, widened.
pub fn level_float(t: &mut Turn) -> f64 {
    t.level.random.float() as f64
}

/// `level.getRandom().nextDouble()`.
pub fn level_double(t: &mut Turn) -> f64 {
    t.level.random.double()
}

/// `level.getRandom().nextBoolean()`.
pub fn level_boolean(t: &mut Turn) -> bool {
    t.level.random.boolean()
}
