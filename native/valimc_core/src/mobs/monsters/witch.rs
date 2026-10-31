//! Witches (`Valimc.AI.Mobs.Witch`, vanilla's `Witch`):
//!
//! - **Goals**: a raider's (patrols, banners, raids and celebrations: idle
//!   without raids), floating, throwing potions at its target
//!   (`RangedAttackGoal`, every three seconds within ten blocks), wandering
//!   and looking around; whoever hurt it (not a raider), raiders to heal
//!   (none without a raid) and players as targets.
//! - **Drinking** (its `aiStep` first): not drinking, by chance it drinks
//!   water breathing with its eyes in water, fire resistance burning,
//!   healing hurt, or swiftness after a far target; the potion in its hand,
//!   slowed for 32 ticks, then its effects. Now and then it shows its
//!   particles (entity event 15).
//! - **Throwing** (`performRangedAttack`): slowness at a far target without
//!   it, poison at a healthy one without it, weakness now and then close
//!   by, else harming, as a splash potion (`{:throw_potion, ...}`).
//! - **Hurts**: magic it resists takes 15% (`witch_resistant_to`).

use super::{fields, flag, int, item, value};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::f;
use crate::mobs::ai::goal::{Goal, JUMP, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::target::TargetOptions;
use crate::mobs::ai::goals::{
    Float, HurtByTarget, Idle, LookAtPlayer, NearestAttackableTarget, RandomLookAround,
    RandomStroll, RangedAttack, TargetKind,
};
use crate::mobs::ai::hooks::{item_id, Hooks, Tag};
use crate::mobs::ai::spawn;
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::combat::{Family, Hit};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, Registered, Registration};
use crate::mobs::living::items;
use crate::mobs::model::{Body, FamilyData, Number, Slot};
use crate::mobs::sensing::Kind as RefKind;
use crate::mobs::term::{Atom, Map, Value, NIL};

pub const WITCH: &str = "minecraft:witch";

const SPEED: &str = "minecraft:movement_speed";
const DRINKING: &str = "minecraft:drinking";
/// Its ranged attack (`throw/3`).
const THROW: Tag = 1;

/// The witch family.
pub struct Witch {
    types: [&'static str; 1],
    raiders: Vec<u16>,
    potion: i32,
    splash_potion: i32,
    water_breathing: i32,
    fire_resistance: i32,
    swiftness: i32,
    slowness: i32,
    poison: i32,
    weakness: i32,
    drink_sound: i32,
    throw_sound: i32,
    /// Damage types it resists (`witch_resistant_to`) and fire's.
    resisted: Vec<i32>,
    fire: Vec<i32>,
}

impl Witch {
    pub fn new(facts: &MobFacts) -> Result<Witch, String> {
        let damage = |tag: &str| {
            facts
                .tags
                .get("minecraft:damage_type", tag)
                .map(<[i32]>::to_vec)
                .unwrap_or_default()
        };
        let raiders = facts
            .tags
            .get("minecraft:entity_type", "minecraft:raiders")
            .unwrap_or_default()
            .iter()
            .map(|&id| id as u16)
            .collect();
        Ok(Witch {
            types: [WITCH],
            raiders,
            potion: item(facts, "minecraft:potion")?,
            splash_potion: item(facts, "minecraft:splash_potion")?,
            water_breathing: super::effect(facts, "minecraft:water_breathing")?,
            fire_resistance: super::effect(facts, "minecraft:fire_resistance")?,
            swiftness: super::effect(facts, "minecraft:speed")?,
            slowness: super::effect(facts, "minecraft:slowness")?,
            poison: super::effect(facts, "minecraft:poison")?,
            weakness: super::effect(facts, "minecraft:weakness")?,
            drink_sound: super::sound(facts, "minecraft:entity.witch.drink")?,
            throw_sound: super::sound(facts, "minecraft:entity.witch.throw")?,
            resisted: damage("minecraft:witch_resistant_to"),
            fire: damage("minecraft:is_fire"),
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[
            ("drinking", Value::bool(false)),
            ("using_time", Value::Int(0)),
            ("heal_cooldown", Value::Int(0)),
        ])
    }

    /// A stack of `item` holding potion `name`
    /// (`%{potion_contents => %{potion: id, ...}}`).
    fn potion_stack(&self, facts: &MobFacts, item: i32, name: &str) -> Value {
        let id = facts.potion(name).map_or(NIL, |id| Value::Int(id as i64));
        let contents = Map::from_atoms([
            ("potion", id),
            ("color", NIL),
            ("effects", Value::List(Vec::new())),
            ("name", NIL),
        ]);
        let components = Map::from_pairs(vec![(
            Value::Binary(b"minecraft:potion_contents".to_vec()),
            Value::Map(contents),
        )])
        .unwrap_or_default();
        items::new_stack(item, 1, Some(Value::Map(components)))
    }

    /// The potion id a drink in hand holds.
    fn potion_of(&self, stack: &Value) -> Option<i64> {
        if item_id(stack) != Some(self.potion) {
            return None;
        }
        items::component(stack, "minecraft:potion_contents")?
            .as_map()?
            .get_atom("potion")?
            .as_int()
    }

    // ## Drinking

    fn drink(&self, t: &mut Turn) {
        let using = int(t.data(), "using_time");
        if using > 0 {
            t.mob.body.data.set("using_time", Value::Int(using - 1));
            return;
        }
        let stack = t.mob.body.mob.equipment.get(Slot::Mainhand).cloned();
        t.mob.body.mob.equipment.set(Slot::Mainhand, None);
        let facts = t.level.facts;
        if let Some(id) = stack.as_ref().and_then(|s| self.potion_of(s)) {
            let effects = facts
                .potions
                .get(id as usize)
                .map(|p| p.effects.clone())
                .unwrap_or_default();
            for (effect, rungs) in effects {
                if let Some(&rung) = rungs.first() {
                    crate::mobs::living::mob::add_effect(
                        facts,
                        t.type_id,
                        &mut t.mob.body.mob,
                        effect,
                        rung,
                    );
                }
            }
        }
        let data = &mut t.mob.body.data;
        data.set("drinking", Value::bool(false));
        data.set("using_time", Value::Int(using - 1));
        modify(t, false);
    }

    fn maybe_drink(&self, t: &mut Turn) {
        let Some(potion) = self.choose(t) else {
            return;
        };
        let facts = t.level.facts;
        let stack = self.potion_stack(facts, self.potion, potion);
        let roll = t.float();
        let pitch = f(f(0.8) + f(roll * f(0.4)));
        t.mob.body.mob.equipment.set(Slot::Mainhand, Some(stack));
        t.mob.body.data.set("drinking", Value::bool(true));
        t.mob.body.data.set("using_time", Value::Int(32));
        t.effect(Effect::SoundAt {
            id: self.drink_sound,
            source: "hostile",
            at: t.pos(),
            volume: 1.0,
            pitch,
        });
        modify(t, true);
    }

    // Each chance is drawn only as the ones before it fail.
    fn choose(&self, t: &mut Turn) -> Option<&'static str> {
        let has = |t: &Turn, id: i32| t.mob.body.mob.living.effects.get(id).is_some();
        let target = t.target();
        let checks: [(f64, &'static str); 4] = [
            (0.15, "minecraft:water_breathing"),
            (0.15, "minecraft:fire_resistance"),
            (0.05, "minecraft:healing"),
            (0.5, "minecraft:swiftness"),
        ];
        for (i, (chance, potion)) in checks.into_iter().enumerate() {
            let roll = t.float();
            if roll >= f(chance) {
                continue;
            }
            let ok = match i {
                0 => t.mob.body.mob.motion.eye_water && !has(t, self.water_breathing),
                1 => self.burning(t) && !has(t, self.fire_resistance),
                2 => t.mob.body.mob.living.health.value < t.attribute("minecraft:max_health"),
                _ => target.as_ref().is_some_and(|tg| {
                    !has(t, self.swiftness) && t.distance_sq(tg.position) > 121.0
                }),
            };
            if ok {
                return Some(potion);
            }
        }
        None
    }

    // On fire, or its last damage (within two seconds,
    // `getLastDamageSource`) was fire's.
    fn burning(&self, t: &Turn) -> bool {
        t.mob.body.mob.living.fire_ticks > 0
            || t.mind.damage.is_some_and(|d| {
                t.mind.tick - d.tick <= 40 && self.fire.contains(&(d.source as i32))
            })
    }

    // ## Throwing

    /// `performRangedAttack` (not while drinking): the potion for the
    /// target, thrown from its eyes toward where the target is heading, and
    /// its sound.
    fn throw(&self, t: &mut Turn, target: &Seen) {
        if flag(t.data(), "drinking") {
            return;
        }
        // A sensed player's motion, effects and health (a mob's: none, none
        // and 20).
        let player = (target.kind() == RefKind::Player)
            .then(|| t.sensing.players.iter().find(|p| p.uuid == target.uuid()))
            .flatten();
        let [vx, _, vz] = player.map_or([0.0; 3], |p| p.velocity);
        let effects: Vec<u16> = player.map(|p| p.effects.clone()).unwrap_or_default();
        let health = player.map_or(20.0, |p| p.health);
        let has = |id: i32| effects.contains(&(id as u16));
        let xd = target.x() + vx - t.x();
        let yd = target.eye_y() - f(1.1) - t.y();
        let zd = target.z() + vz - t.z();
        let dist = (xd * xd + zd * zd).sqrt();
        let potion = if dist >= 8.0 && !has(self.slowness) {
            "minecraft:slowness"
        } else if health >= 8.0 && !has(self.poison) {
            "minecraft:poison"
        } else if dist <= 3.0 && !has(self.weakness) {
            if t.float() < f(0.25) {
                "minecraft:weakness"
            } else {
                "minecraft:harming"
            }
        } else {
            "minecraft:harming"
        };
        let roll = t.float();
        let pitch = f(f(0.8) + f(roll * f(0.4)));
        let facts = t.level.facts;
        let throw = Map::from_atoms([
            (
                "stack",
                self.potion_stack(facts, self.splash_potion, potion),
            ),
            (
                "from",
                Value::vec3([t.x(), t.eye_y() - 0.10000000149011612, t.z()]),
            ),
            ("direction", Value::vec3([xd, yd + dist * f(0.2), zd])),
            (
                "velocity",
                Value::Float(if dist <= 2.0 { 0.45 } else { 0.75 }),
            ),
            ("uncertainty", Value::Float(8.0)),
        ]);
        t.effect(Effect::ThrowPotion(Value::Map(throw)));
        t.effect(Effect::SoundAt {
            id: self.throw_sound,
            source: "hostile",
            at: t.pos(),
            volume: 1.0,
            pitch,
        });
    }
}

/// The drinking modifier (-0.25 movement speed) on or off.
fn modify(t: &mut Turn, on: bool) {
    let add = on.then_some((Number::Float(-0.25), 0));
    t.mob.body.mob.attributes.toggle(SPEED, DRINKING, add);
}

impl Hooks for Witch {
    fn perform(&self, t: &mut Turn, tag: Tag, target: &Seen, _power: f64) {
        if tag == THROW {
            self.throw(t, target);
        }
    }
}

impl Family for Witch {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Witch::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        vec![value(
            "witch_using_item",
            Value::bool(flag(&body.data, "drinking")),
            Value::bool(false),
        )]
    }

    /// `getDamageAfterMagicAbsorb`: magic it resists takes 15%.
    fn taken(&self, _body: &Body, hit: &Hit) -> Option<Hit> {
        self.resisted.contains(&(hit.source as i32)).then(|| {
            let mut hit = hit.clone();
            hit.amount = f(hit.amount * f(0.15));
            hit
        })
    }
}

impl Kind for Witch {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Witch"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        let idle =
            |priority, name: &'static str| Registration::new(priority, name, MOVE, Idle::new(name));
        Registered {
            goals: vec![
                idle(4, "LongDistancePatrolGoal"),
                idle(1, "ObtainRaidLeaderBannerGoal"),
                idle(3, "PathfindToRaidGoal"),
                idle(4, "RaiderMoveThroughVillageGoal"),
                idle(5, "RaiderCelebration"),
                Registration::new(1, "FloatGoal", JUMP, Float::new()),
                Registration::new(
                    2,
                    "RangedAttackGoal",
                    MOVE | LOOK,
                    RangedAttack::new(1.0, 60, 60, 10.0, THROW),
                ),
                Registration::new(
                    2,
                    "WaterAvoidingRandomStrollGoal",
                    MOVE,
                    RandomStroll::new(
                        1.0,
                        StrollOptions {
                            water_avoiding: true,
                            ..StrollOptions::default()
                        },
                    ),
                ),
                Registration::new(
                    3,
                    "LookAtPlayerGoal",
                    LOOK,
                    LookAtPlayer::new(8.0, 0.02, false, None),
                ),
                Registration::new(
                    3,
                    "RandomLookAroundGoal",
                    MOVE | LOOK,
                    RandomLookAround::new(),
                ),
            ],
            targets: vec![
                Registration::new(
                    1,
                    "HurtByTargetGoal",
                    TARGET,
                    HurtByTarget::new(false, Vec::new(), self.raiders.clone()),
                ),
                Registration::new(2, "NearestHealableRaiderTargetGoal", TARGET, HealRaiders),
                Registration::new(
                    3,
                    "NearestAttackableWitchTargetGoal",
                    TARGET,
                    NearestAttackableTarget::new(
                        TargetKind::Player,
                        None,
                        true,
                        TargetOptions::default(),
                    ),
                ),
            ],
        }
    }

    /// `PatrollingMonster.finalizeSpawn`: outside patrols, events and
    /// structures the level draws whether it leads a patrol, which a witch
    /// never does; then a mob's.
    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        if !matches!(reason.as_str(), "patrol" | "event" | "structure") {
            spawn::level_float(t);
        }
        spawn::mob(t, reason);
    }

    /// `aiStep` before its super: the raider heal cooldown, drinking, its
    /// particles.
    fn before_ai(&self, t: &mut Turn) {
        if !crate::mobs::living::mob::alive(&t.mob.body.mob) {
            return;
        }
        let cooldown = int(t.data(), "heal_cooldown") - 1;
        t.mob.body.data.set("heal_cooldown", Value::Int(cooldown));
        if flag(t.data(), "drinking") {
            self.drink(t);
        } else {
            self.maybe_drink(t);
        }
        if t.float() < f(7.5e-4) {
            t.effect(Effect::Event(15));
        }
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Witch::data_of()
    }
}

/// `NearestHealableRaiderTargetGoal` (`Witch.HealRaiders`): off its
/// cooldown it flips a coin each update; without a raid it finds no raider
/// to heal.
#[derive(Clone, Debug, PartialEq)]
pub struct HealRaiders;

impl Goal for HealRaiders {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if int(t.data(), "heal_cooldown") > 0 {
            return false;
        }
        t.boolean();
        false
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Witch.HealRaiders"
    }
}
