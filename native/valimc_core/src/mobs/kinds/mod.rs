//! Mob families (VMC-081d), ported from `Valimc.AI.Kind` and
//! `Valimc.AI.Mobs`: one `Kind` per family module, giving its types' goals
//! and targets (`registerGoals`, checked against vanilla's in the AI facts
//! as `Mobs.__after_compile__` checks them), navigation, motion, its own
//! data, the parts of vanilla's tick its classes override, its sounds and
//! hurts (`combat::Family`), what its goals ask of it (`ai::Hooks`) and the
//! outside actions on it (`interact`). Every hook defaults to what the
//! Elixir does for a family without it (vanilla's `PathfinderMob`).
//!
//! A `Registry` maps entity type ids to the ported families; a type without
//! one is not native (its section yields it to Elixir). The registry is also
//! the living rules' `combat::Families`.
//!
//! Hooks run on the mob as its AI sees it (`Turn`): what the Elixir hook
//! returns in a changed `Self` is a change of the turn here, and its draws
//! are the turn's.

use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::goals::Float;
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::mind::Own;
use crate::mobs::ai::navigation::NavKind;
use crate::mobs::ai::turn::Turn;
use crate::mobs::ai::Opaque;
use crate::mobs::combat::{DefaultFamily, Families, Family, Rules};
use crate::mobs::facts::ai::GoalFact;
use crate::mobs::facts::MobFacts;
use crate::mobs::model::{Body, FamilyData, Mind, MindState, Mob, NativeMob, TravelKind};
use crate::mobs::sensing::SensedItem;
use crate::mobs::term::{Atom, Value};
use crate::physics::mob::Ticked;
use std::collections::HashMap;

pub mod interact;
pub mod leads;

pub use interact::{Hand as HandUse, Interaction, Outcome, Request};

/// One goal a family registers (`{priority, "VanillaGoal", module, flags,
/// state}`).
pub struct Registration {
    pub priority: i32,
    /// Vanilla's goal class, as the AI facts name it.
    pub name: &'static str,
    /// `goal::MOVE | LOOK | JUMP | TARGET`.
    pub flags: u8,
    pub goal: Box<dyn Goal>,
}

impl Registration {
    pub fn new(priority: i32, name: &'static str, flags: u8, goal: impl Goal) -> Registration {
        Registration {
            priority,
            name,
            flags,
            goal: Box::new(goal),
        }
    }
}

/// A type's goals and targets in registration order.
#[derive(Default)]
pub struct Registered {
    pub goals: Vec<Registration>,
    pub targets: Vec<Registration>,
}

/// `createNavigation`: its kind and abilities (`Navigation.new/2`'s).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NavSpec {
    pub kind: NavKind,
    /// A swimmer's `allowBreaching`.
    pub breaching: bool,
    /// `WallClimberNavigation`.
    pub climber: bool,
    pub can_open_doors: bool,
}

impl Default for NavSpec {
    /// `{:ground, []}`.
    fn default() -> NavSpec {
        NavSpec {
            kind: NavKind::Ground,
            breaching: false,
            climber: false,
            can_open_doors: false,
        }
    }
}

/// What its movement makes (`MovementEmission`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Emission {
    All,
    Events,
    Sounds,
    None,
}

/// How the kernel moves it (`motion/0`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct KindMotion {
    pub fixed: bool,
    pub pushable: bool,
    pub pushes: bool,
    pub fluid_pushed: bool,
    /// `{kind, sink}`.
    pub travel: (TravelKind, bool),
    pub emission: Emission,
    pub step_gap: Option<f64>,
    pub lava_walker: bool,
}

impl Default for KindMotion {
    /// `MobMotion`'s `@default_kind`.
    fn default() -> KindMotion {
        KindMotion {
            fixed: false,
            pushable: true,
            pushes: true,
            fluid_pushed: true,
            travel: (TravelKind::Ground, false),
            emission: Emission::All,
            step_gap: None,
            lava_walker: false,
        }
    }
}

impl KindMotion {
    /// `MobMotion.sounds?/1`: its movement makes sounds.
    pub fn sounds(&self) -> bool {
        matches!(self.emission, Emission::All | Emission::Sounds)
    }
}

/// A family: its types' AI, tick, data, hurts and interactions.
pub trait Kind: Hooks + Family {
    /// The Elixir module it ports.
    fn module(&self) -> &'static str;

    /// `types/0`: its entity types.
    fn types(&self) -> &[&'static str];

    /// `goals/1` of a type (`registerGoals`).
    fn goals(&self, facts: &MobFacts, type_id: u16) -> Registered;

    /// `navigation/0`.
    fn navigation(&self, _type_id: u16) -> NavSpec {
        NavSpec::default()
    }

    /// `brain/0`: whether its mobs think with a brain (the brain families
    /// are not native yet).
    fn brain(&self) -> bool {
        false
    }

    /// `motion/0`.
    fn kernel_motion(&self) -> KindMotion {
        KindMotion::default()
    }

    /// `Animal.animal?/1`: an ageable animal (its love and age sensed, its
    /// data read by its partner).
    fn animal(&self) -> bool {
        false
    }

    /// Whether others sense its own fields (`AI.sensed/1`'s `own`: a fish's
    /// school).
    fn sensed_own(&self) -> bool {
        false
    }

    /// `finalize/2`: its `finalizeSpawn` for `reason`; by default `Mob`'s
    /// own (`Spawn.mob/2`).
    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        crate::mobs::ai::spawn::mob(t, reason);
    }

    // ## The tick

    /// `tick_start/1`: its `tick()` before `super.tick()`.
    fn tick_start(&self, _t: &mut Turn) {}

    /// `before_ai/1`: its `aiStep()` before `super.aiStep()`.
    fn before_ai(&self, _t: &mut Turn) {}

    /// `custom_step/1`: `customServerAiStep`, after navigation.
    fn custom_step(&self, _t: &mut Turn) {}

    /// `move_control/1`: its own move control, before the look control.
    fn move_control(&self, _t: &mut Turn) {}

    /// `after_ai/1`: its `aiStep()` after `super.aiStep()`, after the move.
    fn after_ai(&self, _t: &mut Turn) {}

    /// `after_tick/1`: its `tick()` after `super.tick()`.
    fn after_tick(&self, _t: &mut Turn) {}

    /// `ambient_sound/1`: the sound its timer plays (an id), which may draw;
    /// by default its type's.
    fn ambient_sound(&self, t: &mut Turn) -> Option<i32> {
        let name = t.facts.ambient_sound.as_deref()?;
        t.level.facts.sounds.id(name)
    }

    /// `step_sound/1`: its own step sound (a turtle's).
    fn step_sound(&self, _t: &mut Turn) {}

    /// `breath/1`: its own air in its base tick (`{air, drowning damage}`).
    fn breath(&self, _t: &mut Turn) -> Option<(i32, f64)> {
        None
    }

    /// `air/2`: a water animal's air from its supply and wetness.
    fn air(&self, _supply: i32, _wet: bool) -> Option<(i32, f64)> {
        None
    }

    /// `wet?/1`: wet for `air/2` (an axolotl in rain); by default in water.
    fn wet(&self, t: &Turn) -> bool {
        t.in_water()
    }

    /// `dying?/0`: a dying mob still runs its own tick hooks.
    fn dying(&self) -> bool {
        false
    }

    /// `splash_sound/0`, `swim_sound/0` (None: the generic or hostile one)
    /// and `swim_volume/0`.
    fn splash_sound(&self) -> Option<&'static str> {
        None
    }

    fn swim_sound(&self) -> Option<&'static str> {
        None
    }

    fn swim_volume(&self) -> f64 {
        1.0
    }

    /// `falls?/0`: false never lands (a bat).
    fn falls(&self) -> bool {
        true
    }

    /// `climbs?/1`: it climbs what it bumped into (None: no wall climb).
    fn climbs(&self, _body: &Body) -> Option<bool> {
        None
    }

    /// `jump/1`: a cube's `{bonus, lava}`: what its jump from the ground
    /// adds, and its jump power in lava (a magma cube's).
    fn jump(&self, _body: &Body) -> Option<(f64, Option<f64>)> {
        None
    }

    /// `collider/2`: a solid entity box (a shulker's).
    fn collider(&self, _body: &Body, _position: [f64; 3]) -> Option<[f64; 6]> {
        None
    }

    /// `after_move/3`: its part after the kernel moved it, with the effects
    /// it makes (a zombie drowning).
    fn after_move(&self, _mob: &mut NativeMob, _ticked: &Ticked) -> Vec<Effect> {
        Vec::new()
    }

    /// `leashable?/0`.
    fn leashable(&self) -> bool {
        false
    }

    /// Whether a mob that does not think (`NoAI`) still runs its family's
    /// `aiStep` and `tick` after the move (`still/4`: an animal ageing, a
    /// pufferfish's contact, a shulker's lid, an endermite's lifetime).
    fn still(&self) -> bool {
        self.animal()
    }

    /// `consume_sound/2` (`OverrideConsumeSound`): its own sound drinking
    /// item `item` (`ai::consume`); None: the item's.
    fn consume_sound(&self, _item: i32) -> Option<i32> {
        None
    }

    /// `affected?/1` (`canBeAffected`): whether status effect `effect` may
    /// be given to it (a wither skeleton is never withered).
    fn affected(&self, _effect: i32) -> bool {
        true
    }

    /// `young?/1`: a baby by its own data (sensed `baby`); None: its `baby`
    /// flag.
    fn young(&self, _body: &Body) -> Option<bool> {
        None
    }

    /// `hidden?/1`: hidden from enemies.
    fn hidden(&self, _body: &Body) -> bool {
        false
    }

    // ## Conversions

    /// `baby?/1`: a baby by its family's own flag, which a conversion keeps.
    fn baby(&self, _body: &Body) -> bool {
        false
    }

    /// `set_baby/2` (`setBaby`): its flag and what comes with it.
    fn set_baby(&self, _mob: &mut Mob, _data: &mut FamilyData, _baby: bool) {}

    /// `after_conversion/3`: its step after a mob converted into it, at the
    /// local difficulty's `special` multiplier (a zombie's attributes, from
    /// the new mob's own random).
    fn after_conversion(&self, _facts: &MobFacts, _body: &mut Body, _special: f64) {}

    /// `split/2`: the mobs a dead one becomes as it is removed, `(body,
    /// position)` (a cube's halves), from its own random.
    fn split(&self, _rules: &Rules, _body: &Body, _position: [f64; 3]) -> Vec<(Body, [f64; 3])> {
        Vec::new()
    }

    // ## Gear

    /// `wants?/2`: whether it picks item `item` up (`wantsToPickUp`).
    fn wants(&self, t: &Turn, item: i32) -> bool {
        self.can_hold(t, item)
    }

    /// `can_hold?/2` (`canHoldItem`).
    fn can_hold(&self, _t: &Turn, _item: i32) -> bool {
        true
    }

    /// `preferred_weapons/1`: item ids.
    fn preferred_weapons(&self, _type_id: u16) -> Option<&[i32]> {
        None
    }

    /// `pick_up/2`: its own `pickUpItem`; false: the usual.
    fn pick_up(&self, _t: &mut Turn, _item: &SensedItem) -> bool {
        false
    }

    // ## Others' changes

    /// A family's change of another's own state (`{:own, uuid, change}`).
    fn own_change(&self, _own: &mut Own, _change: &dyn Opaque) {}

    /// A family's change of another's mind (`{:remote, uuid, change}`).
    fn remote_change(&self, _mind: &mut MindState, _change: &dyn Opaque) {}

    // ## Outside actions

    /// A player's use of an item on it (`mobInteract`): see
    /// `interact::Interaction`.
    fn interact(&self, _i: &mut Interaction) -> Outcome {
        Outcome::Pass
    }

    /// Its own data a record of a fresh body of type `type_id` holds, as
    /// `(key, value)` (the family's `data/1`, without draws).
    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Vec::new()
    }
}

/// The ported families by entity type id.
pub struct Registry {
    kinds: Vec<Box<dyn Kind>>,
    by_type: HashMap<u16, usize>,
}

impl std::fmt::Debug for Registry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Registry")
            .field("types", &self.by_type.len())
            .finish()
    }
}

/// `{priority, name, flags}` of registered goals (`Mobs.differing/0`).
fn shape(list: &[Registration]) -> Vec<(i32, &str, u8)> {
    list.iter().map(|r| (r.priority, r.name, r.flags)).collect()
}

fn facts_shape(list: &[GoalFact]) -> Vec<(i32, &str, u8)> {
    list.iter()
        .map(|g| (g.priority, g.name.as_str(), g.flags))
        .collect()
}

impl Registry {
    /// Every ported family (`Valimc.AI.Mobs`' `@families` that moved).
    pub fn new(facts: &MobFacts) -> Result<Registry, String> {
        let mut kinds = crate::mobs::animals::kinds(facts)?;
        kinds.extend(crate::mobs::monsters::kinds(facts)?);
        kinds.extend(crate::mobs::water::kinds(facts)?);
        Registry::of(facts, kinds)
    }

    /// A registry of `kinds`, each type's goals checked against vanilla's
    /// (the AI facts' `goals` and `targets` of each type that has them).
    pub fn of(facts: &MobFacts, kinds: Vec<Box<dyn Kind>>) -> Result<Registry, String> {
        let mut by_type = HashMap::new();
        for (i, kind) in kinds.iter().enumerate() {
            for name in kind.types() {
                let id = facts
                    .entities
                    .id(name)
                    .ok_or_else(|| format!("{}: unknown type {name}", kind.module()))?;
                if by_type.insert(id, i).is_some() {
                    return Err(format!("{name} has two families"));
                }
                if let Some(ai) = facts.ai.mob(id) {
                    let registered = kind.goals(facts, id);
                    if shape(&registered.goals) != facts_shape(&ai.goals)
                        || shape(&registered.targets) != facts_shape(&ai.targets)
                    {
                        return Err(format!(
                            "goals differ from vanilla's (MobAiOracle facts) for {name}"
                        ));
                    }
                }
            }
        }
        Ok(Registry { kinds, by_type })
    }

    /// The family of type `type_id`; None: not native.
    pub fn kind(&self, type_id: u16) -> Option<&dyn Kind> {
        self.by_type.get(&type_id).map(|&i| &*self.kinds[i])
    }

    /// Whether type `type_id` is native.
    pub fn native(&self, type_id: u16) -> bool {
        self.by_type.contains_key(&type_id)
    }

    /// The native types.
    pub fn types(&self) -> impl Iterator<Item = u16> + '_ {
        self.by_type.keys().copied()
    }

    /// `AI.thinks?/1`: a type with AI facts and goals.
    pub fn thinks(&self, facts: &MobFacts, type_id: u16) -> bool {
        self.native(type_id) && facts.ai.mob(type_id).is_some()
    }
}

impl Families for Registry {
    fn family(&self, entity_type: u16) -> &dyn Family {
        match self.kind(entity_type) {
            Some(kind) => kind,
            None => &DefaultFamily,
        }
    }
}

/// A player's use of an item on a native mob (`RegionData`'s
/// `{:interact_entity}` chain): its lead part (`leads::interact`, when the
/// player is known as a holder), then its family's (`Kind::interact`).
pub fn interact(i: &mut Interaction, kind: &dyn Kind, player: Option<&leads::Player>) -> Outcome {
    if let Some(player) = player {
        match leads::interact(i, kind, player) {
            Outcome::Pass => {}
            other => return other,
        }
    }
    kind.interact(i)
}

/// `Conversion.convert/4` (`Mob.convertTo` with `ConversionParams.single`):
/// the body `body` becomes as type `to` with `uuid`, at the local
/// difficulty's `special` multiplier: a fresh one of its new type with a
/// fresh mind of `uuid` that keeps its rotations, motion, equipment and drop
/// chances, effects, absorption, hurt time, the player that hurt it, loot
/// pickup, handedness, persistence, AI flag and name; a baby stays one
/// (`convertCommon`); then its new family's step after a conversion. None
/// for a type that is not a mob.
pub fn convert(
    rules: &Rules,
    kinds: &Registry,
    body: &Body,
    uuid: &crate::mobs::sensing::Uuid,
    to: u16,
    special: f64,
) -> Option<Body> {
    let facts = rules.facts;
    let ty = crate::mobs::living::mob::Type::of(facts, facts.entities.name(to)?)?;
    let mut new = crate::mobs::living::body::fresh(rules, ty);
    let old = &body.mob;
    let fresh = &mut new.mob;
    fresh.equipment = old.equipment.clone();
    fresh.drop_chances = old.drop_chances.clone();
    fresh.motion.fall_distance = old.motion.fall_distance;
    fresh.player_memory = old.player_memory;
    fresh.hurt_by_player = old.hurt_by_player;
    fresh.living.effects = old.living.effects.clone();
    fresh.living.absorption = old.living.absorption;
    fresh.living.health.hurt_ticks = old.living.health.hurt_ticks;
    fresh.can_pick_up_loot = old.can_pick_up_loot;
    fresh.left_handed = old.left_handed;
    fresh.no_ai = old.no_ai;
    fresh.persistent = old.persistent;
    fresh.ai = Some(Mind {
        random: crate::mobs::random::LegacyRandom::from_uuid(uuid),
        memories: None,
        state: None,
    });
    new.yaw = body.yaw;
    new.pitch = body.pitch;
    new.head_yaw = body.head_yaw;
    new.velocity = body.velocity;
    new.on_ground = body.on_ground;
    new.no_gravity = body.no_gravity;
    new.custom_name = body.custom_name.clone();
    new.portal_cooldown = body.portal_cooldown;
    let from = facts
        .entities
        .id(&body.entity_type)
        .and_then(|id| kinds.kind(id));
    let into = kinds.kind(to);
    if from.is_some_and(|k| k.baby(body)) {
        if let Some(into) = into {
            into.set_baby(&mut new.mob, &mut new.data, true);
        }
    }
    if let Some(into) = into {
        into.after_conversion(facts, &mut new, special);
    }
    Some(new)
}

/// `Mobs.selectors/1`: a fresh mind's goal and target selectors, and
/// whether a `FloatGoal` makes its navigation float.
pub fn selectors(
    kind: &dyn Kind,
    facts: &MobFacts,
    type_id: u16,
) -> (crate::mobs::ai::Selector, crate::mobs::ai::Selector, bool) {
    use crate::mobs::ai::Selector;
    let registered = kind.goals(facts, type_id);
    let floats = registered.goals.iter().any(|r| r.goal.is::<Float>());
    let entries = |list: Vec<Registration>| {
        Selector::new(
            list.into_iter()
                .map(|r| (r.priority, r.flags, r.goal))
                .collect(),
        )
    };
    (
        entries(registered.goals),
        entries(registered.targets),
        floats,
    )
}
