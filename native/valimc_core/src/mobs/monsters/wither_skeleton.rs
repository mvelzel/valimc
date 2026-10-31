//! Wither skeletons (`Valimc.AI.Mobs.WitherSkeleton`, vanilla's
//! `WitherSkeleton`): a skeleton (its goals and weapon goal) that also
//! targets piglins, spawns with a stone sword and no armour or enchanting,
//! hits for 4 and withers what it hits for ten seconds, and is never
//! withered itself.

use super::skeleton::Skeleton;
use super::{entity, item, item_tag};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::goal::TARGET;
use crate::mobs::ai::goals::target::TargetOptions;
use crate::mobs::ai::goals::{MobTypes, NearestAttackableTarget, TargetKind};
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::spawn;
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::combat::Family;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, Registered, Registration};
use crate::mobs::model::Slot;
use crate::mobs::term::{Atom, Map, Value};

pub const WITHER_SKELETON: &str = "minecraft:wither_skeleton";

/// The wither skeleton family.
pub struct WitherSkeleton {
    types: [&'static str; 1],
    skeleton: Skeleton,
    piglins: Vec<u16>,
    stone_sword: i32,
    wither: i32,
    disliked: Vec<i32>,
}

impl WitherSkeleton {
    pub fn new(facts: &MobFacts) -> Result<WitherSkeleton, String> {
        Ok(WitherSkeleton {
            types: [WITHER_SKELETON],
            skeleton: Skeleton::new(facts)?,
            piglins: vec![
                entity(facts, "minecraft:piglin")?,
                entity(facts, "minecraft:piglin_brute")?,
            ],
            stone_sword: item(facts, "minecraft:stone_sword")?,
            wither: super::effect(facts, "minecraft:wither")?,
            disliked: item_tag(facts, "minecraft:wither_skeleton_disliked_weapons"),
        })
    }
}

impl Hooks for WitherSkeleton {
    /// `doHurtTarget`: what it hits is withered for ten seconds.
    fn hit(&self, t: &mut Turn, target: &Seen) {
        let rung = Value::tuple([
            Value::Int(200),
            Value::Int(0),
            Value::bool(false),
            Value::bool(true),
            Value::bool(true),
        ]);
        let extras = Map::from_atoms([(
            "effect",
            Value::tuple([Value::Int(self.wither as i64), rung]),
        )]);
        t.effect(Effect::AttackExtra(target.reference, Value::Map(extras)));
    }
}

impl Family for WitherSkeleton {}

impl Kind for WitherSkeleton {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.WitherSkeleton"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    /// `registerGoals`: piglins as targets first, then a skeleton's.
    fn goals(&self, facts: &MobFacts, type_id: u16) -> Registered {
        let mut registered = Kind::goals(&self.skeleton, facts, type_id);
        registered.targets.insert(
            0,
            Registration::new(
                3,
                "NearestAttackableTargetGoal",
                TARGET,
                NearestAttackableTarget::new(
                    TargetKind::Mob,
                    Some(MobTypes::Types(self.piglins.clone())),
                    true,
                    TargetOptions::default(),
                ),
            ),
        );
        registered
    }

    /// `finalizeSpawn`: a mob's, a stone sword (no armour, no enchanting),
    /// loot pickup by the special multiplier, a Halloween head, then an
    /// attack damage of 4.
    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        spawn::mob(t, reason);
        let special = spawn::special(t);
        spawn::equip(t, Slot::Mainhand, Some(super::stack(self.stone_sword)));
        let roll = spawn::level_float(t);
        super::loot(t, roll, special);
        super::halloween(t);
        spawn::set_base(&mut t.mob.body.mob, "minecraft:attack_damage", 4.0);
    }

    fn wants(&self, t: &Turn, item: i32) -> bool {
        Kind::wants(&self.skeleton, t, item)
    }

    /// `canHoldItem`: not a weapon it dislikes.
    fn can_hold(&self, _t: &Turn, item: i32) -> bool {
        !self.disliked.contains(&item)
    }
}
