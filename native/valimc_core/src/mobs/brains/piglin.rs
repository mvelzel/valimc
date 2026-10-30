//! Piglins (`Valimc.AI.Mobs.Piglin` and `Valimc.AI.Brains.Piglin`,
//! vanilla's `Piglin` and `PiglinAi`):
//!
//! - **The mob**: baby or not, immune to zombification, charging a
//!   crossbow, dancing, may hunt; a baby's size and speed. Its spawn: one
//!   time in five a baby, else a crossbow or a golden sword (a golden spear
//!   one time in ten), the wait before its first hunt, gold armour piece by
//!   piece one time in ten, their enchantments, then a mob's own spawn (a
//!   piglin from a structure is neither baby nor armed). It opens doors.
//! - **Core**: the look and walk sinks; fleeing nemeses (a baby) and
//!   zombified mobs near it; stop holding an admired item when admiring
//!   ends; start admiring a gold item it sees; celebrating a dead target;
//!   anger at a dead one ends.
//! - **Idle**: look at a player holding what it loves; attack (an adult)
//!   whom it is angry at, a nemesis or a player wearing no gold; walk away
//!   from soul fire; looks and walks at random (a stroll, to a piglin, to
//!   what it looks at); look at a player close by. (Hunting hoglins and
//!   riding wait in the Elixir, so they do here.)
//! - **Admire item**: walk to the item; stop if it is too far or out of
//!   reach too long.
//! - **Fight**: drop a target no longer the nearest valid; walk to it;
//!   melee every 20 ticks; a dead hoglin means no hunt for a while.
//! - **Celebrate**, **avoid**: as vanilla's.
//!
//! It picks up a gold item it wants into its off hand and admires it for
//! 119 ticks. When admiring ends it lets the item go: a gold ingot is its
//! barter (`Effect::Barter`: the bartering table, thrown toward the player
//! it sees or a spot near it); another loved item it drops. Hurt, it lets go
//! of what it holds and fights back with the adults around it, or (a baby,
//! or outnumbered by hoglins) flees; a player opening what piglins guard
//! angers the idle ones near.

use crate::mobs::ai::brain::behavior::{self as b, Behavior, Trigger};
use crate::mobs::ai::brain::behaviors::{self as bs, Pick, Speed, Test};
use crate::mobs::ai::brain::fight::{self, Away};
use crate::mobs::ai::brain::sensors;
use crate::mobs::ai::brain::{
    Activity, Brain, BrainFamily, Cond, Conds, Mem, MemValue, Package, Reaction, Sensor,
};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::f;
use crate::mobs::ai::hooks::{item_id, Hooks};
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::ai::{navigation, random_pos, spawn, think, Extra, Opaque};
use crate::mobs::combat::Family;
use crate::mobs::facts::{MobFacts, Slot as FactSlot};
use crate::mobs::kinds::{Kind, NavSpec, Registered};
use crate::mobs::living::items;
use crate::mobs::model::{Body, FamilyData, Hand, Number, Slot};
use crate::mobs::monsters::{entity, fields, flag, item, value};
use crate::mobs::random::LegacyRandom;
use crate::mobs::sensing::{self, Entity, GameMode, Kind as RefKind, Ref, SensedItem, Uuid};
use crate::mobs::term::{Atom, Value};
use std::any::Any;

pub const PIGLIN: &str = "minecraft:piglin";
const SPEED: &str = "minecraft:movement_speed";
const ADMIRE: i64 = 119;

// Its tests, picks, finder, stop test and sensor (tags).
const BABY: u32 = 1;
const NEAR_ZOMBIFIED: u32 = 2;
const NOT_HOLDING_LOVED: u32 = 3;
const DANCING: u32 = 4;
const STOP_FLEEING: u32 = 5;
const HOLDING_WANTED: u32 = 6;
const HOLDING_LOVED: u32 = 1;
const FIND_TARGET: u32 = 1;
const NOT_NEAREST: u32 = 1;
const SENSOR: u32 = 1;

/// The piglin family.
pub struct Piglin {
    types: [&'static str; 1],
    piglin: u16,
    brute: u16,
    hoglin: u16,
    zombified: [u16; 2],
    nemeses: [u16; 2],
    loved: Vec<i32>,
    safe_armor: Vec<i32>,
    repellent_items: Vec<i32>,
    food: Vec<i32>,
    gold_ingot: i32,
    crossbow: i32,
    golden_spear: i32,
    golden_sword: i32,
    armour: [(Slot, i32); 4],
    repellents: Vec<u16>,
    baby_size: Option<[f32; 3]>,
}

/// What a piglin's reaction asks of another (`{:brain, uuid, fun}`).
#[derive(Clone, Debug, PartialEq)]
enum Change {
    /// `anger_if_closer/2`.
    AngerIfCloser(Ref),
    /// `retreat_from_nearest/2`.
    RetreatFromNearest(Ref),
}

fn item_tag(facts: &MobFacts, tag: &str) -> Vec<i32> {
    crate::mobs::monsters::item_tag(facts, tag)
}

impl Piglin {
    pub fn new(facts: &MobFacts) -> Result<Piglin, String> {
        let mut repellents = Vec::new();
        for id in facts
            .tags
            .get("minecraft:block", "minecraft:piglin_repellents")
            .unwrap_or_default()
        {
            let block = facts
                .blocks
                .block(*id as u16)
                .ok_or("bad repellent block")?;
            let campfire = block.name.trim_start_matches("minecraft:") == "soul_campfire";
            for state in block.first..=block.last {
                if !campfire || facts.blocks.property(state, "lit") == Some("true") {
                    repellents.push(state);
                }
            }
        }
        repellents.sort_unstable();
        let piglin = entity(facts, PIGLIN)?;
        Ok(Piglin {
            types: [PIGLIN],
            piglin,
            brute: entity(facts, "minecraft:piglin_brute")?,
            hoglin: entity(facts, "minecraft:hoglin")?,
            zombified: [
                entity(facts, "minecraft:zombified_piglin")?,
                entity(facts, "minecraft:zoglin")?,
            ],
            nemeses: [
                entity(facts, "minecraft:wither_skeleton")?,
                entity(facts, "minecraft:wither")?,
            ],
            loved: item_tag(facts, "minecraft:piglin_loved"),
            safe_armor: item_tag(facts, "minecraft:piglin_safe_armor"),
            repellent_items: item_tag(facts, "minecraft:piglin_repellents"),
            food: item_tag(facts, "minecraft:piglin_food"),
            gold_ingot: item(facts, "minecraft:gold_ingot")?,
            crossbow: item(facts, "minecraft:crossbow")?,
            golden_spear: item(facts, "minecraft:golden_spear")?,
            golden_sword: item(facts, "minecraft:golden_sword")?,
            armour: [
                (Slot::Head, item(facts, "minecraft:golden_helmet")?),
                (Slot::Chest, item(facts, "minecraft:golden_chestplate")?),
                (Slot::Legs, item(facts, "minecraft:golden_leggings")?),
                (Slot::Feet, item(facts, "minecraft:golden_boots")?),
            ],
            repellents,
            baby_size: facts.hostile.babies.get(&piglin).copied(),
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[
            ("baby", Value::bool(false)),
            ("immune", Value::bool(false)),
            ("charging", Value::bool(false)),
            ("dancing", Value::bool(false)),
            ("cannot_hunt", Value::bool(false)),
        ])
    }

    fn loved(&self, item: Option<i32>) -> bool {
        item.is_some_and(|i| self.loved.contains(&i))
    }

    fn look_behaviors(&self, gate: LegacyRandom) -> Box<dyn Behavior> {
        b::run_one(
            vec![
                (bs::look_target(Pick::Player, 8.0), 1),
                (bs::look_target(Pick::Type(self.piglin), 8.0), 1),
                (bs::look_target(Pick::Any, 8.0), 1),
                (b::do_nothing(30, 60), 1),
            ],
            gate,
            Conds::NONE,
        )
    }

    fn move_behaviors(&self, gate: LegacyRandom) -> Box<dyn Behavior> {
        b::run_one(
            vec![
                (bs::stroll(0.6, 10, 7, Test::Always), 2),
                (
                    b::one_shot(bs::interact_with(Pick::Type(self.piglin), 8, 0.6, 2)),
                    2,
                ),
                (
                    bs::walk_to_look_target(Test::Not(HOLDING_WANTED), Speed::of(0.6), 3),
                    2,
                ),
                (b::do_nothing(30, 60), 1),
            ],
            gate,
            Conds::NONE,
        )
    }

    // ## Its state

    fn offhand(t: &Turn) -> Option<Value> {
        t.mob.body.mob.equipment.get(Slot::Offhand).cloned()
    }

    fn not_holding_loved(&self, t: &Turn) -> bool {
        match Piglin::offhand(t) {
            None => true,
            Some(stack) => !self.loved(item_id(&stack)),
        }
    }

    /// `PiglinAi.isNearZombified`: the zombified one it sees within six
    /// blocks.
    fn near_zombified(t: &Turn) -> bool {
        t.remembered(Mem::NearestVisibleZombified)
            .is_some_and(|z| bs::distance_sq(t, &z) < 36.0)
    }

    fn hoglins_outnumber(t: &Turn) -> bool {
        t.mem_int(Mem::VisibleAdultHoglinCount).unwrap_or(0)
            > t.mem_int(Mem::VisibleAdultPiglinCount).unwrap_or(0) + 1
    }

    // `wantsToStopFleeing`: from zombified ones it no longer sees nearest;
    // from hoglins once piglins match their number.
    fn wants_to_stop_fleeing(&self, t: &Turn) -> bool {
        match t.remembered(Mem::AvoidTarget) {
            None => true,
            Some(a) if a.type_id == Some(self.hoglin) => !Piglin::hoglins_outnumber(t),
            Some(a) if a.type_id.is_some_and(|ty| self.zombified.contains(&ty)) => {
                t.mem_ref(Mem::NearestVisibleZombified) != Some(a.reference)
            }
            _ => false,
        }
    }

    /// `PiglinAi.findNearestValidAttackTarget`.
    fn find_target(&self, t: &mut Turn) -> Option<Seen> {
        let angry = t.remembered(Mem::AngryAt);
        if Piglin::near_zombified(t) {
            return None;
        }
        if let Some(a) = angry {
            if sensors::attackable_ignoring_sight(t, &a.reference) {
                return Some(a);
            }
        }
        if t.has(Mem::UniversalAnger) && t.has(Mem::NearestVisibleAttackablePlayer) {
            return t.remembered(Mem::NearestVisibleAttackablePlayer);
        }
        if let Some(nemesis) = t.remembered(Mem::NearestVisibleNemesis) {
            return Some(nemesis);
        }
        let player = t.remembered(Mem::NearestTargetablePlayerNotWearingGold)?;
        sensors::attackable(t, &player.reference).then_some(player)
    }

    // ## Reactions

    /// `PiglinAi.wasHurtBy`.
    fn hurt_by(&self, t: &mut Turn, r: Ref) {
        let Some(attacker) = t.entity(Some(&r)) else {
            return;
        };
        if attacker
            .type_id
            .is_some_and(|ty| ty == self.piglin || ty == self.brute)
        {
            return;
        }
        if Piglin::offhand(t).is_some() {
            self.let_go(t);
        }
        t.forget(Mem::CelebrateLocation);
        t.forget(Mem::Dancing);
        t.forget(Mem::AdmiringItem);
        if attacker.kind() == RefKind::Player {
            t.remember_for(Mem::AdmiringDisabled, MemValue::True, 400);
        }
        if let Some(avoided) = t.remembered(Mem::AvoidTarget) {
            if type_of(&avoided) != type_of(&attacker) {
                t.forget(Mem::AvoidTarget);
            }
        }
        if baby(t) {
            t.remember_for(Mem::AvoidTarget, MemValue::Ref(attacker.reference), 100);
            if sensors::attackable_ignoring_sight(t, &attacker.reference) {
                broadcast(
                    t,
                    Mem::NearbyAdultPiglins,
                    Change::AngerIfCloser(attacker.reference),
                );
            }
        } else if attacker.type_id == Some(self.hoglin) && Piglin::hoglins_outnumber(t) {
            self.avoid_and_rest(t, attacker.reference);
            broadcast(
                t,
                Mem::NearestVisibleAdultPiglins,
                Change::RetreatFromNearest(attacker.reference),
            );
        } else {
            self.retaliate(t, &attacker);
        }
    }

    // `stopHoldingOffHandItem(level, body, false)`: an adult's gold ingot is
    // gone with no barter; another item it drops.
    fn let_go(&self, t: &mut Turn) {
        let Some(stack) = Piglin::offhand(t) else {
            return;
        };
        t.mob.body.mob.equipment.set(Slot::Offhand, None);
        if !(item_id(&stack) == Some(self.gold_ingot) && !baby(t)) {
            t.effect(Effect::Drop(stack));
        }
    }

    // `maybeRetaliate`.
    fn retaliate(&self, t: &mut Turn, attacker: &Seen) {
        if t.active(Activity::Avoid)
            || !sensors::attackable_ignoring_sight(t, &attacker.reference)
            || fight::much_farther(t, attacker, 4.0)
        {
            return;
        }
        self.set_anger(t, attacker);
        broadcast(
            t,
            Mem::NearbyAdultPiglins,
            Change::AngerIfCloser(attacker.reference),
        );
    }

    /// `PiglinAi.setAngerTarget`: angry for 30 seconds at a target it can
    /// attack.
    fn set_anger(&self, t: &mut Turn, target: &Seen) {
        if !sensors::attackable_ignoring_sight(t, &target.reference) {
            return;
        }
        t.forget(Mem::CantReachWalkTargetSince);
        t.remember_for(Mem::AngryAt, MemValue::Ref(target.reference), 600);
        if target.type_id == Some(self.hoglin) && !flag(t.data(), "cannot_hunt") {
            dont_hunt(t);
        }
        if target.kind() == RefKind::Player && t.level.rules.universal_anger {
            t.remember_for(Mem::UniversalAnger, MemValue::True, 600);
        }
    }

    // `setAngerTargetIfCloserThanCurrent`.
    fn anger_if_closer(&self, t: &mut Turn, r: Ref) {
        let Some(new) = t.entity(Some(&r)) else {
            return;
        };
        let current = t.remembered(Mem::AngryAt);
        let nearest = match current {
            Some(c) if bs::distance_sq(t, &c) < bs::distance_sq(t, &new) => c,
            _ => new,
        };
        if current.is_none_or(|c| c.reference != nearest.reference) {
            self.set_anger(t, &nearest);
        }
    }

    // `setAvoidTargetAndDontHuntForAWhile`.
    fn avoid_and_rest(&self, t: &mut Turn, r: Ref) {
        let n = t.level_int(301) as i64;
        t.forget(Mem::AngryAt);
        t.forget(Mem::AttackTarget);
        t.forget(Mem::WalkTarget);
        t.remember_for(Mem::AvoidTarget, MemValue::Ref(r), 100 + n);
        dont_hunt(t);
    }

    fn retreat_from_nearest(&self, t: &mut Turn, r: Ref) {
        let Some(target) = t.entity(Some(&r)) else {
            return;
        };
        let mut nearest = target;
        for m in [Mem::AvoidTarget, Mem::AttackTarget] {
            if let Some(other) = t.remembered(m) {
                if bs::distance_sq(t, &other) < bs::distance_sq(t, &nearest) {
                    nearest = other;
                }
            }
        }
        self.avoid_and_rest(t, nearest.reference);
    }

    /// `PiglinAi.angerNearbyPiglins`: an idle piglin within 16 blocks of the
    /// player, seeing it if `seen`, is angry at it.
    fn anger_from(&self, t: &mut Turn, player: &Seen, seen: bool) {
        let around = sensing::inflate(&player.bbox, 16.0, 16.0, 16.0);
        if !t.active(Activity::Idle) || !sensing::intersects(&t.bbox(), &around) {
            return;
        }
        if seen && !sensors::visible_contains(t, &player.reference) {
            return;
        }
        self.set_anger(t, player);
    }

    // ## Bartering

    // `PiglinAi.stopHoldingOffHandItem(level, body, true)`: a gold ingot is
    // its barter; another loved item it drops.
    fn stop_holding_offhand(&self, t: &mut Turn) {
        let Some(stack) = Piglin::offhand(t) else {
            return;
        };
        t.mob.body.mob.equipment.set(Slot::Offhand, None);
        if item_id(&stack) != Some(self.gold_ingot) {
            t.effect(Effect::Drop(stack));
            return;
        }
        let seed = match t.level.loot_seeds.pop_front() {
            Some(seed) => seed,
            // `:crypto`'s in the Elixir: no gameplay draw.
            None => match t.next_seed() {
                0 => 1,
                s => s,
            },
        };
        // `throwItems`: toward the nearest visible player, else
        // `getRandomNearbyPos` (the bartering table always gives an item);
        // an off-hand swing, then each item.
        let target = match t.remembered(Mem::NearestVisiblePlayer) {
            Some(p) => p.position,
            None => random_pos::land(t, 4, 2).unwrap_or(t.pos()),
        };
        t.swing(Hand::OffHand);
        let hand = f(0.3);
        let [x, y, z] = t.pos();
        let d = [target[0] - x, target[1] + 1.0 - y, target[2] - z];
        let length = (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).sqrt();
        let d = if length < f(1.0e-5) {
            [0.0; 3]
        } else {
            d.map(|v| v / length)
        };
        t.effect(Effect::Barter {
            seed,
            from: [x, t.eye_y() - hand, z],
            velocity: d.map(|v| v * hand),
        });
    }

    // ## Looting

    // `PiglinAi.pickUpItem`: one into its off hand, which it then admires.
    fn take(&self, t: &mut Turn, index: usize) {
        t.forget(Mem::WalkTarget);
        navigation::stop(t);
        let item = &t.sensing.items[index];
        let (uuid, id, components) = (item.uuid, item.item, item.components.clone());
        t.effect(Effect::Pickup {
            item: uuid,
            count: 1,
        });
        let stack = items::new_stack(id, 1, components);
        if let Some(old) = Piglin::offhand(t) {
            t.effect(Effect::Drop(old));
        }
        t.forget(Mem::TimeTryingToReachAdmireItem);
        t.mob.body.mob.equipment.set(Slot::Offhand, Some(stack));
        t.remember_for(Mem::AdmiringItem, MemValue::True, ADMIRE);
        // The item has one less for the mobs after this one.
        t.sensing.items[index].count -= 1;
    }

    // `PiglinAi.getSoundForCurrentActivity`.
    fn activity_sound(&self, t: &Turn) -> &'static str {
        match t.activity() {
            Some(Activity::Fight) => "minecraft:entity.piglin.angry",
            Some(Activity::Avoid) => {
                let near = t
                    .remembered(Mem::AvoidTarget)
                    .is_some_and(|e| bs::distance_sq(t, &e) < 144.0);
                if near {
                    "minecraft:entity.piglin.retreat"
                } else {
                    idle_sound(t)
                }
            }
            Some(Activity::AdmireItem) => "minecraft:entity.piglin.admiring_item",
            Some(Activity::Celebrate) => "minecraft:entity.piglin.celebrate",
            _ => idle_sound(t),
        }
    }
}

fn idle_sound(t: &Turn) -> &'static str {
    if t.has(Mem::NearestPlayerHoldingWantedItem) {
        "minecraft:entity.piglin.jealous"
    } else if t.has(Mem::NearestRepellent) {
        "minecraft:entity.piglin.retreat"
    } else {
        "minecraft:entity.piglin.ambient"
    }
}

fn baby(t: &Turn) -> bool {
    flag(t.data(), "baby")
}

fn type_of(e: &Seen) -> Option<u16> {
    // A player's type is a player's (None here); a mob's its own.
    e.type_id
}

// `dontKillAnyMoreHoglinsForAWhile`: 30 to 120 seconds (the level's random).
fn dont_hunt(t: &mut Turn) {
    let n = t.level_int(1801) as i64;
    t.remember_for(Mem::HuntedRecently, MemValue::True, 600 + n);
}

// `broadcastAngerTarget` / `broadcastRetreat`: each mob of `list`.
fn broadcast(t: &mut Turn, list: Mem, change: Change) {
    for r in t.mem_refs(list) {
        if r.kind == RefKind::Mob {
            t.effect(Effect::Brain {
                mob: r.uuid,
                change: Box::new(change.clone()),
            });
        }
    }
}

/// `setBaby`: the flag and the baby speed modifier.
fn set_baby(t: &mut Turn, baby: bool) {
    t.mob.body.data.set("baby", Value::bool(baby));
    let add = baby.then_some((Number::Float(f(0.2)), 1));
    t.mob
        .body
        .mob
        .attributes
        .toggle(SPEED, "minecraft:baby", add);
}

impl BrainFamily for Piglin {
    fn as_any(&self) -> &dyn Any {
        self
    }

    fn brain(
        &self,
        _facts: &MobFacts,
        uuid: &Uuid,
        _data: &FamilyData,
        random: &mut LegacyRandom,
    ) -> Brain {
        let [look_gate, move_gate, celebrate_gate, avoid_look_gate, avoid_move_gate] =
            super::gates(uuid, [0x5A17, 0x9E37, 0x3C6E, 0x7F4A, 0x1B5D]);
        use Cond::Present;
        let core = vec![
            bs::look_sink(45, 90),
            bs::move_sink(150, 250),
            b::inert("InteractWithDoor"),
            fight::copy_with_expiry(
                Test::Family(BABY),
                Mem::NearestVisibleNemesis,
                Mem::AvoidTarget,
                100,
                140,
            ),
            fight::copy_with_expiry(
                Test::Family(NEAR_ZOMBIFIED),
                Mem::NearestVisibleZombified,
                Mem::AvoidTarget,
                100,
                140,
            ),
            b::one_shot(StopHolding),
            b::one_shot(StartAdmiring { duration: ADMIRE }),
            fight::celebrate_if_target_dead(300),
            fight::stop_angry_if_target_dead(),
        ];
        let idle = vec![
            bs::look_target(Pick::Family(HOLDING_LOVED), 14.0),
            fight::start_attacking(Test::Not(BABY), FIND_TARGET),
            b::inert("StartHuntingHoglin"),
            fight::walk_away(Mem::NearestRepellent, Away::Pos, 1.0, 8, false),
            b::inert("babySometimesRideBabyHoglin"),
            self.look_behaviors(look_gate),
            self.move_behaviors(move_gate),
            bs::look_and_interact(Pick::Player, 4),
        ];
        let admire = vec![
            bs::go_to_wanted_item(Test::Family(NOT_HOLDING_LOVED), 1.0, true, 9),
            b::one_shot(StopIfTooFar { distance: 9.0 }),
            b::one_shot(StopIfTired {
                most: 200,
                disable: 200,
            }),
        ];
        let fight_list = vec![
            fight::stop_if_invalid(Some(NOT_NEAREST), true, None),
            b::inert("BackUpIfTooClose"),
            fight::walk_to_target(Speed::of(1.0)),
            b::inert("SpearApproach"),
            b::inert("SpearAttack"),
            b::inert("SpearRetreat"),
            fight::melee(Test::Always, 20),
            b::inert("CrossbowAttack"),
            b::one_shot(RememberHoglinKilled {
                hoglin: self.hoglin,
            }),
            fight::erase_if(Test::Family(NEAR_ZOMBIFIED), Mem::AttackTarget),
        ];
        let celebrate = vec![
            fight::walk_away(Mem::NearestRepellent, Away::Pos, 1.0, 8, false),
            bs::look_target(Pick::Family(HOLDING_LOVED), 14.0),
            fight::start_attacking(Test::Not(BABY), FIND_TARGET),
            bs::trigger_if(
                Test::Not(DANCING),
                fight::go_to_location(Mem::CelebrateLocation, 2, 1.0),
            ),
            bs::trigger_if(
                Test::Family(DANCING),
                fight::go_to_location(Mem::CelebrateLocation, 4, 0.6),
            ),
            b::run_one(
                vec![
                    (bs::look_target(Pick::Type(self.piglin), 8.0), 1),
                    (bs::stroll(0.6, 2, 1, Test::Always), 1),
                    (b::do_nothing(10, 20), 1),
                ],
                celebrate_gate,
                Conds::NONE,
            ),
        ];
        let avoid = vec![
            fight::walk_away(Mem::AvoidTarget, Away::Entity, 1.0, 12, true),
            self.look_behaviors(avoid_look_gate),
            self.move_behaviors(avoid_move_gate),
            fight::erase_if(Test::Family(STOP_FLEEING), Mem::AvoidTarget),
        ];
        // Riding waits for vehicles: nothing sets a ride target yet.
        let ride = vec![
            b::inert("Mount"),
            b::inert("SetEntityLookTarget"),
            b::inert("RideSequence"),
            b::inert("DismountOrSkipMounting"),
        ];
        let package = |name, list, memory: &'static [Mem]| {
            Package::from(name, 10, list, Conds::new(&[(memory[0], Present)]), memory)
        };
        Brain::new(
            &[
                (Sensor::NearestLiving, 20),
                (Sensor::Players, 20),
                (Sensor::Items, 20),
                (Sensor::HurtBy, 20),
                (Sensor::Family(SENSOR), 20),
            ],
            vec![
                Package::from(Activity::Core, 0, core, Conds::NONE, &[]),
                Package::from(Activity::Idle, 10, idle, Conds::NONE, &[]),
                package(Activity::AdmireItem, admire, &[Mem::AdmiringItem]),
                package(Activity::Fight, fight_list, &[Mem::AttackTarget]),
                package(Activity::Celebrate, celebrate, &[Mem::CelebrateLocation]),
                package(Activity::Avoid, avoid, &[Mem::AvoidTarget]),
                package(Activity::Ride, ride, &[Mem::RideTarget]),
            ],
            random,
            None,
            &[],
        )
    }

    /// `PiglinAi.updateActivity`: the first valid of its activities, its
    /// activity sound when it changed, its aggression and its dance.
    fn update_activity(&self, t: &mut Turn) {
        let old = t.activity();
        t.first_valid(&[
            Activity::AdmireItem,
            Activity::Fight,
            Activity::Avoid,
            Activity::Celebrate,
            Activity::Ride,
            Activity::Idle,
        ]);
        if t.activity() != old {
            if let Some(sound) = t.level.facts.sounds.id(self.activity_sound(t)) {
                think::make_sound(t, sound);
            }
        }
        let target = t.mem_ref(Mem::AttackTarget);
        t.set_aggressive(target.is_some());
        t.put_target(target);
        if !t.has(Mem::CelebrateLocation) {
            t.forget(Mem::Dancing);
        }
        let dancing = t.has(Mem::Dancing);
        t.mob.body.data.set("dancing", Value::bool(dancing));
    }

    /// `AbstractPiglin.playAmbientSound`: only an idle piglin's.
    fn ambient_sound(&self, t: &mut Turn) -> Option<i32> {
        if t.active(Activity::Idle) {
            t.level.facts.sounds.id(self.activity_sound(t))
        } else {
            None
        }
    }

    /// `Mob.aiStep`'s looting after the move: each wanted item within a
    /// block of its box is picked up (`PiglinAi.pickUpItem`).
    fn pick_up(&self, t: &mut Turn) {
        let around = sensing::inflate(&t.bbox(), 1.0, 0.0, 1.0);
        for index in 0..t.sensing.items.len() {
            let item = &t.sensing.items[index];
            let meets = item.count > 0
                && item.pickup_delay == 0
                && sensing::intersects(&sensors::item_box(item), &around);
            if meets && BrainFamily::wants(self, t, &t.sensing.items[index]) {
                self.take(t, index);
            }
        }
    }

    /// `Piglin.wantsToPickUp` (mob griefing, `PiglinAi.wantsToPickup`).
    fn wants(&self, t: &Turn, item: &SensedItem) -> bool {
        let id = item.item;
        if !t.level.rules.mob_griefing
            || self.repellent_items.contains(&id)
            || (t.has(Mem::AdmiringDisabled) && t.has(Mem::AttackTarget))
        {
            false
        } else if id == self.gold_ingot {
            self.not_holding_loved(t)
        } else if self.food.contains(&id) {
            // Food, nuggets and gear go to its inventory, which waits.
            false
        } else if self.loved(Some(id)) {
            self.not_holding_loved(t)
        } else {
            false
        }
    }

    fn reacts(&self) -> bool {
        true
    }

    fn react(&self, t: &mut Turn, event: Reaction) {
        match event {
            Reaction::HurtBy(r) => self.hurt_by(t, r),
            Reaction::Anger { player, seen } => {
                if let Some(p) = t.entity(Some(&player)) {
                    self.anger_from(t, &p, seen);
                }
            }
        }
    }

    fn brain_change(&self, t: &mut Turn, change: &dyn Opaque) {
        match change.as_any().downcast_ref::<Change>() {
            Some(Change::AngerIfCloser(r)) => self.anger_if_closer(t, *r),
            Some(Change::RetreatFromNearest(r)) => self.retreat_from_nearest(t, *r),
            None => {}
        }
    }

    /// `PiglinSpecificSensor`: from what it sees, the first of each kind in
    /// order of distance, the adult piglins it sees and their count, the
    /// adult hoglins it sees, the adult piglins near it, and the nearest
    /// soul fire eight blocks around and four up and down.
    fn scan(&self, t: &mut Turn, _tag: u32) {
        let repellent = sensors::repellent(t, &self.repellents);
        t.remember_opt(Mem::NearestRepellent, repellent.map(MemValue::Pos));
        let visible = sensors::visible_all(t);
        let mut found = Found::default();
        for r in visible {
            self.sort(t, r, &mut found);
        }
        let nearby: Vec<Ref> = t
            .mem_refs(Mem::NearestLivingEntities)
            .into_iter()
            .filter(|r| match t.sensing.entity(r) {
                Some(Entity::Mob(m)) => {
                    (m.type_id == self.piglin || m.type_id == self.brute) && !m.baby
                }
                _ => false,
            })
            .collect();
        let set = |t: &mut Turn, m: Mem, r: Option<Ref>| t.remember_opt(m, r.map(MemValue::Ref));
        set(t, Mem::NearestVisibleNemesis, found.nemesis);
        set(t, Mem::NearestVisibleHuntableHoglin, found.huntable);
        set(t, Mem::NearestVisibleBabyHoglin, found.baby_hoglin);
        set(t, Mem::NearestVisibleZombified, found.zombified);
        set(
            t,
            Mem::NearestTargetablePlayerNotWearingGold,
            found.not_gold,
        );
        set(t, Mem::NearestPlayerHoldingWantedItem, found.holding);
        t.remember(Mem::NearbyAdultPiglins, MemValue::Refs(nearby));
        let count = found.adults.len() as i64;
        t.remember(
            Mem::NearestVisibleAdultPiglins,
            MemValue::Refs(found.adults),
        );
        t.remember(Mem::VisibleAdultPiglinCount, MemValue::Int(count));
        t.remember(Mem::VisibleAdultHoglinCount, MemValue::Int(found.hoglins));
    }

    fn test(&self, t: &mut Turn, tag: u32) -> bool {
        match tag {
            BABY => baby(t),
            NEAR_ZOMBIFIED => Piglin::near_zombified(t),
            NOT_HOLDING_LOVED => self.not_holding_loved(t),
            DANCING => flag(t.data(), "dancing"),
            STOP_FLEEING => self.wants_to_stop_fleeing(t),
            HOLDING_WANTED => t.has(Mem::NearestPlayerHoldingWantedItem),
            _ => false,
        }
    }

    /// `PiglinAi.isPlayerHoldingLovedItem`.
    fn select(&self, _t: &Turn, _tag: u32, e: Entity<'_, Extra>) -> bool {
        match e {
            Entity::Player(p) => {
                self.loved(p.equipped(FactSlot::MainHand))
                    || self.loved(p.equipped(FactSlot::OffHand))
            }
            _ => false,
        }
    }

    fn find(&self, t: &mut Turn, _tag: u32) -> Option<Seen> {
        self.find_target(t)
    }

    /// `isNearestValidAttackTarget`'s negation: the target stops being
    /// attacked.
    fn stop_when(&self, t: &mut Turn, _tag: u32, target: &Seen) -> bool {
        let found = self.find_target(t);
        !found.is_some_and(|f| f.reference == target.reference)
    }

    /// `wantsToDance`: one time in ten after killing a hoglin, from a random
    /// seeded with the game time.
    fn dance(&self, t: &mut Turn, target: &Seen) -> bool {
        target.type_id == Some(self.hoglin)
            && (LegacyRandom::new(t.level.time).float() as f64) < f(0.1)
    }

    fn young(&self, t: &Turn) -> bool {
        baby(t)
    }
}

/// What the sensor finds first of each kind.
#[derive(Default)]
struct Found {
    nemesis: Option<Ref>,
    huntable: Option<Ref>,
    baby_hoglin: Option<Ref>,
    zombified: Option<Ref>,
    not_gold: Option<Ref>,
    holding: Option<Ref>,
    adults: Vec<Ref>,
    hoglins: i64,
}

impl Piglin {
    fn sort(&self, t: &mut Turn, r: Ref, found: &mut Found) {
        enum Seen {
            Player {
                safe: bool,
                spectator: bool,
                loved: bool,
            },
            Mob {
                ty: u16,
                baby: bool,
                huntable: bool,
            },
        }
        let seen = match t.sensing.entity(&r) {
            Some(Entity::Player(p)) => Seen::Player {
                safe: [
                    FactSlot::Head,
                    FactSlot::Chest,
                    FactSlot::Legs,
                    FactSlot::Feet,
                ]
                .into_iter()
                .any(|s| p.equipped(s).is_some_and(|i| self.safe_armor.contains(&i))),
                spectator: p.mode == GameMode::Spectator,
                loved: self.loved(p.equipped(FactSlot::MainHand))
                    || self.loved(p.equipped(FactSlot::OffHand)),
            },
            Some(Entity::Mob(m)) => Seen::Mob {
                ty: m.type_id,
                baby: m.baby,
                huntable: m.huntable,
            },
            _ => return,
        };
        match seen {
            Seen::Player {
                safe,
                spectator,
                loved,
            } => {
                if found.not_gold.is_none() && !safe && t.can_attack(&r) {
                    found.not_gold = Some(r);
                }
                if found.holding.is_none() && !spectator && loved {
                    found.holding = Some(r);
                }
            }
            Seen::Mob { ty, baby, huntable } => {
                if ty == self.hoglin {
                    if baby {
                        found.baby_hoglin.get_or_insert(r);
                    } else {
                        found.hoglins += 1;
                        if huntable {
                            found.huntable.get_or_insert(r);
                        }
                    }
                } else if ty == self.brute {
                    found.adults.push(r);
                } else if ty == self.piglin {
                    if !baby {
                        found.adults.push(r);
                    }
                } else if self.nemeses.contains(&ty) {
                    if found.nemesis.is_none() {
                        found.nemesis = Some(r);
                    }
                } else if self.zombified.contains(&ty) {
                    found.zombified.get_or_insert(r);
                }
            }
        }
    }
}

// ## Its behaviours

/// `StopHoldingItemIfNoLongerAdmiring`.
#[derive(Clone, Debug, PartialEq)]
struct StopHolding;

fn piglin<'w>(t: &Turn<'_, 'w>) -> Option<&'w Piglin> {
    t.family()?.as_any().downcast_ref::<Piglin>()
}

impl Trigger for StopHolding {
    fn conditions(&self) -> Conds {
        Conds::new(&[(Mem::AdmiringItem, Cond::Absent)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        if Piglin::offhand(t).is_none() {
            return false;
        }
        if let Some(p) = piglin(t) {
            p.stop_holding_offhand(t);
        }
        true
    }
}

/// `StartAdmiringItemIfSeen`.
#[derive(Clone, Debug, PartialEq)]
struct StartAdmiring {
    duration: i64,
}

impl Trigger for StartAdmiring {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::NearestVisibleWantedItem, Cond::Present),
            (Mem::AdmiringItem, Cond::Absent),
            (Mem::AdmiringDisabled, Cond::Absent),
            (Mem::DisableWalkToAdmireItem, Cond::Absent),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let item =
            t.mem_ref(Mem::NearestVisibleWantedItem)
                .and_then(|r| match t.sensing.entity(&r) {
                    Some(Entity::Item(i)) => Some(i.item),
                    _ => None,
                });
        match (item, piglin(t)) {
            (Some(item), Some(p)) if p.loved(Some(item)) => {
                t.remember_for(Mem::AdmiringItem, MemValue::True, self.duration);
                true
            }
            _ => false,
        }
    }
}

/// `StopAdmiringIfItemTooFarAway`.
#[derive(Clone, Debug, PartialEq)]
struct StopIfTooFar {
    distance: f64,
}

impl Trigger for StopIfTooFar {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::AdmiringItem, Cond::Present),
            (Mem::NearestVisibleWantedItem, Cond::Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let item = t.remembered(Mem::NearestVisibleWantedItem);
        if Piglin::offhand(t).is_some() {
            return false;
        }
        if item.is_some_and(|i| bs::distance_sq(t, &i) < self.distance * self.distance) {
            return false;
        }
        t.forget(Mem::AdmiringItem);
        true
    }
}

/// `StopAdmiringIfTiredOfTryingToReachItem`.
#[derive(Clone, Debug, PartialEq)]
struct StopIfTired {
    most: i64,
    disable: i64,
}

impl Trigger for StopIfTired {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::AdmiringItem, Cond::Present),
            (Mem::NearestVisibleWantedItem, Cond::Present),
            (Mem::TimeTryingToReachAdmireItem, Cond::Registered),
            (Mem::DisableWalkToAdmireItem, Cond::Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        if Piglin::offhand(t).is_some() {
            return false;
        }
        match t.mem_int(Mem::TimeTryingToReachAdmireItem) {
            None => t.remember(Mem::TimeTryingToReachAdmireItem, MemValue::Int(0)),
            Some(time) if time > self.most => {
                t.forget(Mem::AdmiringItem);
                t.forget(Mem::TimeTryingToReachAdmireItem);
                t.remember_for(Mem::DisableWalkToAdmireItem, MemValue::True, self.disable);
            }
            Some(time) => t.remember(Mem::TimeTryingToReachAdmireItem, MemValue::Int(time + 1)),
        }
        true
    }
}

/// `RememberIfHoglinWasKilled`: a dead hoglin target means no hunt for a
/// while.
#[derive(Clone, Debug, PartialEq)]
struct RememberHoglinKilled {
    hoglin: u16,
}

impl Trigger for RememberHoglinKilled {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::AttackTarget, Cond::Present),
            (Mem::HuntedRecently, Cond::Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        match t.remembered(Mem::AttackTarget) {
            Some(e) if e.type_id == Some(self.hoglin) && !e.alive => {
                dont_hunt(t);
                true
            }
            _ => false,
        }
    }
}

// ## The mob

impl Hooks for Piglin {
    fn brain(&self) -> Option<&dyn BrainFamily> {
        Some(self)
    }

    fn voice(&self, _type_id: u16, data: &FamilyData) -> f32 {
        if flag(data, "baby") {
            1.5
        } else {
            1.0
        }
    }
}

impl Family for Piglin {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Piglin::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let d = &body.data;
        vec![
            value(
                "piglin_immune",
                Value::bool(flag(d, "immune")),
                Value::bool(false),
            ),
            value(
                "piglin_baby",
                Value::bool(flag(d, "baby")),
                Value::bool(false),
            ),
            value(
                "piglin_charging_crossbow",
                Value::bool(flag(d, "charging")),
                Value::bool(false),
            ),
            value(
                "piglin_dancing",
                Value::bool(flag(d, "dancing")),
                Value::bool(false),
            ),
        ]
    }

    fn dimensions(&self, body: &Body) -> Option<[f32; 3]> {
        if flag(&body.data, "baby") {
            self.baby_size
        } else {
            None
        }
    }

    fn voice(&self, body: &Body) -> f32 {
        Hooks::voice(self, self.piglin, &body.data)
    }
}

impl Kind for Piglin {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Piglin"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    /// A brain mob registers no goals.
    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered::default()
    }

    /// `AbstractPiglin.applyOpenDoorsAbility`.
    fn navigation(&self, _type_id: u16) -> NavSpec {
        NavSpec {
            can_open_doors: true,
            ..NavSpec::default()
        }
    }

    /// `Piglin.finalizeSpawn`.
    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        // A piglin picks up loot from the start (`AbstractPiglin`).
        t.mob.body.mob.can_pick_up_loot = true;
        if reason.as_str() != "structure" {
            if spawn::level_float(t) < f(0.2) {
                set_baby(t, true);
            } else {
                // `createSpawnWeapon`, from its own random.
                let item = if t.float() < 0.5 {
                    self.crossbow
                } else if t.int(10) == 0 {
                    self.golden_spear
                } else {
                    self.golden_sword
                };
                spawn::equip(t, Slot::Mainhand, Some(items::new_stack(item, 1, None)));
            }
        }
        // `PiglinAi.initMemories`: no hunt for 30 to 120 seconds.
        let n = spawn::level_int(t, 1801) as i64;
        if t.brain().is_some() {
            t.remember_for(Mem::HuntedRecently, MemValue::True, 600 + n);
        }
        // `populateDefaultEquipmentSlots`: an adult's gold armour, each
        // piece one time in ten.
        if !baby(t) {
            for (slot, id) in self.armour {
                if spawn::level_float(t) < f(0.1) {
                    spawn::equip(t, slot, Some(items::new_stack(id, 1, None)));
                }
            }
        }
        spawn::enchant_equipment(t);
        spawn::mob(t, reason);
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Piglin::data_of()
    }
}
