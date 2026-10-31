//! The one hurt path for native mobs (VMC-081d), ported from
//! `Valimc.Entity.Combat`: `hurt_body` is `LivingEntity.hurtServer` on a mob
//! for every kind of damage (melee, explosions, falling blocks, its own
//! falls, fire and drowning, projectiles); `resolve` the same as a store
//! applies it, `hurt_mob` a hit without attacker from the mob's own vitals,
//! `hit_body` a mob's melee landing mid-tick, `knockback` an attack's extra
//! knockback and `mob_hit` the hit a mob's `doHurtTarget` deals. A hit
//! outside the cooldown sends the damage event, knocks the mob away from the
//! source and plays the hurt sound; a death sends the death sound and event
//! and leaves on the mob what its owner drops (`Mob.death`, `Death`): its
//! loot table's death, its equipment by drop chance and a player kill's
//! experience.
//!
//! A family's part is the `Family` hook trait (`Valimc.AI.Kind`'s optional
//! callbacks the hurt path calls), every hook defaulting to the Elixir's
//! default; the AI's part (`Valimc.AI.hurt`, `voice`, the idle reset) is
//! `MindLink`. Draws the Elixir takes from the mind's random, or from
//! `:rand` for a mob without a mind, come from the mob's own random
//! (`LegacyRandom`, made from its uuid where it has none yet), as vanilla's
//! entity random.

use super::facts::MobFacts;
use super::living::facts::{tag, LivingFacts};
use super::living::melee::{self, DEFAULT_KNOCKBACK};
use super::living::mob::{self as living_mob, Type};
use super::living::{enchant, enchantments, f, items};
use super::model::{Body, FamilyData, Mind, MobMotion, NativeMob, Slot};
use super::random::LegacyRandom;
use super::sensing::{Kind, Ref};
use super::term::{Atom, Map, Value, NIL};

/// The living entity that caused a hit or dealt it (`%{uuid, entity_id,
/// player, type, mainhand}`).
#[derive(Clone, Debug, PartialEq)]
pub struct Attacker {
    pub uuid: [u8; 16],
    pub entity_id: i32,
    pub player: bool,
    /// Its entity type (`"minecraft:player"` for a player).
    pub entity_type: String,
    /// Its main hand's stack (None: empty).
    pub mainhand: Option<Value>,
    /// A player's luck (`getLuck`), which the loot of a mob it kills reads.
    pub luck: f64,
}

/// A hit (`%{source, amount, ...}`).
#[derive(Clone, Debug, PartialEq)]
pub struct Hit {
    /// The damage type's registry id.
    pub source: u16,
    pub amount: f64,
    /// The living entity that caused it.
    pub attacker: Option<Attacker>,
    /// The entity that dealt it.
    pub direct: Option<Attacker>,
    /// Where knockback points away from (none: a random direction).
    pub position: Option<[f64; 3]>,
    /// A projectile's knockback direction `{xd, zd}`.
    pub direction: Option<[f64; 2]>,
    /// An attack's extra knockback `{power, {xd, zd}}`.
    pub extra_knockback: Option<(f64, [f64; 2])>,
    /// A throw up after a hurt (an iron golem's).
    pub lift: Option<f64>,
    /// A hit its class makes it vulnerable to passes its immunities.
    pub bypass_immunity: bool,
    /// The death message's killer (a text tag term), carried along.
    pub killer: Option<Value>,
    /// The dragon part it struck (0 the head, 1 the neck, ...), where it
    /// struck one.
    pub dragon_part: Option<u8>,
    /// Its enchantments' post-attack effects run when it hurts (VMC-037q):
    /// a melee hit, `doPostAttackEffects`.
    pub post_attack: bool,
    /// An arrow's Punch: its knockback and horizontal motion `{x, z}`.
    pub punch: Option<(f64, [f64; 2])>,
    /// The effects a hit that lands adds (a tipped arrow's, a wither
    /// skeleton's wither): `(id, rung)`.
    pub effects: Vec<(i32, super::model::Rung)>,
    /// The attacker's fall distance, ground and flying as requirements
    /// read them (Wind Burst's, VMC-037q).
    pub attacker_motion: Option<(f64, bool, bool)>,
}

impl Hit {
    /// An added effect's term, `{id, {ticks, amplifier, ambient, particles,
    /// icon}}`.
    pub fn effect_of(v: &Value) -> Option<(i32, super::model::Rung)> {
        let [id, rung] = v.as_tuple_n::<2>()?;
        let [ticks, amplifier, ambient, particles, icon] = rung.as_tuple_n::<5>()?;
        let amplifier = u8::try_from(amplifier.as_int()?).ok()?;
        Some((
            i32::try_from(id.as_int()?).ok()?,
            super::model::Rung {
                ticks: i32::try_from(ticks.as_int()?).ok()?,
                amplifier,
                ambient: ambient.as_bool()?,
                particles: particles.as_bool()?,
                icon: icon.as_bool()?,
            },
        ))
    }

    /// A hit of `amount` from damage type `source` with nothing else.
    pub fn new(source: u16, amount: f64) -> Hit {
        Hit {
            source,
            amount,
            attacker: None,
            direct: None,
            position: None,
            direction: None,
            extra_knockback: None,
            lift: None,
            bypass_immunity: false,
            killer: None,
            dragon_part: None,
            post_attack: false,
            punch: None,
            effects: Vec::new(),
            attacker_motion: None,
        }
    }
}

/// A hurt's outcome: a full hit (the hurt animation, the damage event and
/// knockback) and whether it took its last health.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Outcome {
    pub full: bool,
    pub died: bool,
}

/// A sound by name or by id.
#[derive(Clone, Debug, PartialEq)]
pub enum SoundRef {
    Name(String),
    Id(i32),
}

/// Which of a mob's sounds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SoundKind {
    Hurt,
    Death,
}

/// An entity event a body's change returns (`Body.event_packet/3`'s).
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    /// `{:event, n}`.
    Entity(i32),
    /// `{:damage, type, cause id, direct id, nil}`.
    Damage {
        source: u16,
        cause: Option<i32>,
        direct: Option<i32>,
    },
    /// `{:damage, :generic_kill}` (`/kill`).
    Killed,
    /// `{:sound, sound, source, volume, pitch, seed}`: the owner stamps the
    /// position and the client's seed.
    Sound {
        sound: SoundRef,
        source: i32,
        volume: f64,
        pitch: f64,
    },
    /// A family's own event term.
    Other(Value),
}

/// A family's part of the living rules (`Valimc.AI.Kind`'s optional
/// callbacks the body, vitals and hurt path call, and `Valimc.Entity.Animal`
/// where it acts on them). Every hook defaults to what the Elixir does for a
/// family without it.
pub trait Family: Sync {
    /// `data/1`: a fresh body's own data, of type `type_id` (a family's
    /// types may differ: a zombie villager's villager data).
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::empty()
    }

    /// `Mob.new/1`'s motion (a rabbit's hop).
    fn motion(&self) -> MobMotion {
        MobMotion::default()
    }

    /// `max_air/0` (`getMaxAirSupply`).
    fn max_air(&self) -> i32 {
        300
    }

    /// `own_air?/1`: it keeps its own air (`air/2` or `breath/1`), which its
    /// AI runs.
    fn own_air(&self) -> bool {
        false
    }

    /// `taken/2`: its own take on a hit (a ghast's reflected fireball); None
    /// keeps the hit.
    fn taken(&self, _body: &Body, _hit: &Hit) -> Option<Hit> {
        None
    }

    /// `before_hurt/2`: its part before the hurt lands (an axolotl playing
    /// dead): a changed body, kept only if the hurt goes on.
    fn before_hurt(&self, _body: &Body, _hit: &Hit) -> Option<Body> {
        None
    }

    /// `knockback?/1`.
    fn knockback(&self, _body: &Body) -> bool {
        true
    }

    /// `ignores?/2`: it turns the hit away before its health is asked.
    fn ignores(&self, _body: &Body, _hit: &Hit) -> bool {
        false
    }

    /// `admits_ignored?/2`: an ignored hit still counts (not full, not
    /// dying).
    fn admits_ignored(&self, _body: &Body, _hit: &Hit) -> bool {
        false
    }

    /// `damage_result/3`, here over the body with its hurt mob and its
    /// health before the hurt.
    fn damage_result(&self, _body: &mut Body, _health_before: f64, _outcome: &mut Outcome) {}

    /// `hurt/2`: its part after a hurt, with the events it adds (a squid's
    /// ink).
    fn hurt(&self, _body: &mut Body, _hit: &Hit, _events: &mut Vec<Event>) {}

    /// `hurt_events/2`: what it shows of a hurt from `health_before` (a
    /// golem cracking).
    fn hurt_events(&self, _body: &Body, _health_before: f64) -> Vec<Event> {
        Vec::new()
    }

    /// `hurt/2` of a family whose part reads the living rules (a shulker's
    /// maximum health); by default `hurt`. The hurt path calls this one.
    fn hurt_with(&self, _rules: &Rules, body: &mut Body, hit: &Hit, events: &mut Vec<Event>) {
        self.hurt(body, hit, events);
    }

    /// `hurt_events/2` of a family whose part reads the living rules (a
    /// golem's maximum health); by default `hurt_events`. The hurt path
    /// calls this one.
    fn hurt_events_with(&self, _rules: &Rules, body: &Body, health_before: f64) -> Vec<Event> {
        self.hurt_events(body, health_before)
    }

    /// `repelled/2`: its part after turning a hurt away (an enderman
    /// teleporting from a projectile).
    fn repelled(&self, _body: &mut Body, _hit: &Hit) {}

    /// `volume/1`: its sound volume from the type's.
    fn volume(&self, _body: &Body, volume: f64) -> f64 {
        volume
    }

    /// `sound/2`: its own hurt or death sound.
    fn sound(&self, _body: &Body, _which: SoundKind) -> Option<SoundRef> {
        None
    }

    /// Its ambient interval where the AI facts give none (`AI.ambient_interval/1`
    /// of the dragon): a hurt sound restarts its ambient clock.
    fn ambient_interval(&self) -> Option<i32> {
        None
    }

    /// `voice/2`: its voice pitch's base (a baby's higher).
    fn voice(&self, _body: &Body) -> f32 {
        1.0
    }

    /// The scale of its voice pitch (`voice/2`'s `{base, scale}`: a bat's).
    fn voice_scale(&self, _body: &Body) -> f32 {
        1.0
    }

    /// `death_drops/1`: what it drops of its own (an enderman's block).
    fn death_drops(&self, _body: &Body) -> Vec<Value> {
        Vec::new()
    }

    /// `Animal.properties/1` then `loot_properties/1`: what loot tables
    /// read of it (a sheep's colour, a cube's size).
    fn loot_properties(&self, _body: &Body) -> Vec<(String, String)> {
        Vec::new()
    }

    /// `experience/1`: its own experience reward (a cube's size).
    fn experience(&self, _body: &Body) -> Option<i32> {
        None
    }

    /// `Animal.hurt/2` after its living rules hurt it (`hurt_if`): an animal
    /// loses its love.
    fn actually_hurt(&self, _data: &mut FamilyData) {}

    /// `values/1`: its own entity data values `(field, value, default)`.
    fn values(&self, _body: &Body) -> Vec<(Atom, Value, Value)> {
        Vec::new()
    }

    /// `dimensions/1`: `[width, height, eye height]` where it changes them.
    fn dimensions(&self, _body: &Body) -> Option<[f32; 3]> {
        None
    }

    /// `box/2`: its own bounding box at `position`.
    fn bounding_box(&self, _body: &Body, _position: [f64; 3]) -> Option<[f64; 6]> {
        None
    }
}

/// A family with every default.
pub struct DefaultFamily;

impl Family for DefaultFamily {}

/// The family of each entity type.
pub trait Families: Sync {
    fn family(&self, entity_type: u16) -> &dyn Family;
}

/// Every type with the default family.
pub struct NoFamilies;

impl Families for NoFamilies {
    fn family(&self, _entity_type: u16) -> &dyn Family {
        &DefaultFamily
    }
}

/// The AI's part of the living rules, over a mind (the parts of
/// `Valimc.AI` a hurt and the vitals call); each acts only on a mind that
/// thought (a `%Mind{}`), as the Elixir's do.
pub trait MindLink: Sync {
    /// `mind.tick` (`tickCount`), 0 for a mind that never thought.
    fn tick(&self, _mind: &Mind) -> i64 {
        0
    }

    /// The idle reset (`no_action: 0`).
    fn stir(&self, _mind: &mut Mind) {}

    /// `Valimc.AI.hurt/3`: the attacker that angers it and the damage type.
    fn hurt(&self, _mind: &mut Mind, _attacker: Option<Ref>, _source: u16) {}

    /// `Mob.playHurtSound` resets the ambient timer (`ambient: -interval`).
    fn hurt_sound(&self, _mind: &mut Mind, _interval: i32) {}

    /// `mind.aggressive` (the mob flags' bit 2).
    fn aggressive(&self, _mind: &Mind) -> bool {
        false
    }
}

/// A mind link that does nothing (minds that never thought).
pub struct NoMind;

impl MindLink for NoMind {}

/// The link over the AI's live mind state (`mobs::ai::MindState`): a mind
/// with no state (one only a record gave) is one that never thought.
pub struct AiMind;

impl MindLink for AiMind {
    fn tick(&self, mind: &Mind) -> i64 {
        mind.state.as_ref().map_or(0, |s| s.tick)
    }

    fn stir(&self, mind: &mut Mind) {
        if let Some(s) = mind.state.as_mut() {
            s.no_action = 0;
        }
    }

    fn hurt(&self, mind: &mut Mind, attacker: Option<Ref>, source: u16) {
        if let Some(s) = mind.state.as_mut() {
            s.hurt(attacker, source);
        }
    }

    fn hurt_sound(&self, mind: &mut Mind, interval: i32) {
        if let Some(s) = mind.state.as_mut() {
            s.ambient = -(interval as i64);
        }
    }

    fn aggressive(&self, mind: &Mind) -> bool {
        mind.state.as_ref().is_some_and(|s| s.aggressive)
    }
}

/// What the rules read.
#[derive(Clone, Copy)]
pub struct Rules<'a> {
    pub facts: &'a MobFacts,
    pub living: &'a LivingFacts,
    pub families: &'a dyn Families,
    pub mind: &'a dyn MindLink,
}

impl<'a> Rules<'a> {
    /// The type named `name`; None for an unknown one.
    pub fn of(&self, name: &str) -> Option<Type<'a>> {
        Type::of(self.facts, name)
    }

    pub fn family(&self, ty: Type) -> &'a dyn Family {
        self.families.family(ty.id)
    }
}

/// The mob's own random: its mind's, made from its uuid where it has none
/// yet (vanilla's entity random exists from construction).
pub fn random<'m>(mob: &'m mut super::model::Mob, uuid: &[u8; 16]) -> &'m mut LegacyRandom {
    &mut mob
        .ai
        .get_or_insert_with(|| Mind {
            random: LegacyRandom::from_uuid(uuid),
            memories: None,
            state: None,
        })
        .random
}

/// How `resolve` ended (`Combat.resolve/2`'s outcome).
#[derive(Clone, Debug, PartialEq)]
pub struct Resolution {
    /// Whether it took the hit.
    pub hurt: bool,
    pub full: bool,
    pub died: bool,
    /// Its health before and after.
    pub previous: f64,
    pub health: f64,
    /// The post-attack actions on the attacker, for its owner (VMC-037q).
    pub post: Vec<enchant::Action>,
}

/// `Combat.resolve/2` on a mob: its events and the outcome; a turned-away
/// hit only stirs it and runs its family's `repelled`.
pub fn resolve(rules: &Rules, mob: &mut NativeMob, hit: &Hit) -> (Vec<Event>, Resolution) {
    let before = mob.body.mob.living.health.value;
    let position = mob.position;
    match hurt_body(rules, mob, Some(position), hit) {
        None => {
            stir(rules, mob, hit);
            repelled(rules, mob, hit);
            (
                Vec::new(),
                Resolution {
                    hurt: false,
                    full: false,
                    died: false,
                    previous: before,
                    health: before,
                    post: Vec::new(),
                },
            )
        }
        Some((events, outcome)) => {
            let post = if hit.post_attack {
                post_attack(rules, mob, hit)
            } else {
                Vec::new()
            };
            (
                events,
                Resolution {
                    hurt: true,
                    full: outcome.full,
                    died: outcome.died,
                    previous: before,
                    health: mob.body.mob.living.health.value,
                    post,
                },
            )
        }
    }
}

/// `EnchantmentHelper.doPostAttackEffectsWithItemSource` on a mob hurt by
/// `hit` (VMC-037q): the effects of its equipment (enchanted victim), then
/// of the attacker's weapon (enchanted attacker). Those on the mob apply
/// here; those on the attacker are returned for its owner, a worn piece's
/// wear as the piece's own.
pub fn post_attack(rules: &Rules, mob: &mut NativeMob, hit: &Hit) -> Vec<enchant::Action> {
    let engine = &rules.living.enchant;
    let motion = hit.attacker_motion.unwrap_or((0.0, false, false));
    let view = |a: &Attacker| enchant::EntityView {
        type_id: rules
            .facts
            .entities
            .ids
            .get(&a.entity_type)
            .copied()
            .unwrap_or(0),
        player: a.player.then(|| ("survival".to_owned(), 20)),
        fall_distance: motion.0,
        on_ground: motion.1,
        flying: motion.2,
        ..Default::default()
    };
    let this = enchant::EntityView {
        type_id: rules
            .facts
            .entities
            .ids
            .get(&mob.body.entity_type)
            .copied()
            .unwrap_or(0),
        on_ground: mob.body.on_ground,
        fall_distance: mob.body.mob.motion.fall_distance,
        ..Default::default()
    };
    let attacker = hit.attacker.as_ref().map(view);
    let direct = hit.direct.as_ref().map(view);
    let is_direct = match (&hit.attacker, &hit.direct) {
        (Some(a), Some(d)) => a.uuid == d.uuid,
        _ => false,
    };
    let ctx = enchant::Context {
        this: Some(&this),
        attacker: attacker.as_ref(),
        direct: direct.as_ref(),
        damage: Some((hit.source, is_direct)),
        ..Default::default()
    };
    let uuid = mob.uuid;
    let enchanted =
        |stack: Option<&Value>| stack.is_some_and(|s| !items::enchantments(s).is_empty());
    if !Slot::ALL
        .iter()
        .any(|slot| enchanted(mob.body.mob.equipment.get(*slot)))
        && !enchanted(hit.attacker.as_ref().and_then(|a| a.mainhand.as_ref()))
    {
        // Nothing to run: the mob's random stays untouched.
        return Vec::new();
    }
    // The plan first, from the mob's own random; then its effects.
    let mut worn: Vec<(Slot, i32)> = Vec::new();
    let mut on_mob = Vec::new();
    let mut out = Vec::new();
    {
        let equipment = mob.body.mob.equipment.clone();
        let random = random(&mut mob.body.mob, &uuid);
        let mut draws = enchant::Legacy { random, held: None };
        for slot in Slot::ALL {
            let Some(stack) = equipment.get(slot) else {
                continue;
            };
            let levels: Vec<(&str, i32)> = items::enchantments(stack)
                .into_iter()
                .filter(|(name, _)| engine.in_slot(name, slot))
                .map(|(n, l)| (n, l as i32))
                .collect();
            for (target, action) in engine.post_attack(
                rules.facts,
                enchant::Target::Victim,
                &levels,
                &ctx,
                &mut draws,
            ) {
                match (target, action) {
                    (_, enchant::Action::ItemDamage(n)) => worn.push((slot, n)),
                    (enchant::Target::Victim, a) => on_mob.push(a),
                    (_, a) => out.push(a),
                }
            }
        }
        if let Some(weapon) = hit.attacker.as_ref().and_then(|a| a.mainhand.as_ref()) {
            let levels: Vec<(&str, i32)> = items::enchantments(weapon)
                .into_iter()
                .filter(|(name, _)| engine.in_slot(name, Slot::Mainhand))
                .map(|(n, l)| (n, l as i32))
                .collect();
            for (target, action) in engine.post_attack(
                rules.facts,
                enchant::Target::Attacker,
                &levels,
                &ctx,
                &mut draws,
            ) {
                match target {
                    enchant::Target::Victim => on_mob.push(action),
                    _ => out.push(action),
                }
            }
        }
    }
    for (slot, n) in worn {
        wear_piece(rules, mob, slot, n);
    }
    for action in on_mob {
        apply_on_mob(rules, mob, action);
    }
    out
}

/// A worn piece's `hurtAndBreak` by `n` (Thorns' cost on the victim).
fn wear_piece(rules: &Rules, mob: &mut NativeMob, slot: Slot, n: i32) {
    let Some(stack) = mob.body.mob.equipment.get(slot).cloned() else {
        return;
    };
    let uuid = mob.uuid;
    let wear = {
        let random = random(&mut mob.body.mob, &uuid);
        super::living::durability::hurt_and_break(
            rules.living,
            rules.facts,
            &stack,
            n as i64,
            || random.float() as f64,
        )
    };
    match wear {
        super::living::durability::Wear::Worn(next) => mob.body.mob.equipment.set(slot, Some(next)),
        super::living::durability::Wear::Broken(_) => mob.body.mob.equipment.set(slot, None),
        super::living::durability::Wear::Unchanged => {}
    }
}

/// A post-attack action on the mob itself.
fn apply_on_mob(rules: &Rules, mob: &mut NativeMob, action: enchant::Action) {
    let Some(ty) = rules.of(&mob.body.entity_type) else {
        return;
    };
    match action {
        enchant::Action::Ignite(seconds) => {
            let factor = living_mob::value(
                rules.living,
                rules.facts,
                ty,
                &mob.body.mob,
                rules.living.attributes.burning_time,
            );
            let fire = &mut mob.body.mob.living.fire_ticks;
            *fire = super::living::burning::ignite_seconds(*fire, seconds as f64, factor, false);
        }
        enchant::Action::MobEffect {
            effect,
            ticks,
            amplifier,
        } => {
            if let Some(id) = rules.facts.effects.id(&effect) {
                super::living::effects::add(
                    &mut mob.body.mob.living.effects,
                    id as i32,
                    super::model::Rung {
                        ticks,
                        amplifier: amplifier.clamp(0, 255) as u8,
                        ambient: false,
                        particles: true,
                        icon: true,
                    },
                );
            }
        }
        enchant::Action::Damage(amount, damage_type) => {
            if let Some(source) = rules.facts.damage_types.id(&damage_type) {
                hurt_mob(rules, mob, source, amount as f64);
            }
        }
        // Sounds, summons and explosions on a mob come with the trident and
        // the mace (VMC-037q4, q5).
        _ => {}
    }
}

/// `Combat.hurt_mob/5`: a hit without attacker from the mob's own vitals
/// (falls, fire, drowning): its events and whether it hurt. As the Elixir
/// runs it over a bare body, only the mob part changes: its velocity and
/// data stay as they were.
pub fn hurt_mob(
    rules: &Rules,
    mob: &mut NativeMob,
    source: u16,
    amount: f64,
) -> (Vec<Event>, bool) {
    let velocity = mob.body.velocity;
    let data = mob.body.data.clone();
    let hit = Hit::new(source, amount);
    let result = match hurt_body(rules, mob, None, &hit) {
        None => {
            stir(rules, mob, &hit);
            repelled(rules, mob, &hit);
            (Vec::new(), false)
        }
        Some((events, _)) => (events, true),
    };
    mob.body.velocity = velocity;
    mob.body.data = data;
    result
}

/// `Combat.hit_body/3`: a hit that lands mid-tick (a mob's melee on a mob):
/// its events and whether it hurt; an ignored hit only stirs it.
pub fn hit_body(rules: &Rules, mob: &mut NativeMob, hit: &Hit) -> (Vec<Event>, bool) {
    let position = mob.position;
    match hurt_body(rules, mob, Some(position), hit) {
        None => {
            stir(rules, mob, hit);
            (Vec::new(), false)
        }
        Some((events, _)) => (events, true),
    }
}

/// `Combat.hurt_body/3`: `hurtServer` on a mob at `at` (none where only
/// knockback-free damage comes): its events and outcome, or None (nothing
/// changed) when it is ignored.
pub fn hurt_body(
    rules: &Rules,
    mob: &mut NativeMob,
    at: Option<[f64; 3]>,
    hit: &Hit,
) -> Option<(Vec<Event>, Outcome)> {
    let ty = rules.of(&mob.body.entity_type)?;
    let family = rules.family(ty);
    let taken = family.taken(&mob.body, hit);
    let hit = taken.as_ref().unwrap_or(hit);
    let mut replaced = family.before_hurt(&mob.body, hit);
    let uuid = mob.uuid;
    let position = mob.position;
    let body: &mut Body = match replaced.as_mut() {
        Some(b) => b,
        None => &mut mob.body,
    };
    let knocks = family.knockback(body);
    let health_before = body.mob.living.health.value;

    let outcome = if family.ignores(body, hit) {
        None
    } else {
        living_mob::hurt(rules.living, rules.facts, ty, &mut body.mob, hit)
    };
    let Some(mut outcome) = outcome else {
        if family.admits_ignored(body, hit) {
            if let Some(b) = replaced {
                mob.body = b;
            }
            return Some((
                Vec::new(),
                Outcome {
                    full: false,
                    died: false,
                },
            ));
        }
        return None;
    };

    family.damage_result(body, health_before, &mut outcome);
    let source = hit.source;
    let sounds = sounds(rules, ty, family, body);
    if let Some(mind) = body.mob.ai.as_mut() {
        rules.mind.hurt(mind, anger(rules, hit), source);
    }

    let mut events = Vec::new();
    if outcome.full {
        events.push(Event::Damage {
            source,
            cause: hit.attacker.as_ref().map(|a| a.entity_id),
            direct: hit.direct.as_ref().map(|a| a.entity_id),
        });
        if knocks && !rules.living.is(source, tag::NO_KNOCKBACK) {
            let direction = hit.direction.unwrap_or_else(|| away(at, hit.position));
            knock(rules, ty, family, body, DEFAULT_KNOCKBACK, direction);
        }
    }
    if outcome.died && outcome.full {
        if let Some(sound) = sound(rules, ty, family, body, &uuid, &sounds, SoundKind::Death) {
            events.push(sound);
        }
        events.push(Event::Entity(3));
    } else if outcome.died {
        events.push(Event::Entity(3));
    } else if outcome.full {
        if let Some(sound) = sound(rules, ty, family, body, &uuid, &sounds, SoundKind::Hurt) {
            events.push(sound);
        }
    }
    if let Some((power, direction)) = hit.extra_knockback {
        if power > 0.0 {
            knock(rules, ty, family, body, power, direction);
        }
    }
    // `AbstractArrow.doKnockback`: along the arrow's horizontal motion,
    // its Punch times 0.6 less the knockback resistance, and up 0.1.
    if let Some((power, [ax, az])) = hit.punch {
        let resistance = living_mob::value(
            rules.living,
            rules.facts,
            ty,
            &body.mob,
            rules.living.attributes.knockback_resistance,
        );
        let length = (ax * ax + az * az).sqrt();
        if length >= 1.0e-4 {
            let scale = power * 0.6 * super::living::emax(0.0, 1.0 - resistance) / length;
            body.velocity[0] += ax * scale;
            body.velocity[1] += 0.1;
            body.velocity[2] += az * scale;
        }
    }
    if let Some(lift) = hit.lift {
        let resistance = living_mob::value(
            rules.living,
            rules.facts,
            ty,
            &body.mob,
            rules.living.attributes.knockback_resistance,
        );
        body.velocity[1] += lift * super::living::emax(0.0, 1.0 - resistance);
    }
    // `doPostHurtEffects` and a melee's own (`WitherSkeleton.doHurtTarget`):
    // a hit that lands adds its effect, even a killing one.
    for &(id, rung) in &hit.effects {
        living_mob::add_effect(rules.facts, ty.id, &mut body.mob, id, rung);
    }
    // `InfestedMobEffect.onMobHurt`: silverfish from the middle of its box,
    // which its owner spawns.
    if body
        .mob
        .living
        .effects
        .get(rules.living.effects.infested)
        .is_some()
    {
        let (pitch, yaw) = (body.pitch, body.yaw);
        let velocities = super::living::removal::infested(random(&mut body.mob, &uuid), pitch, yaw);
        if !velocities.is_empty() {
            let [_, height, _] = super::living::body::dimensions(rules, ty, body);
            let at = [
                position[0],
                position[1] + f64::from(height as f32) / 2.0,
                position[2],
            ];
            for v in velocities {
                body.mob.spawns.push(Value::tuple([
                    Value::Binary(b"minecraft:silverfish".to_vec()),
                    Value::vec3(at),
                    Value::Map(Map::from_atoms([
                        ("velocity", Value::vec3(v)),
                        ("hurt_sound", Value::bool(true)),
                    ])),
                ]));
            }
        }
    }
    if outcome.died {
        died(rules, ty, family, body, &uuid, Some(hit));
    }
    family.hurt_with(rules, body, hit, &mut events);
    events.extend(family.hurt_events_with(rules, body, health_before));
    if let Some(b) = replaced {
        mob.body = b;
    }
    Some((events, outcome))
}

/// `stir/2`: a hurt past the first checks restarts the idle time.
fn stir(rules: &Rules, mob: &mut NativeMob, hit: &Hit) {
    let Some(ty) = rules.of(&mob.body.entity_type) else {
        return;
    };
    if living_mob::stirs(rules.living, ty, &mob.body.mob, hit.source) {
        if let Some(mind) = mob.body.mob.ai.as_mut() {
            rules.mind.stir(mind);
        }
    }
}

fn repelled(rules: &Rules, mob: &mut NativeMob, hit: &Hit) {
    if let Some(ty) = rules.of(&mob.body.entity_type) {
        rules.family(ty).repelled(&mut mob.body, hit);
    }
}

/// `Combat.knockback/4`: an attack's extra knockback along the attacker's
/// facing.
pub fn knockback(rules: &Rules, mob: &mut NativeMob, power: f64, direction: [f64; 2]) {
    if let Some(ty) = rules.of(&mob.body.entity_type) {
        knock(rules, ty, rules.family(ty), &mut mob.body, power, direction);
    }
}

fn knock(
    rules: &Rules,
    ty: Type,
    family: &dyn Family,
    body: &mut Body,
    power: f64,
    direction: [f64; 2],
) {
    if family.knockback(body) {
        let resistance = living_mob::value(
            rules.living,
            rules.facts,
            ty,
            &body.mob,
            rules.living.attributes.knockback_resistance,
        );
        body.velocity =
            melee::knockback(body.velocity, body.on_ground, power, direction, resistance);
    }
}

/// `dealDefaultKnockback`: from the source position toward the mob.
fn away(at: Option<[f64; 3]>, position: Option<[f64; 3]>) -> [f64; 2] {
    match (at, position) {
        (Some(e), Some(s)) => [s[0] - e[0], s[2] - e[2]],
        _ => [0.0, 0.0],
    }
}

/// What angers the mob (`resolveMobResponsibleForDamage`).
fn anger(rules: &Rules, hit: &Hit) -> Option<Ref> {
    let attacker = hit.attacker.as_ref()?;
    if rules.living.is(hit.source, tag::NO_ANGER) {
        return None;
    }
    Some(Ref {
        kind: if attacker.player {
            Kind::Player
        } else {
            Kind::Mob
        },
        uuid: attacker.uuid,
    })
}

/// A type's hurt and death sounds at its volume (`sounds/1`).
struct Sounds {
    hurt: Option<SoundRef>,
    death: Option<SoundRef>,
    source: i32,
    volume: f64,
}

fn sounds(rules: &Rules, ty: Type, family: &dyn Family, body: &Body) -> Sounds {
    let facts = rules.facts.combat.mob_sounds(ty.id);
    let volume = rules.facts.ai.mob(ty.id).map_or(1.0, |m| m.volume);
    let volume = family.volume(body, volume);
    let own = |which| {
        family.sound(body, which).map(|s| match s {
            SoundRef::Name(name) => SoundRef::Id(rules.facts.sounds.id(&name).unwrap_or(-1)),
            id => id,
        })
    };
    Sounds {
        hurt: own(SoundKind::Hurt).or_else(|| facts.hurt.clone().map(SoundRef::Name)),
        death: own(SoundKind::Death).or_else(|| facts.death.clone().map(SoundRef::Name)),
        source: facts.source,
        volume,
    }
}

/// `sound/4`: the mob's voice from its random (a hurt also restarts its
/// ambient timer), drawn whether or not it has the sound.
#[allow(clippy::too_many_arguments)]
fn sound(
    rules: &Rules,
    ty: Type,
    family: &dyn Family,
    body: &mut Body,
    uuid: &[u8; 16],
    sounds: &Sounds,
    which: SoundKind,
) -> Option<Event> {
    let base = family.voice(body);
    let scale = family.voice_scale(body);
    let pitch = random(&mut body.mob, uuid).voice_pitch(base) * scale;
    if which == SoundKind::Hurt {
        let interval = rules.facts.ai.mob(ty.id).map(|m| m.ambient_interval);
        if let Some(interval) = interval.or_else(|| family.ambient_interval()) {
            if let Some(mind) = body.mob.ai.as_mut() {
                rules.mind.hurt_sound(mind, interval);
            }
        }
    }
    let sound = match which {
        SoundKind::Hurt => sounds.hurt.clone(),
        SoundKind::Death => sounds.death.clone(),
    }?;
    Some(Event::Sound {
        sound,
        source: sounds.source,
        volume: sounds.volume,
        pitch: pitch as f64,
    })
}

/// `Mob.doHurtTarget`'s hit of `mob` (network id `entity_id`) on a target
/// of entity type `target`: its attack damage after its weapon's
/// enchantments, its knockback along its facing, the death message's
/// killer, from its position. None for a dead mob.
pub fn mob_hit(rules: &Rules, mob: &NativeMob, entity_id: i32, target: u16) -> Option<Hit> {
    let body = &mob.body;
    if !living_mob::alive(&body.mob) {
        return None;
    }
    let ty = rules.of(&body.entity_type)?;
    let weapon = body.mob.equipment.get(Slot::Mainhand);
    let levels = weapon.map(items::enchantments).unwrap_or_default();
    let a = &rules.living.attributes;
    let damage = f(living_mob::value(
        rules.living,
        rules.facts,
        ty,
        &body.mob,
        a.attack_damage,
    ));
    let base_knockback = f(living_mob::value(
        rules.living,
        rules.facts,
        ty,
        &body.mob,
        a.attack_knockback,
    ));
    let knockback = f(enchantments::attack(
        rules.living,
        rules.facts,
        enchantments::AttackKind::Knockback,
        &levels,
        target,
        ty.id,
        base_knockback,
    ) / 2.0);
    let source = weapon
        .and_then(items::item_id)
        .and_then(|id| rules.living.item(id).damage_type)
        .unwrap_or(rules.living.damage.mob_attack);
    let attacker = Attacker {
        uuid: mob.uuid,
        entity_id,
        player: false,
        entity_type: body.entity_type.clone(),
        mainhand: weapon.cloned(),
        luck: 0.0,
    };
    let amount = enchantments::attack(
        rules.living,
        rules.facts,
        enchantments::AttackKind::Damage,
        &levels,
        target,
        ty.id,
        damage,
    );
    let killer = Value::tuple([
        Value::atom("compound"),
        Value::Map(
            Map::from_pairs(vec![(
                Value::Binary(b"translate".to_vec()),
                Value::tuple([
                    Value::atom("string"),
                    Value::Binary(ty.facts.description.as_bytes().to_vec()),
                ]),
            )])
            .expect("one key"),
        ),
    ]);
    Some(Hit {
        source,
        amount,
        attacker: Some(attacker.clone()),
        direct: Some(attacker),
        position: Some(mob.position),
        post_attack: true,
        punch: None,
        attacker_motion: None,
        direction: None,
        extra_knockback: Some((knockback, melee::facing(body.yaw))),
        lift: None,
        bypass_immunity: false,
        killer: Some(killer),
        dragon_part: None,
        effects: Vec::new(),
    })
}

/// The killing damage as loot reads it (`damage_source_properties`).
#[derive(Clone, Debug, PartialEq)]
pub struct DeathSource {
    /// Its type's tags, namespaced.
    pub tags: Vec<String>,
    pub direct: Option<String>,
    pub source: Option<String>,
    pub is_direct: bool,
}

/// An attacker's main hand as a death keeps it: `:none` without an
/// attacker, else its stack (or nil).
#[derive(Clone, Debug, PartialEq)]
pub enum Mainhand {
    NoAttacker,
    Stack(Option<Value>),
}

/// What the owner drops for a death (`Mob.death`: `dropAllDeathLoot`).
#[derive(Clone, Debug, PartialEq)]
pub struct Death {
    pub entity_type: String,
    pub loot_table: Option<String>,
    pub on_fire: bool,
    pub baby: bool,
    pub killed_by_player: bool,
    pub attacker: Mainhand,
    pub direct_attacker: Mainhand,
    pub attacker_type: Option<String>,
    pub direct_attacker_type: Option<String>,
    pub properties: Vec<(String, String)>,
    /// None for a death without a hit (`/kill`).
    pub source: Option<DeathSource>,
    pub experience: i32,
    /// Its equipment as it fell, then its family's own drops.
    pub equipment: Vec<Value>,
    /// The killing player's luck (`withLuck`), 0 without one.
    pub luck: f64,
}

fn binary(s: &str) -> Value {
    Value::Binary(s.as_bytes().to_vec())
}

fn opt_binary(s: &Option<String>) -> Value {
    s.as_deref().map_or(NIL, binary)
}

impl Mainhand {
    fn of(attacker: Option<&Attacker>) -> Mainhand {
        match attacker {
            None => Mainhand::NoAttacker,
            Some(a) => Mainhand::Stack(a.mainhand.clone()),
        }
    }

    fn to_value(&self) -> Value {
        match self {
            Mainhand::NoAttacker => Value::atom("none"),
            Mainhand::Stack(stack) => stack.clone().unwrap_or(NIL),
        }
    }

    /// The loot context's main-hand enchantments (none without attacker).
    fn levels(&self) -> Option<Vec<(String, i32)>> {
        match self {
            Mainhand::NoAttacker => None,
            Mainhand::Stack(None) => Some(Vec::new()),
            Mainhand::Stack(Some(stack)) => Some(
                items::enchantments(stack)
                    .into_iter()
                    .map(|(n, l)| (n.to_owned(), l as i32))
                    .collect(),
            ),
        }
    }
}

impl Death {
    /// The death as the Elixir's `Mob.death` term holds it.
    pub fn to_value(&self) -> Value {
        let source = match &self.source {
            None => NIL,
            Some(s) => Value::Map(Map::from_atoms([
                (
                    "tags",
                    Value::List(s.tags.iter().map(|t| binary(t)).collect()),
                ),
                ("direct", opt_binary(&s.direct)),
                ("source", opt_binary(&s.source)),
                ("is_direct", Value::bool(s.is_direct)),
            ])),
        };
        let loot = Map::from_atoms([
            ("on_fire", Value::bool(self.on_fire)),
            ("baby", Value::bool(self.baby)),
            ("vehicle", NIL),
            ("killed_by_player", Value::bool(self.killed_by_player)),
            ("attacker", self.attacker.to_value()),
            ("direct_attacker", self.direct_attacker.to_value()),
            ("attacker_type", opt_binary(&self.attacker_type)),
            (
                "direct_attacker_type",
                opt_binary(&self.direct_attacker_type),
            ),
            (
                "properties",
                Value::List(
                    self.properties
                        .iter()
                        .map(|(k, v)| Value::tuple([binary(k), binary(v)]))
                        .collect(),
                ),
            ),
            ("source", source),
        ]);
        Value::Map(Map::from_atoms([
            ("type", binary(&self.entity_type)),
            ("loot_table", opt_binary(&self.loot_table)),
            ("loot", Value::Map(loot)),
            ("experience", Value::Int(self.experience as i64)),
            ("equipment", Value::List(self.equipment.clone())),
            ("luck", Value::Float(self.luck)),
        ]))
    }

    /// The loot table's view of it (`Loot.entity_drops/5`'s conversion).
    pub fn loot(&self) -> crate::loot::Death {
        crate::loot::Death {
            on_fire: self.on_fire,
            baby: self.baby,
            vehicle: None,
            killed_by_player: self.killed_by_player,
            attacker: self.attacker.levels(),
            direct_attacker: self.direct_attacker.levels(),
            attacker_type: self.attacker_type.clone(),
            direct_attacker_type: self.direct_attacker_type.clone(),
            properties: self.properties.clone(),
            source: self.source.as_ref().map(|s| crate::loot::DamageInfo {
                tags: s.tags.clone(),
                direct: s.direct.clone(),
                source: s.source.clone(),
                is_direct: s.is_direct,
                source_properties: Vec::new(),
            }),
        }
    }
}

fn entity_type(attacker: Option<&Attacker>) -> Option<String> {
    attacker.map(|a| {
        if a.player {
            "minecraft:player".to_owned()
        } else {
            a.entity_type.clone()
        }
    })
}

/// `AgeableMob.isBaby` as a death reads it: data with a negative `age`.
fn baby(body: &Body) -> bool {
    body.data.age().is_some_and(|age| age < 0)
}

/// `Combat.died/2`: a mob that died of `hit` (None: `/kill`) carries what
/// its owner drops (`mob.death`, its `Death` term).
pub fn died(
    rules: &Rules,
    ty: Type,
    family: &dyn Family,
    body: &mut Body,
    uuid: &[u8; 16],
    hit: Option<&Hit>,
) {
    let mut equipment = equipment_drops(rules, body, uuid, hit);
    equipment.extend(family.death_drops(body));
    let mob = &body.mob;
    let killed_by_player = mob.player_memory > 0;
    let attacker = hit.and_then(|h| h.attacker.as_ref());
    let direct = hit.and_then(|h| h.direct.as_ref());
    let source = hit.map(|h| DeathSource {
        tags: rules.living.tags_of(h.source).to_vec(),
        direct: direct.map(|d| d.entity_type.clone()),
        source: attacker.map(|a| a.entity_type.clone()),
        is_direct: matches!((direct, attacker), (Some(d), Some(a)) if d.uuid == a.uuid),
    });
    let death = Death {
        entity_type: body.entity_type.clone(),
        loot_table: ty.facts.loot_table.clone(),
        on_fire: mob.living.fire_ticks > 0 && !ty.facts.fire_immune,
        baby: baby(body),
        killed_by_player,
        attacker: Mainhand::of(attacker),
        direct_attacker: Mainhand::of(direct),
        attacker_type: entity_type(attacker),
        direct_attacker_type: entity_type(direct),
        properties: family.loot_properties(body),
        source,
        experience: 0,
        equipment,
        luck: attacker.filter(|a| a.player).map_or(0.0, |a| a.luck),
    };
    let experience = if killed_by_player && !baby(body) {
        experience(rules, ty, family, body, uuid)
    } else {
        0
    };
    body.mob.death = Some(
        Death {
            experience,
            ..death
        }
        .to_value(),
    );
}

/// `Mob.dropCustomDeathLoot`: each slot's item by its drop chance (Looting
/// on a player's weapon adds a hundredth a level), from the mob's random;
/// only a player's kill drops what is not kept unworn, and such an item
/// drops worn. Curses of vanishing never drop.
pub fn equipment_drops(
    rules: &Rules,
    body: &mut Body,
    uuid: &[u8; 16],
    hit: Option<&Hit>,
) -> Vec<Value> {
    let killed_by_player = body.mob.player_memory > 0;
    let looting = hit
        .and_then(|h| h.attacker.as_ref())
        .filter(|a| a.player)
        .and_then(|a| a.mainhand.as_ref())
        .and_then(|s| items::enchantment(s, "minecraft:looting"))
        .unwrap_or(0);
    let mut drops = Vec::new();
    for slot in Slot::ALL {
        let chance = living_mob::drop_chance(rules.living, &body.mob, slot);
        let Some(stack) = body.mob.equipment.get(slot) else {
            continue;
        };
        if chance == 0.0 {
            continue;
        }
        let preserve = chance > 1.0;
        let chance = if looting > 0 {
            f(chance + 0.01 * looting as f64)
        } else {
            chance
        };
        let vanishing = items::enchantment(stack, "minecraft:vanishing_curse").is_some();
        if vanishing || !(killed_by_player || preserve) {
            continue;
        }
        let stack = stack.clone();
        let draw = random(&mut body.mob, uuid).float();
        if (draw as f64) < chance {
            let stack = if preserve {
                stack
            } else {
                worn(rules, &mut body.mob, uuid, stack)
            };
            body.mob.equipment.set(slot, None);
            drops.push(stack);
        }
    }
    drops
}

/// A damageable item that drops off a dead mob is badly worn.
fn worn(rules: &Rules, mob: &mut super::model::Mob, uuid: &[u8; 16], mut stack: Value) -> Value {
    let max = items::component(&stack, "minecraft:max_damage")
        .and_then(Value::as_int)
        .or_else(|| items::item_id(&stack).and_then(|id| rules.living.item(id).max_damage));
    let unbreakable = items::component(&stack, "minecraft:unbreakable").is_some();
    if let Some(max) = max.filter(|&m| m > 0 && !unbreakable) {
        let r = random(mob, uuid);
        let inner = r.int((max - 3).max(1) as i32);
        let outer = r.int(1 + inner);
        items::put_component(
            &mut stack,
            "minecraft:damage",
            Value::Int(max - outer as i64),
        );
    }
    stack
}

/// `getBaseExperienceReward`: a chicken jockey's 10, a family's own, an
/// animal's one to three from its random, else the type's reward.
fn experience(
    rules: &Rules,
    ty: Type,
    family: &dyn Family,
    body: &mut Body,
    uuid: &[u8; 16],
) -> i32 {
    if body.entity_type == "minecraft:chicken"
        && body.data.get("jockey") == Some(&super::term::TRUE)
    {
        return 10;
    }
    if let Some(xp) = family.experience(body) {
        return xp;
    }
    if rules.facts.combat.mob_sounds(ty.id).animal {
        return 1 + random(&mut body.mob, uuid).int(3);
    }
    reward(rules, ty, body, uuid)
}

/// The type's reward (a baby zombie's two and a half times), plus one to
/// three for each worn or held item it would not keep unworn, in vanilla's
/// slot order from its random.
fn reward(rules: &Rules, ty: Type, body: &mut Body, uuid: &[u8; 16]) -> i32 {
    let reward = rules
        .facts
        .combat
        .experience
        .get(&ty.id)
        .copied()
        .unwrap_or(0);
    if reward == 0 {
        return 0;
    }
    let mut reward = if body.data.baby() == Some(true) {
        (reward as f64 * 2.5) as i32
    } else {
        reward
    };
    for slot in [
        Slot::Mainhand,
        Slot::Offhand,
        Slot::Feet,
        Slot::Legs,
        Slot::Chest,
        Slot::Head,
    ] {
        if body.mob.equipment.get(slot).is_some()
            && living_mob::drop_chance(rules.living, &body.mob, slot) <= 1.0
        {
            reward += 1 + random(&mut body.mob, uuid).int(3);
        }
    }
    reward
}
