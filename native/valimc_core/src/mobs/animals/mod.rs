//! Farm animals (VMC-081d), ported from `Valimc.Entity.Animal` (vanilla's
//! `AgeableMob` and `Animal`) and its modules: what every animal shares is
//! `Animal<S>`, a family (`Kind`) over its species `S` (`Species`, the
//! `Valimc.Entity.Animal` behaviour's callbacks): cows, mooshrooms, pigs,
//! sheep, chickens and rabbits.
//!
//! An animal's age, forced age, age lock, love and the player who caused it
//! are its data (`age`, `forced_age`, `age_locked`, `in_love`,
//! `love_cause`); a baby's age is negative and counts up, a parent's is
//! positive after breeding and counts down. Breeding, feeding and growing
//! draw on the mob's own random where vanilla's do; variants and colours on
//! the level's.
//!
//! Outside actions (`interact`): a player's item used on an animal runs the
//! species' own `mobInteract` (milking, shearing, stew), then
//! `Animal.mobInteract` (food: love for an adult, a tenth of its time for a
//! baby), `AgeableMob`'s golden dandelion, then the item's own use (dye).
//! `feed_love` and `feed_baby` are the scene's acts (`Animal.fall_in_love`,
//! `Animal.feed_baby`).

pub mod chicken;
pub mod cow;
pub mod mooshroom;
pub mod pig;
pub mod rabbit;
pub mod sheep;
pub mod variants;

use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::goals::move_to_block::MoveToBlock;
use crate::mobs::ai::hooks::{Hooks, Tag};
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::combat::{Event, Family, Hit, SoundKind, SoundRef};
use crate::mobs::facts::families::AnimalFact;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::interact::{Done, Hand, InteractEvent, Interaction, Outcome};
use crate::mobs::kinds::{Kind, Registered};
use crate::mobs::living::mob as living_mob;
use crate::mobs::model::{Body, FamilyData, MobMotion, NativeMob};
use crate::mobs::sensing::Uuid;
use crate::mobs::term::{Atom, Map, Value, NIL};

/// `@ageable`: the shared data of a fresh animal.
pub fn ageable() -> Vec<(Atom, Value)> {
    vec![
        (Atom::from_static("age"), Value::Int(0)),
        (Atom::from_static("forced_age"), Value::Int(0)),
        (Atom::from_static("age_locked"), Value::bool(false)),
        (Atom::from_static("in_love"), Value::Int(0)),
        (Atom::from_static("love_cause"), NIL),
    ]
}

/// A species: one animal module's own parts (`Valimc.Entity.Animal`'s
/// callbacks and the `Kind` hooks it overrides).
pub trait Species: Send + Sync + Sized + 'static {
    /// Its entity type.
    const TYPE: &'static str;
    /// The Elixir module.
    const MODULE: &'static str;

    /// `goals/0`.
    fn goals(&self, a: &Animal<Self>, facts: &MobFacts) -> Registered;

    /// `defaults/0`: its own data (beyond the ageable part), without draws.
    fn defaults(&self) -> Vec<(Atom, Value)>;

    /// `fields/1`: its own entity data fields `(field, value, default)`.
    fn fields(&self, a: &Animal<Self>, data: &FamilyData) -> Vec<(Atom, Value, Value)>;

    /// `offspring/2`: the child's own data, drawn from the parent's random,
    /// with its sensed partner's data.
    fn offspring(&self, a: &Animal<Self>, t: &mut Turn, partner: &FamilyData)
        -> Vec<(Atom, Value)>;

    /// `settle/1`: its part of `aiStep` after the shared one.
    fn settle(&self, _a: &Animal<Self>, _t: &mut Turn) {}

    /// `properties/1`: what its loot tables read of it.
    fn properties(&self, _data: &FamilyData) -> Vec<(String, String)> {
        Vec::new()
    }

    /// `interact/2`: its own `mobInteract`, before the shared one.
    fn interact(&self, _a: &Animal<Self>, _i: &mut Interaction) -> Outcome {
        Outcome::Pass
    }

    /// `use_item/2`: a held item's own use after the rest passed.
    fn use_item(&self, _a: &Animal<Self>, _i: &mut Interaction) -> Outcome {
        Outcome::Pass
    }

    /// `server_ai_step/1`: its own `customServerAiStep` in place of the
    /// shared one (true: it has one).
    fn server_ai_step(&self, _a: &Animal<Self>, _t: &mut Turn) -> bool {
        false
    }

    /// `spawn_part/2`: its part of `finalizeSpawn` before the shared one.
    fn spawn_part(&self, _a: &Animal<Self>, _t: &mut Turn, _reason: &Atom) {}

    /// `ate/1` (`Mob.ate`).
    fn ate(&self, _a: &Animal<Self>, _t: &mut Turn) {}

    /// `ambient_sound/1`; None: its type's.
    fn ambient_sound(&self, _a: &Animal<Self>, _t: &mut Turn) -> Option<Option<i32>> {
        None
    }

    /// `sound/2`: its own hurt or death sound.
    fn sound(&self, _a: &Animal<Self>, _body: &Body, _which: SoundKind) -> Option<SoundRef> {
        None
    }

    /// `Mob.new/1`'s motion (a rabbit's hop).
    fn motion(&self) -> MobMotion {
        MobMotion::default()
    }

    /// `playEatingSound` (a pig's): the sound, else none.
    fn eat_sound(&self, _data: &FamilyData) -> Option<i32> {
        None
    }

    /// `Hooks::block` of its own move-to-block goals (a rabbit's garden).
    fn block(
        &self,
        _a: &Animal<Self>,
        _t: &mut Turn,
        _tag: Tag,
        _cell: [i32; 3],
        _goal: &mut MoveToBlock,
    ) -> bool {
        false
    }
}

/// An animal family over species `S`.
pub struct Animal<S> {
    pub type_id: u16,
    pub types: [&'static str; 1],
    pub fact: AnimalFact,
    pub species: S,
    /// Protocol ids of what the shared rules use.
    pub golden_dandelion: Option<i32>,
    pub tropical_fish_bucket: Option<i32>,
    pub water_bucket: Option<i32>,
    pub age_lockable: bool,
}

impl<S: Species> Animal<S> {
    pub fn new(facts: &MobFacts, species: S) -> Result<Animal<S>, String> {
        let type_id = facts
            .entities
            .id(S::TYPE)
            .ok_or_else(|| format!("unknown animal {}", S::TYPE))?;
        let fact = facts
            .animal
            .animals
            .get(&type_id)
            .cloned()
            .ok_or_else(|| format!("no animal facts for {}", S::TYPE))?;
        Ok(Animal {
            type_id,
            types: [S::TYPE],
            fact,
            species,
            golden_dandelion: item(facts, "minecraft:golden_dandelion"),
            tropical_fish_bucket: item(facts, "minecraft:tropical_fish_bucket"),
            water_bucket: item(facts, "minecraft:water_bucket"),
            age_lockable: !facts.entity_tag(type_id, "cannot_be_age_locked"),
        })
    }

    /// `Animal.data/1`: a fresh animal's data.
    pub fn data_fields(&self) -> Vec<(Atom, Value)> {
        let mut fields = ageable();
        fields.extend(self.species.defaults());
        fields
    }
}

/// A protocol item id by name.
pub fn item(facts: &MobFacts, name: &str) -> Option<i32> {
    facts.items.names.id(name).map(|id| id as i32)
}

/// The every farm animal (each `Valimc.Entity.Animals.*` module).
pub fn kinds(facts: &MobFacts) -> Result<Vec<Box<dyn Kind>>, String> {
    Ok(vec![
        Box::new(Animal::new(facts, cow::Cow::new(facts)?)?),
        Box::new(Animal::new(facts, mooshroom::Mooshroom::new(facts)?)?),
        Box::new(Animal::new(facts, pig::Pig::new(facts)?)?),
        Box::new(Animal::new(facts, sheep::Sheep::new(facts)?)?),
        Box::new(Animal::new(facts, chicken::Chicken::new(facts)?)?),
        Box::new(Animal::new(facts, rabbit::Rabbit::new(facts)?)?),
    ])
}

// ## Data

/// An animal's age.
pub fn age(data: &FamilyData) -> i64 {
    data.age().unwrap_or(0)
}

/// `canAgeUp`: a baby whose age is not locked.
pub fn can_age_up(data: &FamilyData) -> bool {
    age(data) < 0 && !data.age_locked().unwrap_or(false)
}

/// `ageUp(seconds, forced)`: older by `seconds` (never past adult); a
/// forced ageing counts toward the forced age and starts the particle
/// timer. The timer after it from `timer`.
pub fn age_up(data: &mut FamilyData, seconds: i64, forced: bool, timer: i32) -> i32 {
    let old = age(data);
    let new = (old + seconds * 20).min(0);
    data.set_age(new);
    let mut timer = timer;
    if forced {
        let forced_age = data.forced_age().unwrap_or(0) + (new - old);
        data.set_forced_age(forced_age);
        if timer == 0 {
            timer = 40;
        }
    }
    if age(data) == 0 {
        let forced_age = data.forced_age().unwrap_or(0);
        data.set_age(forced_age);
    }
    timer
}

/// `getSpeedUpSecondsWhenFeeding`: a tenth of the baby's time left, in
/// seconds.
pub fn speed_up_seconds(ticks: i64) -> i64 {
    use crate::mobs::ai::fmath::f;
    f((ticks / 20) as f64 * f(0.1)) as i64
}

/// `setInLove(player)`: 600 ticks, caused by `player` (or its old cause).
pub fn set_in_love(data: &mut FamilyData, player: Option<Uuid>) {
    data.set_in_love(600);
    if let Some(p) = player {
        data.set_love_cause(Value::Binary(p.to_vec()));
    }
}

/// `canFallInLove`.
pub fn can_fall_in_love(data: &FamilyData) -> bool {
    data.in_love().unwrap_or(0) <= 0
}

/// What breeding leaves in the partner's data (`setAge(6000)`,
/// `resetLove`).
pub fn bred(data: &mut FamilyData) {
    data.set_age(6000);
    data.set_in_love(0);
}

fn mind_timer(mob: &NativeMob, forced: bool) -> Option<i32> {
    let s = mob.body.mob.ai.as_ref()?.state.as_ref()?;
    Some(if forced {
        s.forced_age_timer
    } else {
        s.age_lock_timer
    })
}

fn put_mind_timer(mob: &mut NativeMob, forced: bool, timer: i32) {
    if let Some(s) = mob.body.mob.ai.as_mut().and_then(|m| m.state.as_mut()) {
        if forced {
            s.forced_age_timer = timer;
        } else {
            s.age_lock_timer = timer;
        }
    }
}

/// `Animal.fall_in_love/2`: love a player (`player`) fed; its hearts event.
pub fn feed_love(mob: &mut NativeMob, player: Option<Uuid>) -> Vec<InteractEvent> {
    set_in_love(&mut mob.body.data, player);
    vec![InteractEvent::Entity(18)]
}

/// `Animal.feed_baby/1`: a baby fed is a tenth of its time older, and its
/// happy particles' timer starts.
pub fn feed_baby(mob: &mut NativeMob) {
    let timer = mind_timer(mob, true).unwrap_or(0);
    let seconds = speed_up_seconds(-age(&mob.body.data));
    let timer = age_up(&mut mob.body.data, seconds, true, timer);
    put_mind_timer(mob, true, timer);
}

/// `Animal.convert/2` of a body into a fresh `into` (`Mob.convertTo`
/// single): facing and moving as it did, keeping its age, effects,
/// absorption, fire, name, persistence, AI flag and its last player hurt.
pub fn convert(from: &Body, mut into: Body) -> Body {
    if let Some(a) = from.data.age() {
        into.data.set_age(a);
    }
    if let Some(a) = from.data.forced_age() {
        into.data.set_forced_age(a);
    }
    let old = &from.mob;
    into.mob.living.effects = old.living.effects.clone();
    into.mob.living.absorption = old.living.absorption;
    into.mob.living.fire_ticks = old.living.fire_ticks;
    into.mob.no_ai = old.no_ai;
    into.mob.persistent = old.persistent;
    into.mob.hurt_by_player = old.hurt_by_player;
    into.mob.player_memory = old.player_memory;
    into.mob.left_handed = old.left_handed;
    into.yaw = from.yaw;
    into.pitch = from.pitch;
    into.head_yaw = from.head_yaw;
    into.velocity = from.velocity;
    into.on_ground = from.on_ground;
    into.custom_name = from.custom_name.clone();
    into
}

// ## The tick

impl<S: Species> Animal<S> {
    /// `Animal.ai_step/1` (`customServerAiStep`): only an adult stays in
    /// love; a species with its own step runs that instead.
    fn ai_step(&self, t: &mut Turn) {
        if !self.species.server_ai_step(self, t) && age(t.data()) != 0 {
            t.mob.body.data.set_in_love(0);
        }
    }

    /// `Animal.settle/1`: `AgeableMob.aiStep` and `Animal.aiStep` after the
    /// move, then the species' own part.
    fn settle(&self, t: &mut Turn) {
        settle_ageable(t);
        if age(t.data()) != 0 {
            t.mob.body.data.set_in_love(0);
        }
        let love = t.data().in_love().unwrap_or(0);
        if love > 0 {
            let love = love - 1;
            t.mob.body.data.set_in_love(love);
            if love % 10 == 0 {
                hearts(t);
            }
        }
        self.species.settle(self, t);
    }

    /// `Animal.breed/2`: the child's data from the parent's random (a baby
    /// where the parent stands), both parents' age 6,000 and love gone, the
    /// hearts event, and an orb of 1 to 7 while mobs drop loot.
    fn breed(&self, t: &mut Turn, partner: &Seen) {
        let partner_data = t
            .sensing
            .mob(&partner.uuid())
            .and_then(|m| m.extra.data.clone())
            .unwrap_or_else(FamilyData::empty);
        let own = self.species.offspring(self, t, &partner_data);
        let mut child: Vec<(Atom, Value)> = self.data_fields();
        for (k, v) in own {
            match child.iter_mut().find(|(ck, _)| *ck == k) {
                Some(slot) => slot.1 = v,
                None => child.push((k, v)),
            }
        }
        // A chick's laying time is its own random's (the owner's, as the
        // Elixir's `:rand`): no draw of the parent's.
        if let Some(slot) = child.iter_mut().find(|(k, _)| k.as_str() == "egg_time") {
            slot.1 = Value::Int(6000 + (t.next_seed().rem_euclid(6000)));
        }
        if let Some(slot) = child.iter_mut().find(|(k, _)| k.as_str() == "age") {
            slot.1 = Value::Int(-24_000);
        }
        let data = Map::from_pairs(
            child
                .into_iter()
                .map(|(k, v)| (Value::Atom(k), v))
                .collect(),
        )
        .map(Value::Map)
        .unwrap_or(NIL);
        bred(&mut t.mob.body.data);
        let at = t.pos();
        t.effect(Effect::Offspring {
            type_id: self.type_id,
            data,
            at,
        });
        t.effect(Effect::Bred(partner.reference));
        t.effect(Effect::Event(18));
        if t.level.rules.mob_drops {
            let n = t.int(7);
            t.effect(Effect::Orb { value: n + 1, at });
        }
    }
}

/// `settle_ageable/1` (`AgeableMob.aiStep`): the forced-age particles'
/// draws, the age counting toward 0, the age-lock particles' draws.
pub fn settle_ageable(t: &mut Turn) {
    let timer = t.mind.forced_age_timer;
    if timer > 0 {
        if timer % 4 == 0 {
            random_point(t);
        }
        t.mind.forced_age_timer = timer - 1;
    }
    if living_mob::alive(&t.mob.body.mob) {
        let data = &mut t.mob.body.data;
        let a = age(data);
        if can_age_up(data) {
            data.set_age(a + 1);
        } else if a > 0 {
            data.set_age(a - 1);
        }
    }
    let timer = t.mind.age_lock_timer;
    if timer > 0 {
        if timer % 2 == 0 {
            random_point(t);
        }
        t.mind.age_lock_timer = timer - 1;
    }
}

// `addParticle(HEART, ...)`: three gaussian speeds, then a random point.
fn hearts(t: &mut Turn) {
    t.gaussian();
    t.gaussian();
    t.gaussian();
    random_point(t);
}

// `getRandomX(1.0)`, `getRandomY()`, `getRandomZ(1.0)`.
fn random_point(t: &mut Turn) {
    t.double();
    t.double();
    t.double();
}

// ## The family

impl<S: Species> Hooks for Animal<S> {
    fn voice(&self, _type_id: u16, data: &FamilyData) -> f32 {
        if age(data) < 0 {
            1.5
        } else {
            1.0
        }
    }

    fn breed(&self, t: &mut Turn, _breeding: Option<Tag>, partner: &Seen) {
        Animal::breed(self, t, partner);
    }

    fn ate(&self, t: &mut Turn) {
        self.species.ate(self, t);
    }

    fn block(&self, t: &mut Turn, tag: Tag, cell: [i32; 3], goal: &mut MoveToBlock) -> bool {
        self.species.block(self, t, tag, cell, goal)
    }
}

impl<S: Species> Family for Animal<S> {
    fn data(&self) -> FamilyData {
        FamilyData::new(self.data_fields()).unwrap_or_else(FamilyData::empty)
    }

    fn motion(&self) -> MobMotion {
        self.species.motion()
    }

    fn hurt(&self, body: &mut Body, _hit: &Hit, _events: &mut Vec<Event>) {
        body.data.set_in_love(0);
    }

    fn actually_hurt(&self, data: &mut FamilyData) {
        data.set_in_love(0);
    }

    fn voice(&self, body: &Body) -> f32 {
        Hooks::voice(self, self.type_id, &body.data)
    }

    fn loot_properties(&self, body: &Body) -> Vec<(String, String)> {
        self.species.properties(&body.data)
    }

    fn sound(&self, body: &Body, which: SoundKind) -> Option<SoundRef> {
        self.species.sound(self, body, which)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let data = &body.data;
        let mut out = vec![
            (
                Atom::from_static("ageable_baby"),
                Value::bool(age(data) < 0),
                Value::bool(false),
            ),
            (
                Atom::from_static("age_locked"),
                Value::bool(data.age_locked().unwrap_or(false)),
                Value::bool(false),
            ),
        ];
        out.extend(self.species.fields(self, data));
        out
    }

    fn dimensions(&self, body: &Body) -> Option<[f32; 3]> {
        (age(&body.data) < 0).then_some(self.fact.baby)
    }
}

impl<S: Species> Kind for Animal<S> {
    fn module(&self) -> &'static str {
        S::MODULE
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, facts: &MobFacts, _type_id: u16) -> Registered {
        self.species.goals(self, facts)
    }

    fn animal(&self) -> bool {
        true
    }

    fn leashable(&self) -> bool {
        true
    }

    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        self.species.spawn_part(self, t, reason);
        crate::mobs::ai::spawn::mob(t, reason);
    }

    fn custom_step(&self, t: &mut Turn) {
        self.ai_step(t);
    }

    fn after_ai(&self, t: &mut Turn) {
        self.settle(t);
    }

    fn ambient_sound(&self, t: &mut Turn) -> Option<i32> {
        match self.species.ambient_sound(self, t) {
            Some(sound) => sound,
            None => {
                let name = t.facts.ambient_sound.as_deref()?;
                t.level.facts.sounds.id(name)
            }
        }
    }

    fn interact(&self, i: &mut Interaction) -> Outcome {
        if !living_mob::alive(&i.mob.body.mob) {
            return Outcome::Pass;
        }
        match self.species.interact(self, i) {
            Outcome::Pass => {}
            other => return other,
        }
        match self.feed(i) {
            Outcome::Pass => {}
            other => return other,
        }
        match self.dandelion(i) {
            Outcome::Pass => {}
            other => return other,
        }
        self.species.use_item(self, i)
    }

    fn fresh_data(&self) -> Vec<(Atom, Value)> {
        self.data_fields()
    }
}

// ## Interactions

impl<S: Species> Animal<S> {
    /// `Animal.mobInteract`: food makes an adult fall in love (one past
    /// breeding or in love ignores it) or ages a baby on.
    fn feed(&self, i: &mut Interaction) -> Outcome {
        let Some(id) = i.request.item_id() else {
            return Outcome::Pass;
        };
        if !i.rules.facts.animal.food(self.type_id, Some(id)) {
            return Outcome::Pass;
        }
        let data = &i.mob.body.data;
        if age(data) == 0 && can_fall_in_love(data) {
            let player = i.request.player;
            let mut events = feed_love(i.mob, player);
            events.extend(self.eating_sound(i));
            Outcome::Done(Done {
                hand: Some(self.fed(id)),
                swing: true,
                events,
                ..Done::default()
            })
        } else if can_age_up(data) {
            feed_baby(i.mob);
            let events = self.eating_sound(i);
            Outcome::Done(Done {
                hand: Some(self.fed(id)),
                events,
                ..Done::default()
            })
        } else {
            Outcome::Pass
        }
    }

    // `usePlayerItem`: an axolotl's bucket of fish leaves a water bucket,
    // other food is used up.
    fn fed(&self, id: i32) -> Hand {
        match (self.tropical_fish_bucket, self.water_bucket) {
            (Some(fish), Some(water)) if fish == id => {
                Hand::Fill(crate::mobs::living::items::new_stack(water, 1, None))
            }
            _ => Hand::Use(1),
        }
    }

    // `playEatingSound`: a pig's (its sound variant's, at its voice pitch).
    fn eating_sound(&self, i: &mut Interaction) -> Vec<InteractEvent> {
        let Some(sound) = self.species.eat_sound(&i.mob.body.data) else {
            return Vec::new();
        };
        let base = if age(&i.mob.body.data) < 0 { 1.5 } else { 1.0 };
        let pitch = i.random().voice_pitch(base) as f64;
        let volume = i.rules.facts.ai.mob(self.type_id).map_or(1.0, |a| a.volume);
        vec![InteractEvent::Sound {
            sound,
            source: "neutral",
            volume,
            pitch,
        }]
    }

    /// `AgeableMob.mobInteract`: a golden dandelion locks a baby's age (or
    /// unlocks it), back to a newborn's, unless its type cannot be locked
    /// or it was just used.
    fn dandelion(&self, i: &mut Interaction) -> Outcome {
        if i.request.item_id().is_none() || i.request.item_id() != self.golden_dandelion {
            return Outcome::Pass;
        }
        let timer = mind_timer(i.mob, false).unwrap_or(0);
        if !(age(&i.mob.body.data) < 0 && timer == 0 && self.age_lockable) {
            return Outcome::Pass;
        }
        let locked = !i.mob.body.data.age_locked().unwrap_or(false);
        i.mob.body.data.set_age_locked(locked);
        i.mob.body.data.set_age(-24_000);
        if locked {
            i.mob.body.mob.persistent = true;
        }
        put_mind_timer(i.mob, false, 40);
        let name = if locked {
            "minecraft:item.golden_dandelion.use"
        } else {
            "minecraft:item.golden_dandelion.unuse"
        };
        Outcome::Done(Done {
            hand: Some(Hand::Use(1)),
            events: vec![InteractEvent::SoundBlock {
                sound: i.sound(name),
                source: "player",
                volume: 1.0,
                pitch: 1.0,
            }],
            ..Done::default()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn data(age: i64) -> FamilyData {
        FamilyData::new(vec![
            (Atom::new("age"), Value::Int(age)),
            (Atom::new("forced_age"), Value::Int(0)),
            (Atom::new("age_locked"), Value::bool(false)),
            (Atom::new("in_love"), Value::Int(0)),
            (Atom::new("love_cause"), NIL),
        ])
        .unwrap()
    }

    #[test]
    fn feeding_ages_a_baby_by_a_tenth() {
        let mut d = data(-24_000);
        let timer = age_up(&mut d, speed_up_seconds(24_000), true, 0);
        assert_eq!(age(&d), -21_600);
        assert_eq!(d.forced_age(), Some(2_400));
        assert_eq!(timer, 40);
        let mut d = data(-100);
        assert_eq!(age_up(&mut d, 10, true, 3), 3);
        // A baby forced to adulthood takes its forced age as its age.
        assert_eq!((age(&d), d.forced_age()), (100, Some(100)));
    }

    #[test]
    fn breeding_resets_love() {
        let mut d = data(0);
        set_in_love(&mut d, None);
        assert_eq!(d.in_love(), Some(600));
        assert!(!can_fall_in_love(&d));
        bred(&mut d);
        assert_eq!((d.age(), d.in_love()), (Some(6000), Some(0)));
    }
}
