//! Hoglins (`Valimc.AI.Mobs.Hoglin` and `Valimc.AI.Brains.Hoglin`,
//! vanilla's `Hoglin` and `HoglinAi`):
//!
//! - **The mob**: an ageable mob, a baby one time in five (smaller, weaker,
//!   quicker to strike, growing up a tick at a time), immune to
//!   zombification or not, its time in the overworld, whether piglins may
//!   hunt it. Its hit (`doHurtTarget`): the attack event and sound, the
//!   brain's reaction, then `HoglinBase.hurtAndThrowTarget` (an adult hits
//!   for half its attack damage plus up to as much again and throws what it
//!   hits). Zombification outside the Nether and breeding wait in the
//!   Elixir, so they do here.
//! - **Core**: the look and walk sinks.
//! - **Idle**: pacified by a warped fungus (or a portal, a respawn anchor)
//!   near it; walk away from it; attack the nearest player it may attack;
//!   an adult walks away from the adult piglins it sees; looks at what is
//!   near now and then; a baby follows an adult; a random stroll, walking to
//!   what it looks at, or nothing (one at random).
//! - **Fight**: pacified as in idle; walk to its target; an adult's melee
//!   every 40 ticks, a baby's every 15; drop an invalid target.
//! - **Retreat**: walk away from what it avoids, idle movement and looks;
//!   an adult stops once piglins no longer outnumber the hoglins it sees.
//!
//! Hurt, it gives up its peace; a baby flees the attacker, an adult turns on
//! it with the adult hoglins it sees. Its hit on a piglin while piglins
//! outnumber them would send them all fleeing, else join them in the
//! attack: those changes of others ride its think's effects, which the
//! Elixir leaves unapplied.

use crate::mobs::ai::brain::behavior::{self as b, Behavior};
use crate::mobs::ai::brain::behaviors::{self as bs, Pick, Speed, Test};
use crate::mobs::ai::brain::fight::{self, Away};
use crate::mobs::ai::brain::sensors;
use crate::mobs::ai::brain::{
    Activity, Brain, BrainFamily, Cond, Conds, Mem, MemValue, Package, Reaction, Sensor,
};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{self, f};
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::ai::{think, Opaque};
use crate::mobs::combat::Family;
use crate::mobs::facts::MobFacts;
use crate::mobs::facts::Slot;
use crate::mobs::kinds::{Kind, Registered};
use crate::mobs::model::{Body, FamilyData};
use crate::mobs::monsters::{entity, fields, flag, int, item, states, value};
use crate::mobs::random::LegacyRandom;
use crate::mobs::sensing::{Entity, Kind as RefKind, Ref, Uuid};
use crate::mobs::term::{Atom, Map, Value, NIL};
use std::any::Any;

pub const HOGLIN: &str = "minecraft:hoglin";
const ATTACK: &str = "minecraft:attack_damage";

// Its tests, finder and sensor (tags).
const ADULT: u32 = 1;
const BREEDING: u32 = 2;
const STOP_FLEEING: u32 = 3;
const FIND_TARGET: u32 = 1;
const SENSOR: u32 = 1;

/// The hoglin family.
pub struct Hoglin {
    types: [&'static str; 1],
    hoglin: u16,
    piglin: u16,
    netherite: [i32; 4],
    repellents: Vec<u16>,
    attack_sound: i32,
    retreat: i32,
    angry: i32,
    ambient: i32,
}

/// What a hoglin's reaction asks of another (`{:brain, uuid, fun}`).
#[derive(Clone, Debug, PartialEq)]
enum Change {
    /// `attack_if_closer/2`.
    AttackIfCloser(Ref),
    /// `retreat_from_nearest/2`.
    RetreatFromNearest(Ref),
}

impl Hoglin {
    pub fn new(facts: &MobFacts) -> Result<Hoglin, String> {
        let mut repellents = Vec::new();
        for id in facts
            .tags
            .get("minecraft:block", "minecraft:hoglin_repellents")
            .unwrap_or_default()
        {
            let block = facts
                .blocks
                .block(*id as u16)
                .ok_or("bad repellent block")?;
            repellents.extend(states(facts, &block.name)?);
        }
        repellents.sort_unstable();
        Ok(Hoglin {
            types: [HOGLIN],
            hoglin: entity(facts, HOGLIN)?,
            piglin: entity(facts, "minecraft:piglin")?,
            netherite: [
                item(facts, "minecraft:netherite_helmet")?,
                item(facts, "minecraft:netherite_chestplate")?,
                item(facts, "minecraft:netherite_leggings")?,
                item(facts, "minecraft:netherite_boots")?,
            ],
            repellents,
            attack_sound: super::sound(facts, "minecraft:entity.hoglin.attack")?,
            retreat: super::sound(facts, "minecraft:entity.hoglin.retreat")?,
            angry: super::sound(facts, "minecraft:entity.hoglin.angry")?,
            ambient: super::sound(facts, "minecraft:entity.hoglin.ambient")?,
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[
            ("age", Value::Int(0)),
            ("immune", Value::bool(false)),
            ("time_in_overworld", Value::Int(0)),
            ("cannot_be_hunted", Value::bool(false)),
        ])
    }

    fn idle_movement(gate: LegacyRandom) -> Box<dyn Behavior> {
        b::run_one(
            vec![
                (bs::stroll(0.4, 10, 7, Test::Always), 2),
                (bs::walk_to_look_target(Test::Always, Speed::of(0.4), 3), 2),
                (b::do_nothing(30, 60), 1),
            ],
            gate,
            Conds::NONE,
        )
    }

    // ## Its state

    fn type_of(&self, e: &Seen) -> Option<u16> {
        e.type_id
    }

    /// `piglinsOutnumberHoglins`: more adult piglins seen than adult
    /// hoglins (itself among them).
    fn piglins_outnumber(t: &Turn) -> bool {
        adult(t)
            && t.mem_int(Mem::VisibleAdultPiglinCount).unwrap_or(0)
                > t.mem_int(Mem::VisibleAdultHoglinCount).unwrap_or(0) + 1
    }

    // ## Reactions

    /// `HoglinAi.wasHurtBy`.
    fn hurt_by(&self, t: &mut Turn, attacker: &Seen) {
        t.forget(Mem::Pacified);
        t.forget(Mem::BreedTarget);
        if adult(t) {
            self.retaliate(t, attacker);
        } else {
            self.retreat_from_nearest(t, attacker.reference);
        }
    }

    // `maybeRetaliate`.
    fn retaliate(&self, t: &mut Turn, attacker: &Seen) {
        if t.active(Activity::Avoid) && self.type_of(attacker) == Some(self.piglin) {
            return;
        }
        if self.type_of(attacker) == Some(self.hoglin) {
            return;
        }
        if fight::much_farther(t, attacker, 4.0) {
            return;
        }
        if sensors::attackable(t, &attacker.reference) {
            set_attack_target(t, attacker.reference);
            broadcast(t, Change::AttackIfCloser(attacker.reference));
        }
    }

    // `attack_if_closer/2`.
    fn attack_if_closer(&self, t: &mut Turn, r: Ref) {
        let Some(new) = t.entity(Some(&r)) else {
            return;
        };
        let current = t.remembered(Mem::AttackTarget);
        if t.has(Mem::Pacified) {
            return;
        }
        let nearest = nearest(t, current, new);
        set_attack_target(t, nearest.reference);
    }

    // `retreatFromNearestTarget`.
    fn retreat_from_nearest(&self, t: &mut Turn, r: Ref) {
        let Some(target) = t.entity(Some(&r)) else {
            return;
        };
        let mut nearest_one = target;
        for m in [Mem::AvoidTarget, Mem::AttackTarget] {
            let e = t.remembered(m);
            nearest_one = nearest(t, e, nearest_one);
        }
        set_avoid_target(t, nearest_one.reference);
    }

    /// `HoglinAi.onHitTarget`.
    fn on_hit(&self, t: &mut Turn, target: &Seen) {
        if !adult(t) {
            return;
        }
        if self.type_of(target) == Some(self.piglin) && Hoglin::piglins_outnumber(t) {
            set_avoid_target(t, target.reference);
            broadcast(t, Change::RetreatFromNearest(target.reference));
        } else {
            broadcast(t, Change::AttackIfCloser(target.reference));
        }
    }

    /// `HoglinAi.getSoundForCurrentActivity`.
    fn activity_sound(&self, t: &Turn) -> Option<i32> {
        match t.activity()? {
            Activity::Avoid => Some(self.retreat),
            Activity::Fight => Some(self.angry),
            _ => Some(if t.has(Mem::NearestRepellent) {
                self.retreat
            } else {
                self.ambient
            }),
        }
    }

    // `HoglinBase.throwTarget`: its attack knockback less the target's
    // resistance (a tenth for each netherite piece a player wears), away
    // from it and turned a whole number of radians, and up.
    fn throw(&self, t: &mut Turn, target: &Seen) -> Option<[f64; 3]> {
        let power = t.attribute("minecraft:attack_knockback") - self.resistance(t, target);
        if power <= 0.0 {
            return None;
        }
        let (xd, zd) = (target.x() - t.x(), target.z() - t.z());
        let n = t.level_int(21);
        let r = t.level_float();
        let g = t.level_float();
        let angle = f((n - 10) as f64);
        let horizontal = power * f(f(r * 0.5) + f(0.2));
        let length = (xd * xd + zd * zd).sqrt();
        let (x, z) = if length < 1.0e-5 {
            (0.0, 0.0)
        } else {
            (xd / length * horizontal, zd / length * horizontal)
        };
        let (cos, sin) = (fmath::cos(angle), fmath::sin(angle));
        Some([x * cos + z * sin, power * g * 0.5, z * cos - x * sin])
    }

    fn resistance(&self, t: &Turn, target: &Seen) -> f64 {
        match t.sensing.entity(&target.reference) {
            Some(Entity::Player(p)) => {
                let worn = [Slot::Head, Slot::Chest, Slot::Legs, Slot::Feet]
                    .into_iter()
                    .filter(|&s| p.equipped(s).is_some_and(|i| self.netherite.contains(&i)))
                    .count();
                0.1 * worn as f64
            }
            _ => 0.0,
        }
    }
}

/// `isAdult`.
fn adult(t: &Turn) -> bool {
    t.data().age().unwrap_or(0) >= 0
}

/// `BehaviorUtils.getNearestTarget`: what it has if nearer, else the new
/// one.
fn nearest(t: &Turn, current: Option<Seen>, new: Seen) -> Seen {
    match current {
        Some(c) if bs::distance_sq(t, &c) < bs::distance_sq(t, &new) => c,
        _ => new,
    }
}

// `setAttackTarget`: for ten seconds.
fn set_attack_target(t: &mut Turn, r: Ref) {
    t.forget(Mem::CantReachWalkTargetSince);
    t.forget(Mem::BreedTarget);
    t.remember_for(Mem::AttackTarget, MemValue::Ref(r), 200);
}

// `setAvoidTarget`: for 5 to 20 seconds (the level's random).
fn set_avoid_target(t: &mut Turn, r: Ref) {
    let n = t.level_int(301) as i64;
    t.forget(Mem::AttackTarget);
    t.forget(Mem::WalkTarget);
    t.remember_for(Mem::AvoidTarget, MemValue::Ref(r), 100 + n);
}

// `broadcastAttackTarget` / `broadcastRetreat`: each adult hoglin it sees.
fn broadcast(t: &mut Turn, change: Change) {
    for r in t.mem_refs(Mem::NearestVisibleAdultHoglins) {
        if r.kind == RefKind::Mob {
            t.effect(Effect::Brain {
                mob: r.uuid,
                change: Box::new(change.clone()),
            });
        }
    }
}

/// `setBaby` (`ageBoundaryReached`): its age and a baby's attack damage.
fn set_baby(t: &mut Turn, baby: bool) {
    t.mob.body.data.set_age(if baby { -24_000 } else { 0 });
    crate::mobs::ai::spawn::set_base(&mut t.mob.body.mob, ATTACK, if baby { 0.5 } else { 6.0 });
}

impl BrainFamily for Hoglin {
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
        let [avoid_gate, idle_gate] = super::gates(uuid, [0x6B1D, 0x2E59]);
        use Cond::Present;
        let core = vec![bs::look_sink(45, 90), bs::move_sink(150, 250)];
        let idle = vec![
            bs::become_passive(Mem::NearestRepellent, 200),
            b::inert("AnimalMakeLove"),
            fight::walk_away(Mem::NearestRepellent, Away::Pos, 1.0, 8, true),
            fight::start_attacking(Test::Always, FIND_TARGET),
            bs::trigger_if(
                Test::Family(ADULT),
                fight::walk_away_trigger(
                    Mem::NearestVisibleAdultPiglin,
                    Away::Entity,
                    0.4,
                    8,
                    false,
                ),
            ),
            bs::look_sometimes(Pick::Any, 8.0, (30, 60)),
            bs::baby_follow_adult(5, 16, Speed::of(0.6)),
            Hoglin::idle_movement(idle_gate),
        ];
        let fight_list = vec![
            bs::become_passive(Mem::NearestRepellent, 200),
            b::inert("AnimalMakeLove"),
            fight::walk_to_target(Speed::of(1.0)),
            fight::melee(Test::Family(ADULT), 40),
            fight::melee(Test::Not(ADULT), 15),
            fight::stop_if_invalid(None, true, None),
            fight::erase_if(Test::Family(BREEDING), Mem::AttackTarget),
        ];
        let avoid = vec![
            fight::walk_away(Mem::AvoidTarget, Away::Entity, 1.3, 15, false),
            Hoglin::idle_movement(avoid_gate),
            bs::look_sometimes(Pick::Any, 8.0, (30, 60)),
            fight::erase_if(Test::Family(STOP_FLEEING), Mem::AvoidTarget),
        ];
        Brain::new(
            &[
                (Sensor::NearestLiving, 20),
                (Sensor::Players, 20),
                (Sensor::NearestAdult, 20),
                (Sensor::Family(SENSOR), 20),
            ],
            vec![
                Package::from(Activity::Core, 0, core, Conds::NONE, &[]),
                Package::from(Activity::Idle, 10, idle, Conds::NONE, &[]),
                Package::from(
                    Activity::Fight,
                    10,
                    fight_list,
                    Conds::new(&[(Mem::AttackTarget, Present)]),
                    &[Mem::AttackTarget],
                ),
                Package::from(
                    Activity::Avoid,
                    10,
                    avoid,
                    Conds::new(&[(Mem::AvoidTarget, Present)]),
                    &[Mem::AvoidTarget],
                ),
            ],
            random,
            None,
            &[],
        )
    }

    /// `HoglinAi.updateActivity`: fight, retreat or idle, its activity
    /// sound when it changed, and its aggression.
    fn update_activity(&self, t: &mut Turn) {
        let old = t.activity();
        t.first_valid(&[Activity::Fight, Activity::Avoid, Activity::Idle]);
        if t.activity() != old {
            if let Some(sound) = self.activity_sound(t) {
                think::make_sound(t, sound);
            }
        }
        let target = t.mem_ref(Mem::AttackTarget);
        t.set_aggressive(target.is_some());
        t.put_target(target);
    }

    fn ambient_sound(&self, t: &mut Turn) -> Option<i32> {
        self.activity_sound(t)
    }

    fn reacts(&self) -> bool {
        true
    }

    fn react(&self, t: &mut Turn, event: Reaction) {
        if let Reaction::HurtBy(r) = event {
            if let Some(attacker) = t.entity(Some(&r)) {
                self.hurt_by(t, &attacker);
            }
        }
    }

    fn brain_change(&self, t: &mut Turn, change: &dyn Opaque) {
        match change.as_any().downcast_ref::<Change>() {
            Some(Change::AttackIfCloser(r)) => self.attack_if_closer(t, *r),
            Some(Change::RetreatFromNearest(r)) => self.retreat_from_nearest(t, *r),
            None => {}
        }
    }

    /// `HoglinSpecificSensor`: the nearest repellent eight blocks around and
    /// four up and down, and of the adult piglins and hoglins it sees, the
    /// nearest piglin, the piglins' count and the hoglins.
    fn scan(&self, t: &mut Turn, _tag: u32) {
        let repellent = sensors::repellent(t, &self.repellents);
        t.remember_opt(Mem::NearestRepellent, repellent.map(MemValue::Pos));
        let visible = sensors::visible_all(t);
        let (mut piglins, mut hoglins) = (Vec::new(), Vec::new());
        for r in visible {
            if let Some(Entity::Mob(m)) = t.sensing.entity(&r) {
                if !m.baby && m.type_id == self.piglin {
                    piglins.push(r);
                } else if !m.baby && m.type_id == self.hoglin {
                    hoglins.push(r);
                }
            }
        }
        t.remember_opt(
            Mem::NearestVisibleAdultPiglin,
            piglins.first().map(|r| MemValue::Ref(*r)),
        );
        let (np, nh) = (piglins.len() as i64, hoglins.len() as i64);
        t.remember(Mem::NearestVisibleAdultHoglins, MemValue::Refs(hoglins));
        t.remember(Mem::VisibleAdultPiglinCount, MemValue::Int(np));
        t.remember(Mem::VisibleAdultHoglinCount, MemValue::Int(nh));
    }

    fn test(&self, t: &mut Turn, tag: u32) -> bool {
        match tag {
            ADULT => adult(t),
            BREEDING => t.has(Mem::BreedTarget),
            STOP_FLEEING => adult(t) && !Hoglin::piglins_outnumber(t),
            _ => false,
        }
    }

    /// `findNearestValidAttackTarget`: the nearest player it may attack,
    /// unless pacified or breeding.
    fn find(&self, t: &mut Turn, _tag: u32) -> Option<Seen> {
        if t.has(Mem::Pacified) || t.has(Mem::BreedTarget) {
            None
        } else {
            t.remembered(Mem::NearestVisibleAttackablePlayer)
        }
    }

    fn young(&self, t: &Turn) -> bool {
        !adult(t)
    }
}

impl Hooks for Hoglin {
    fn brain(&self) -> Option<&dyn BrainFamily> {
        Some(self)
    }

    fn voice(&self, _type_id: u16, data: &FamilyData) -> f32 {
        if data.age().unwrap_or(0) < 0 {
            1.5
        } else {
            1.0
        }
    }

    /// `Hoglin.doHurtTarget`: the attack event (4) and sound, the brain's
    /// reaction, then the hit's amount and an adult's throw from the level's
    /// random, for the owner to land.
    fn hit(&self, t: &mut Turn, target: &Seen) {
        t.effect(Effect::Event(4));
        think::make_sound(t, self.attack_sound);
        self.on_hit(t, target);
        let adult = adult(t);
        let damage = f(t.attribute(ATTACK));
        let amount = if adult && damage.trunc() as i32 > 0 {
            let n = t.level_int(damage.trunc() as i32);
            f(f(damage / 2.0) + n as f64)
        } else {
            damage
        };
        let push = if adult { self.throw(t, target) } else { None };
        let extras = Map::from_atoms([
            ("amount", Value::Float(amount)),
            (
                "extra_knockback",
                Value::tuple([
                    Value::Float(0.0),
                    Value::tuple([Value::Float(0.0), Value::Float(0.0)]),
                ]),
            ),
            ("push", push.map_or(NIL, Value::vec3)),
        ]);
        t.effect(Effect::AttackExtra(target.reference, Value::Map(extras)));
    }
}

impl Family for Hoglin {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Hoglin::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        vec![
            value(
                "ageable_baby",
                Value::bool(int(&body.data, "age") < 0),
                Value::bool(false),
            ),
            value(
                "hoglin_immune",
                Value::bool(flag(&body.data, "immune")),
                Value::bool(false),
            ),
        ]
    }

    fn dimensions(&self, body: &Body) -> Option<[f32; 3]> {
        (int(&body.data, "age") < 0).then_some([0.75, 0.85, 0.625])
    }

    fn voice(&self, body: &Body) -> f32 {
        Hooks::voice(self, self.hoglin, &body.data)
    }

    fn experience(&self, body: &Body) -> Option<i32> {
        Some(if int(&body.data, "age") < 0 { 3 } else { 5 })
    }
}

impl Kind for Hoglin {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Hoglin"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    /// A brain mob registers no goals.
    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered::default()
    }

    fn leashable(&self) -> bool {
        true
    }

    fn young(&self, body: &Body) -> Option<bool> {
        Some(int(&body.data, "age") < 0)
    }

    /// `Hoglin.finalizeSpawn`: a baby one time in five (the level's random),
    /// then a mob's own spawn.
    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        if crate::mobs::ai::spawn::level_float(t) < f(0.2) {
            set_baby(t, true);
        }
        crate::mobs::ai::spawn::mob(t, reason);
    }

    /// `AgeableMob.aiStep`: a baby grows up a tick at a time.
    fn after_ai(&self, t: &mut Turn) {
        let age = t.data().age().unwrap_or(0);
        if age < 0 {
            t.mob.body.data.set_age(age + 1);
            if age + 1 == 0 {
                set_baby(t, false);
            }
        }
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Hoglin::data_of()
    }
}
