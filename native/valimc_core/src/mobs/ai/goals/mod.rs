//! The goals of `Valimc.AI.Goals`, each a `Goal` holding the Elixir goal's
//! state, with a constructor taking what the families pass. The closures
//! the Elixir goals take as parameters are data (`ItemTest`, `EntityTest`,
//! `MobTypes`, `TargetTest` here; `Tag`s a family's `Hooks` answers).

pub mod avoid_entity;
pub mod breath_air;
pub mod breed;
pub mod climb_powder_snow;
pub mod eat_block;
pub mod float;
pub mod follow_parent;
pub mod follow_ridden;
pub mod idle;
pub mod leap_at_target;
pub mod look_at_player;
pub mod melee_attack;
pub mod move_to_block;
pub mod move_towards_restriction;
pub mod move_towards_target;
pub mod neutral;
pub mod ocelot_attack;
pub mod panic;
pub mod random_look_around;
pub mod random_stroll;
pub mod ranged_attack;
pub mod ranged_bow_attack;
pub mod remove_block;
pub mod sun;
pub mod target;
pub mod tempt;
pub mod try_find_liquid;
pub mod use_item;

pub use avoid_entity::AvoidEntity;
pub use breath_air::BreathAir;
pub use breed::Breed;
pub use climb_powder_snow::ClimbPowderSnow;
pub use eat_block::EatBlock;
pub use float::Float;
pub use follow_parent::FollowParent;
pub use follow_ridden::FollowRidden;
pub use idle::Idle;
pub use leap_at_target::LeapAtTarget;
pub use look_at_player::LookAtPlayer;
pub use melee_attack::MeleeAttack;
pub use move_to_block::MoveToBlock;
pub use move_towards_restriction::MoveTowardsRestriction;
pub use move_towards_target::MoveTowardsTarget;
pub use neutral::ResetUniversalAnger;
pub use ocelot_attack::OcelotAttack;
pub use panic::Panic;
pub use random_look_around::RandomLookAround;
pub use random_stroll::RandomStroll;
pub use ranged_attack::RangedAttack;
pub use ranged_bow_attack::RangedBowAttack;
pub use remove_block::RemoveBlock;
pub use sun::{FleeSun, RestrictSun};
pub use target::{HurtByTarget, NearestAttackableTarget, TargetKind};
pub use tempt::Tempt;
pub use try_find_liquid::TryFindLiquid;
pub use use_item::UseItem;

use super::hooks::{Hooks, Tag};
use super::turn::{Eyes, Kinds};
use super::Extra;
use crate::mobs::facts::Slot;
use crate::mobs::level::Level;
use crate::mobs::sensing::{Entity, GameMode};

/// Which item ids a goal wants (`TemptGoal`'s `items`).
#[derive(Clone, Debug, PartialEq)]
pub enum ItemTest {
    /// `Animal.food?(type, &1)`.
    Food(u16),
    /// One item (`&(&1 == id)`).
    One(i32),
    /// Any of a set (`&MapSet.member?(set, &1)`).
    Set(Vec<i32>),
    Family(Tag),
}

impl ItemTest {
    pub fn test(&self, level: &Level, hooks: &dyn Hooks, item: Option<i32>) -> bool {
        match self {
            ItemTest::Food(type_id) => level.facts.animal.food(*type_id, item),
            ItemTest::One(id) => item == Some(*id),
            ItemTest::Set(ids) => item.is_some_and(|i| ids.contains(&i)),
            ItemTest::Family(tag) => hooks.item(level, *tag, item),
        }
    }
}

/// Which sensed entities a goal takes (`AvoidEntityGoal`'s `select`).
#[derive(Clone, Debug, PartialEq)]
pub enum EntityTest {
    /// `&(&1.kind == :player)`.
    Players,
    /// Mobs of these types.
    Mobs(Vec<u16>),
    /// Mobs of a monster type (`Animal.monster?`).
    Monsters,
    Family(Tag),
}

impl EntityTest {
    pub fn test(&self, level: &Level, hooks: &dyn Hooks, e: Entity<'_, Extra>) -> bool {
        match self {
            EntityTest::Players => matches!(e, Entity::Player(_)),
            EntityTest::Mobs(types) => match e {
                Entity::Mob(m) => types.contains(&m.type_id),
                _ => false,
            },
            EntityTest::Monsters => match e {
                Entity::Mob(m) => level.facts.animal.monster(m.type_id),
                _ => false,
            },
            EntityTest::Family(tag) => hooks.entity(level, *tag, e),
        }
    }
}

/// Which mob types a goal searches (a target goal's `select`, a look
/// goal's `types`).
#[derive(Clone, Debug, PartialEq)]
pub enum MobTypes {
    /// Every type (`fn _ -> true end`).
    Any,
    Types(Vec<u16>),
    Family(Tag),
}

impl MobTypes {
    pub fn kinds(&self) -> Kinds<'_> {
        match self {
            MobTypes::Any => Kinds::Any,
            MobTypes::Types(types) => Kinds::Types(types),
            MobTypes::Family(tag) => Kinds::Family(*tag),
        }
    }
}

/// A target goal's selector of the target and the mob (`selector`).
#[derive(Clone, Debug, PartialEq)]
pub enum TargetTest {
    /// `&(abs(&1.y - &2.y) <= d)`: within `d` blocks up or down.
    WithinY(f64),
    /// `&Neutral.angry_at?(&2, &1)`.
    AngryAt,
    Family(Tag),
}

impl TargetTest {
    pub fn test(&self, level: &Level, eyes: &Eyes, e: Entity<'_, Extra>) -> bool {
        match self {
            TargetTest::WithinY(d) => (e.position()[1] - eyes.position[1]).abs() <= *d,
            TargetTest::AngryAt => neutral::angry_at(level, eyes, e),
            TargetTest::Family(tag) => eyes.hooks.target(level, eyes, *tag, e),
        }
    }
}

/// A sensed player's item in a hand.
pub(crate) fn held(e: Entity<'_, Extra>, slot: Slot) -> Option<i32> {
    match e {
        Entity::Player(p) => p.equipped(slot),
        _ => None,
    }
}

/// A creative or spectating player.
pub(crate) fn exempt(mode: Option<GameMode>) -> bool {
    matches!(mode, Some(GameMode::Creative | GameMode::Spectator))
}
