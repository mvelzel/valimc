//! Guardians and elder guardians (`Valimc.AI.Mobs.Guardian`, vanilla's
//! `Guardian` and `ElderGuardian`).
//!
//! A guardian swims to random spots in water (now and then, or at once
//! after a hurt or a beam), steered by its own move control
//! (`GuardianMoveControl`: easing its speed, turning at most 90 degrees a
//! tick, bobbing as it goes and looking a little ahead); it travels as a
//! guardian, sinking while still with no target, and flops about on land.
//!
//! It targets players, squid and axolotls more than three blocks away and
//! beams one (`Attack`): holding still and looking at it, after ten ticks it
//! shows the beam (its attack target data, entity event 21) and after its
//! attack duration (80 ticks, an elder's 60) it hits with magic and its
//! melee attack, then lets go and swims off. A living attacker that hit it
//! while it was still takes two thorns damage on its next tick (`thorns`,
//! its own state).
//!
//! An elder never despawns, strolls a fifth as often, takes a home of 16
//! blocks where it first ticks and every minute curses the players within
//! 50 blocks (`Effect::ElderCurse`).

use super::{entity, fields, flag, int, value};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{self, f, lerp, rotlerp};
use crate::mobs::ai::goal::{Goal, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::target::TargetOptions;
use crate::mobs::ai::goals::{
    LookAtPlayer, MobTypes, MoveTowardsRestriction, NearestAttackableTarget, RandomLookAround,
    RandomStroll, TargetKind, TargetTest,
};
use crate::mobs::ai::hooks::{Hooks, Tag};
use crate::mobs::ai::navigation::{self, NavKind};
use crate::mobs::ai::turn::{Eyes, Seen, Turn};
use crate::mobs::ai::{spawn, Extra};
use crate::mobs::combat::{Event, Family, Hit, SoundKind, SoundRef};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Emission, Kind, KindMotion, NavSpec, Registered, Registration};
use crate::mobs::level::{Difficulty, FluidKind, Level};
use crate::mobs::model::{Body, FamilyData, Home, Impulse, MotionSet, Travel, TravelKind};
use crate::mobs::sensing::{self, Entity, Kind as RefKind, Ref};
use crate::mobs::term::{Atom, Value};
use std::collections::HashSet;

pub const GUARDIAN: &str = "minecraft:guardian";
pub const ELDER_GUARDIAN: &str = "minecraft:elder_guardian";

// The family's own target selector: more than three blocks away.
const FAR: Tag = 1;

/// The thorns a guardian owes the attackers that hit it while it was still
/// (`Mind.own`'s `thorns`), dealt on its next tick.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GuardianOwn {
    pub thorns: Vec<Ref>,
}

/// The guardian family.
pub struct Guardian {
    types: [&'static str; 2],
    guardian: u16,
    elder: u16,
    prey: Vec<u16>,
    /// Names of the living entity types (a thorns-taking attacker).
    living: HashSet<String>,
    /// Damage types guardians' thorns never answer.
    no_thorns: Vec<u16>,
    thorns: Option<u16>,
}

impl Guardian {
    pub fn new(facts: &MobFacts) -> Result<Guardian, String> {
        let no_thorns = facts
            .tags
            .get("minecraft:damage_type", "minecraft:avoids_guardian_thorns")
            .map(|ids| ids.iter().map(|&i| i as u16).collect())
            .unwrap_or_default();
        Ok(Guardian {
            types: [GUARDIAN, ELDER_GUARDIAN],
            guardian: entity(facts, GUARDIAN)?,
            elder: entity(facts, ELDER_GUARDIAN)?,
            prey: vec![
                entity(facts, "minecraft:squid")?,
                entity(facts, "minecraft:glow_squid")?,
                entity(facts, "minecraft:axolotl")?,
            ],
            living: facts
                .entities
                .types
                .iter()
                .filter(|t| t.living())
                .map(|t| t.name.clone())
                .collect(),
            no_thorns,
            thorns: facts.damage_types.id("minecraft:thorns"),
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[("moving", Value::bool(false)), ("beam", Value::Int(0))])
    }

    /// Its sound `which` in water or on land.
    fn sound_name(type_name: &str, which: &str, in_water: bool) -> String {
        let name = type_name.strip_prefix("minecraft:").unwrap_or(type_name);
        if in_water {
            format!("minecraft:entity.{name}.{which}")
        } else {
            format!("minecraft:entity.{name}.{which}_land")
        }
    }

    /// The living entity that hit it directly, unless it was moving or the
    /// damage avoids its thorns.
    fn thorns_of(&self, data: &FamilyData, hit: &Hit) -> Option<Ref> {
        if flag(data, "moving") {
            return None;
        }
        let direct = hit.direct.as_ref()?;
        let living = direct.player || self.living.contains(&direct.entity_type);
        if living && !self.no_thorns.contains(&hit.source) && Some(hit.source) != self.thorns {
            Some(Ref {
                kind: if direct.player {
                    RefKind::Player
                } else {
                    RefKind::Mob
                },
                uuid: direct.uuid,
            })
        } else {
            None
        }
    }

    // ## The move control

    /// `GuardianMoveControl.tick`: toward the wanted position while it
    /// navigates (turning, easing its speed, a bob along its heading and up
    /// toward the target, its look led an eighth of the way ahead), else
    /// still. It travels as a guardian, sinking while still with no target.
    fn move_control(&self, t: &mut Turn) {
        match t.mob.body.mob.motion.control {
            crate::mobs::model::Control::MoveTo { target, speed } if !t.mind.navigation.done() => {
                steer(t, target, speed)
            }
            _ => still(t),
        }
        let sink = !flag(t.data(), "moving") && t.mind.target.is_none();
        t.mob.body.mob.motion.travel = Some(Travel {
            kind: TravelKind::Guardian,
            sink,
        });
    }
}

fn still(t: &mut Turn) {
    t.mob.body.data.set("moving", Value::bool(false));
    set(t, 0.0, [0.0; 3]);
}

fn steer(t: &mut Turn, [wx, wy, wz]: [f64; 3], modifier: f64) {
    let (dx, dy, dz) = (wx - t.x(), wy - t.y(), wz - t.z());
    let length = (dx * dx + dy * dy + dz * dz).sqrt();
    let (xd, yd, zd) = (dx / length, dy / length, dz / length);
    let yaw = rotlerp(t.yaw(), fmath::yaw(dx, dz), 90.0);
    t.mob.body.yaw = yaw;
    t.mind.body_yaw = yaw;
    let attribute = t.attribute("minecraft:movement_speed");
    let target = f(modifier * attribute);
    let speed = lerp(f(0.125), t.speed(), target);
    // `Math.sin` and `cos` as vanilla's.
    let at = (t.mind.tick + t.id as i64) as f64;
    let push = fmath::java_sin_cos(at * 0.5).0 * 0.05;
    let radians = f(std::f64::consts::PI / 180.0);
    let (s, c) = fmath::java_sin_cos(f(yaw * radians));
    let y_push = fmath::java_sin_cos(at * 0.75).0 * 0.05;
    let impulse = [
        push * c,
        y_push * (s + c) * 0.25 + speed * yd * 0.1,
        push * s,
    ];
    let new = [t.x() + xd * 2.0, t.eye_y() + yd / length, t.z() + zd * 2.0];
    let old = match t.mind.look {
        Some(l) if l.cooldown > 0 => [l.x, l.y, l.z],
        _ => new,
    };
    // `Mth.lerp(0.125, old, new)` in doubles.
    let look = std::array::from_fn(|a| old[a] + 0.125 * (new[a] - old[a]));
    t.look_at(look, 10.0, 40.0);
    t.mob.body.data.set("moving", Value::bool(true));
    set(t, speed, impulse);
}

// `setSpeed` (no lift) and the move control's push.
fn set(t: &mut Turn, speed: f64, impulse: [f64; 3]) {
    let motion = &mut t.mob.body.mob.motion;
    motion.set = Some(MotionSet::Speed { speed, lift: false });
    motion.impulse = Impulse::One(impulse);
}

fn own<'a>(t: &'a Turn) -> Option<&'a GuardianOwn> {
    t.mind.own.family::<GuardianOwn>()
}

impl Hooks for Guardian {
    /// `getWalkTargetValue`: water above all, then darkness.
    fn walk_value(&self, t: &mut Turn, pos: [i32; 3]) -> Option<f64> {
        let cost = f(t.level.light(pos) as f64 - 0.5);
        Some(if t.level.fluid(pos) == FluidKind::Water {
            f(10.0 + cost)
        } else {
            -cost
        })
    }

    /// `GuardianAttackSelector`: more than three blocks away.
    fn target(&self, _level: &Level, eyes: &Eyes, tag: Tag, target: Entity<'_, Extra>) -> bool {
        tag == FAR && fmath::distance_sq(eyes.position, target.position()) > 9.0
    }
}

impl Family for Guardian {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Guardian::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        vec![
            value(
                "guardian_moving",
                Value::bool(flag(&body.data, "moving")),
                Value::bool(false),
            ),
            value(
                "guardian_attack_target",
                Value::Int(int(&body.data, "beam")),
                Value::Int(0),
            ),
        ]
    }

    fn sound(&self, body: &Body, which: SoundKind) -> Option<SoundRef> {
        let which = match which {
            SoundKind::Hurt => "hurt",
            SoundKind::Death => "death",
        };
        Some(SoundRef::Name(Guardian::sound_name(
            &body.entity_type,
            which,
            body.mob.motion.water > 0.0,
        )))
    }

    /// `Guardian.hurtServer`: a living attacker that hit it while still
    /// takes thorns (on its next tick), and its stroll goes at once.
    fn hurt(&self, body: &mut Body, hit: &Hit, _events: &mut Vec<Event>) {
        let thorns = self.thorns_of(&body.data, hit);
        let Some(state) = body.mob.ai.as_mut().and_then(|m| m.state.as_mut()) else {
            return;
        };
        state.goals.change::<RandomStroll>(|g| g.trigger());
        if let Some(r) = thorns {
            let mut o = state
                .own
                .family::<GuardianOwn>()
                .cloned()
                .unwrap_or_default();
            o.thorns.push(r);
            state.own.family = Some(Box::new(o));
        }
    }

    /// Its retaliation and stroll also follow a refused hurt.
    fn repelled(&self, body: &mut Body, hit: &Hit) {
        Family::hurt(self, body, hit, &mut Vec::new());
    }
}

impl Kind for Guardian {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Guardian"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, type_id: u16) -> Registered {
        let elder = type_id == self.elder;
        Registered {
            goals: vec![
                Registration::new(
                    4,
                    "GuardianAttackGoal",
                    MOVE | LOOK,
                    Attack { elder, time: 0 },
                ),
                Registration::new(
                    5,
                    "MoveTowardsRestrictionGoal",
                    MOVE | LOOK,
                    MoveTowardsRestriction::new(1.0),
                ),
                Registration::new(
                    7,
                    "RandomStrollGoal",
                    MOVE | LOOK,
                    RandomStroll::new(
                        1.0,
                        StrollOptions {
                            interval: if elder { 400 } else { 80 },
                            ..StrollOptions::default()
                        },
                    ),
                ),
                Registration::new(
                    8,
                    "LookAtPlayerGoal",
                    LOOK,
                    LookAtPlayer::new(8.0, 0.02, false, None),
                ),
                Registration::new(
                    8,
                    "LookAtPlayerGoal",
                    LOOK,
                    LookAtPlayer::new(
                        12.0,
                        0.01,
                        false,
                        Some(MobTypes::Types(vec![self.guardian, self.elder])),
                    ),
                ),
                Registration::new(
                    9,
                    "RandomLookAroundGoal",
                    MOVE | LOOK,
                    RandomLookAround::new(),
                ),
            ],
            targets: vec![Registration::new(
                1,
                "NearestAttackableTargetGoal",
                TARGET,
                NearestAttackableTarget::new(
                    TargetKind::Living,
                    Some(MobTypes::Types(self.prey.clone())),
                    true,
                    TargetOptions {
                        selector: Some(TargetTest::Family(FAR)),
                        ..TargetOptions::default()
                    },
                ),
            )],
        }
    }

    fn navigation(&self, _type_id: u16) -> NavSpec {
        NavSpec {
            kind: NavKind::Water,
            ..NavSpec::default()
        }
    }

    /// Its travel when its AI does not choose one (dead, `NoAI`): no target.
    fn kernel_motion(&self) -> KindMotion {
        KindMotion {
            emission: Emission::Events,
            travel: (TravelKind::Guardian, true),
            ..KindMotion::default()
        }
    }

    /// `finalizeSpawn`: an elder guardian never despawns.
    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        if t.type_id == self.elder {
            t.mob.body.mob.persistent = true;
        }
        spawn::mob(t, reason);
    }

    fn ambient_sound(&self, t: &mut Turn) -> Option<i32> {
        let name = Guardian::sound_name(&t.mob.body.entity_type, "ambient", t.in_water());
        t.level.facts.sounds.id(&name)
    }

    /// The thorns it owes the attackers that hit it still.
    fn tick_start(&self, t: &mut Turn) {
        let owed = match own(t) {
            Some(o) if !o.thorns.is_empty() => o.thorns.clone(),
            _ => return,
        };
        t.mind.own.family = Some(Box::new(GuardianOwn { thorns: Vec::new() }));
        for target in owed {
            t.effect(Effect::Hurt {
                target,
                kind: Value::atom("thorns"),
                amount: 2.0,
                actions: Value::List(Vec::new()),
            });
        }
    }

    /// `Guardian.aiStep` before its super: full air in water; on land, a
    /// flop up with a random sideways push and a random facing; while
    /// beaming, its body faces where its head looks.
    fn before_ai(&self, t: &mut Turn) {
        if t.in_water() {
            t.mob.body.mob.living.air_supply = 300;
        } else if t.on_ground() {
            let a = t.float();
            let b = t.float();
            let side = |v: f64| f(f(f(v * 2.0) - 1.0) * f(0.4));
            let [vx, vy, vz] = t.velocity();
            let r = t.float();
            t.mob.body.velocity = [vx + side(a), vy + 0.5, vz + side(b)];
            t.mob.body.yaw = f(r * 360.0);
            t.mob.body.on_ground = false;
        }
        if int(t.data(), "beam") != 0 {
            t.mob.body.yaw = t.head();
        }
    }

    /// `ElderGuardian.customServerAiStep`: every 1200 ticks (by its tick and
    /// id) its curse, and a home where it first ticks.
    fn custom_step(&self, t: &mut Turn) {
        if t.type_id != self.elder {
            return;
        }
        if (t.mind.tick + t.id as i64) % 1200 == 0 {
            let at = t.pos();
            t.effect(Effect::ElderCurse(at));
        }
        if t.mob.body.mob.home.is_none() {
            t.mob.body.mob.home = Some(Home {
                center: t.block(),
                radius: 16,
            });
        }
    }

    fn move_control(&self, t: &mut Turn) {
        Guardian::move_control(self, t);
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Guardian::data_of()
    }
}

// ## The beam

/// `GuardianAttackGoal` (`Guardian.Attack`), updated every tick: it holds
/// still and looks at its target while it sees it (an elder's however
/// close, another's while more than three blocks away); ten ticks in it
/// shows the beam, after its attack duration it hits and lets go. Stopping
/// clears the beam and the target and sends it strolling.
#[derive(Clone, Debug, PartialEq)]
pub struct Attack {
    elder: bool,
    time: i64,
}

fn look(t: &mut Turn, target: &Seen) {
    t.look_at([target.x(), target.eye_y(), target.z()], 90.0, 90.0);
}

fn beam(t: &mut Turn, id: i32) {
    t.mob.body.data.set("beam", Value::Int(id as i64));
}

impl Attack {
    fn attack(&self, t: &mut Turn, target: &Seen, time: i64) {
        if time == 0 {
            beam(t, target.id);
            t.effect(Effect::Event(21));
            return;
        }
        if time >= if self.elder { 60 } else { 80 } {
            let hard = if t.level.difficulty == Difficulty::Hard {
                2.0
            } else {
                0.0
            };
            let magic = 1.0 + hard + if self.elder { 2.0 } else { 0.0 };
            t.effect(Effect::Hurt {
                target: target.reference,
                kind: Value::atom("indirect_magic"),
                amount: magic,
                actions: Value::List(Vec::new()),
            });
            t.effect(Effect::Attack(target.reference));
            t.set_target(None);
        }
    }
}

impl Goal for Attack {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        t.target().is_some_and(|e| e.alive)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        match t.target() {
            Some(e) if e.alive => self.elder || t.distance_sq(e.position) > 9.0,
            _ => false,
        }
    }

    fn start(&mut self, t: &mut Turn) {
        navigation::stop(t);
        if let Some(target) = t.target() {
            look(t, &target);
        }
        self.time = -10;
    }

    fn stop(&mut self, t: &mut Turn) {
        beam(t, 0);
        t.set_target(None);
        t.mind.goals.change::<RandomStroll>(|g| g.trigger());
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        let Some(target) = t.target() else { return };
        navigation::stop(t);
        look(t, &target);
        let seen = {
            let (level, sensing, eyes) = t.split();
            sensing
                .entity(&target.reference)
                .is_some_and(|e| sensing::line_of_sight(level, &eyes, e))
        };
        if seen {
            self.time += 1;
            self.attack(t, &target, self.time);
        } else {
            t.set_target(None);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Guardian.Attack"
    }
}
