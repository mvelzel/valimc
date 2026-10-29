//! What families give the AI core (`Valimc.AI.Kind`'s optional callbacks
//! the core calls, dispatched by type through `Valimc.AI.Mobs.hook/4`): one
//! `Hooks` value serves a section's mobs and answers per type, each default
//! being what the Elixir does where no family overrides it (vanilla's
//! `PathfinderMob`).
//!
//! Closures the Elixir goals hold as parameters (a tempt's items, an avoided
//! entity, a target selector, a stroll's guard and position, a ranged
//! attack, a breeding, a block test) are data here: the common cases are
//! enum variants the goals answer themselves, and a family's own is a
//! `Tag` its `Hooks` answers.

use super::goals::move_to_block::MoveToBlock;
use super::mind::LookAt;
use super::turn::{Eyes, Seen, Turn};
use super::Extra;
use crate::mobs::facts::MobFacts;
use crate::mobs::level::Level;
use crate::mobs::model::{Mob, Rung, Slot};
use crate::mobs::sensing::{Entity, Ref};
use crate::mobs::term::Value;

/// A family's own test or action, by the number its `Hooks` gives it.
pub type Tag = u32;

pub trait Hooks: Send + Sync {
    /// `Mob.value(type, mob, name)`: an attribute's value with its
    /// overrides and its equipment's modifiers.
    fn attribute(&self, t: &Turn, name: &str) -> f64 {
        attribute(t.level.facts, t.type_id, &t.mob.body.mob, name)
    }

    /// `set_target/2`: a type's own `setTarget`; false: `put_target`.
    fn set_target(&self, _t: &mut Turn, _target: Option<Ref>) -> bool {
        false
    }

    /// `look_rotations/2`: the yaw and pitch to turn toward (None each:
    /// none); None: the default measure.
    fn look_rotations(&self, _t: &Turn, _look: &LookAt) -> Option<(Option<f64>, Option<f64>)> {
        None
    }

    /// `look_control/1`: its own look control in place of `LookControl`
    /// (true: it ran).
    fn look_control(&self, _t: &mut Turn) -> bool {
        false
    }

    /// `looks?/0`: whether it has a look control at all.
    fn looks(&self, _type_id: u16) -> bool {
        true
    }

    /// `clamps_head?/0`.
    fn clamps_head(&self, _type_id: u16) -> bool {
        true
    }

    /// `turns_body?/0`.
    fn turns_body(&self, _type_id: u16) -> bool {
        true
    }

    /// `walk_value/2`: a family's `getWalkTargetValue` (negative infinity:
    /// never taken); None: `family_value`.
    fn walk_value(&self, _t: &mut Turn, _pos: [i32; 3]) -> Option<f64> {
        None
    }

    /// `stable_destination?/2`: a family's own navigation's judgement.
    fn stable_destination(&self, _t: &Turn, _pos: [i32; 3]) -> Option<bool> {
        None
    }

    /// `can_attack?/2`: `canAttack` beyond `Mob`'s.
    fn can_attack(&self, _eyes: &Eyes, _target: Entity<'_, Extra>) -> bool {
        true
    }

    /// `harmless?/0`: its melee hits hurt nothing.
    fn harmless(&self, _type_id: u16) -> bool {
        false
    }

    /// `hit/2`: what its `doHurtTarget` adds to a melee hit.
    fn hit(&self, _t: &mut Turn, _target: &Seen) {}

    /// `world.melee`: a melee hit on a mob ticking with the thinking one
    /// lands mid-tick, with the effects it made so far; true when it
    /// killed it.
    fn melee(&self, _t: &mut Turn, _target: &Ref) -> bool {
        false
    }

    /// `voice/2`: the base of its voice pitch.
    fn voice(&self, _type_id: u16, _data: &crate::mobs::model::FamilyData) -> f32 {
        1.0
    }

    /// `Living.Effects.add/3` on the mob.
    fn add_effect(&self, t: &mut Turn, id: i32, rung: Rung) {
        crate::mobs::living::effects::add(&mut t.mob.body.mob.living.effects, id, rung);
    }

    /// `Animal.breed/2` (`Breeding::Animal`) or a family's breeding.
    fn breed(&self, _t: &mut Turn, _breeding: Option<Tag>, _partner: &Seen) {}

    /// `Animal.ate/1`: its family's `ate`.
    fn ate(&self, _t: &mut Turn) {}

    /// A family's test of the mob (a guard, a target goal's `when`, a use
    /// item goal's `can_use`).
    fn test(&self, _t: &mut Turn, _tag: Tag) -> bool {
        false
    }

    /// A family's test of an item id (a tempt's items).
    fn item(&self, _level: &Level, _tag: Tag, _item: Option<i32>) -> bool {
        false
    }

    /// A family's test of a sensed entity (an avoided entity).
    fn entity(&self, _level: &Level, _tag: Tag, _target: Entity<'_, Extra>) -> bool {
        false
    }

    /// A family's test of a mob type (a target goal's `select`).
    fn mob_type(&self, _level: &Level, _tag: Tag, _type_id: u16) -> bool {
        false
    }

    /// A family's target selector (`selector`: the target and the mob).
    fn target(&self, _level: &Level, _eyes: &Eyes, _tag: Tag, _target: Entity<'_, Extra>) -> bool {
        false
    }

    /// A family's stroll target (`getPosition`).
    fn position(&self, _t: &mut Turn, _tag: Tag) -> Option<[f64; 3]> {
        None
    }

    /// A family's ranged attack (`performRangedAttack`).
    fn perform(&self, _t: &mut Turn, _tag: Tag, _target: &Seen, _power: f64) {}

    /// `World.find/3`: the blocks of `states` in an inclusive box (the
    /// owner's snapshot search); by default every cell is read.
    fn find(
        &self,
        level: &Level,
        min: [i32; 3],
        max: [i32; 3],
        states: &[u16],
    ) -> Vec<([i32; 3], u16)> {
        let mut out = Vec::new();
        for x in min[0]..=max[0] {
            for y in min[1]..=max[1] {
                for z in min[2]..=max[2] {
                    if let Some(s) = level.block([x, y, z]) {
                        if states.contains(&s) {
                            out.push(([x, y, z], s));
                        }
                    }
                }
            }
        }
        out
    }

    /// A family's block test of a move-to-block goal (`isValidTarget`).
    fn block(&self, _t: &mut Turn, _tag: Tag, _cell: [i32; 3], _goal: &mut MoveToBlock) -> bool {
        false
    }
}

/// What no family overrides.
pub struct DefaultHooks;

impl Hooks for DefaultHooks {}

/// `Weapons`' slot groups: the slots `group` covers.
fn covers(group: &str, slot: Slot) -> bool {
    match group {
        "any" => true,
        "hand" => matches!(slot, Slot::Mainhand | Slot::Offhand),
        "armor" => matches!(slot, Slot::Feet | Slot::Legs | Slot::Chest | Slot::Head),
        other => other == slot.name(),
    }
}

/// An `%ItemStack{}`'s item id.
pub fn item_id(stack: &Value) -> Option<i32> {
    stack
        .as_map()?
        .get_atom("item_id")?
        .as_int()
        .map(|i| i as i32)
}

/// Equipment slots in the order an Elixir equipment map iterates (its atoms
/// sorted).
pub const SORTED_SLOTS: [Slot; 8] = [
    Slot::Body,
    Slot::Chest,
    Slot::Feet,
    Slot::Head,
    Slot::Legs,
    Slot::Mainhand,
    Slot::Offhand,
    Slot::Saddle,
];

/// `Mob.value/3` of a mob of type `type_id`: the override's base (else the
/// type's, else the attribute's default), its modifiers then its
/// equipment's, `Attributes.value/3`'s sums, clamped.
pub fn attribute(facts: &MobFacts, type_id: u16, mob: &Mob, name: &str) -> f64 {
    let Some(fact) = facts.attributes.fetch(name) else {
        return 0.0;
    };
    let name = fact.name.as_str();
    let kept = mob.attributes.get(name);
    let base = kept.and_then(|o| o.base).unwrap_or_else(|| {
        facts
            .entities
            .get(type_id)
            .and_then(|t| t.attribute(name))
            .unwrap_or(fact.default)
    });
    let mut modifiers: Vec<(f64, u8)> = kept
        .map(|o| {
            o.modifiers
                .iter()
                .map(|m| (m.amount.as_f64(), m.operation as u8))
                .collect()
        })
        .unwrap_or_default();
    for slot in SORTED_SLOTS {
        let Some(id) = mob.equipment.get(slot).and_then(item_id) else {
            continue;
        };
        for m in facts.combat.items.get(&id).into_iter().flatten() {
            if m.attribute == fact.id && covers(&m.slot, slot) {
                modifiers.push((m.amount, m.operation));
            }
        }
    }
    let added = modifiers
        .iter()
        .fold(base, |acc, &(a, op)| if op == 0 { acc + a } else { acc });
    let result = modifiers.iter().fold(
        added,
        |acc, &(a, op)| {
            if op == 1 {
                acc + added * a
            } else {
                acc
            }
        },
    );
    let result = modifiers.iter().fold(
        result,
        |acc, &(a, op)| {
            if op == 2 {
                acc * (1.0 + a)
            } else {
                acc
            }
        },
    );
    super::fmath::emin(fact.max, super::fmath::emax(fact.min, result))
}
