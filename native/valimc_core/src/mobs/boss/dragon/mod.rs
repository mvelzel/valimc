//! The ender dragon (`Valimc.Entity.Dragon` reads its row): a boss with no
//! goals whose whole tick is its own actor (`actor`), run by its owner in
//! place of the ordinary think, travel and vitals.
//!
//! The actor keeps its phases, flight, crystal and death clock in the body's
//! `brain` field as its record's term (`codec`). Each tick the owner gives
//! an `Arena` (the fight's podium, crystal count and crystal bodies, the
//! mobs it may hit, the kill so far, the arena's column heights and a fresh
//! flame uuid) and the group's players; `environment` makes the actor's
//! `Env` from them. Its outputs are event and effect terms (`DragonEvent`,
//! `DragonEffect`) the owner applies.
//!
//! The family (`Dragon`) gives the living rules its multipart damage:
//! a hit on a part other than the head (or a hit with no part) takes a
//! quarter plus up to one; the sitting phases turn away and ignite arrows,
//! count the damage they take and take off past a quarter of the maximum
//! health; a killing blow in flight leaves it at one health, dying.

pub mod actor;
pub mod codec;
pub mod facts;
pub mod flight;
pub mod paths;
pub mod phases;

#[cfg(test)]
mod tests;

pub use actor::Actor;
pub use facts::DragonFacts;

use crate::mobs::ai::hooks::Hooks;
use crate::mobs::combat::{Event, Family, Hit, Outcome};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Emission, Kind, KindMotion, Registered};
use crate::mobs::level::{Level, AIR};
use crate::mobs::model::{Body, FamilyData, Mind, Mob, NativeMob};
use crate::mobs::monsters::{fields, value};
use crate::mobs::sensing::{GameMode, Kind as RefKind, Ref, SensedPlayer};
use crate::mobs::term::{Atom, Map, Value};
use flight::{dot, sub};
use paths::Graph;

pub const DRAGON: &str = "minecraft:ender_dragon";

/// The projectiles a sitting dragon turns away and ignites.
const ARROWS: [&str; 4] = [
    "minecraft:arrow",
    "minecraft:spectral_arrow",
    "minecraft:trident",
    "minecraft:wind_charge",
];

/// A combat-eligible player as the phases keep it (`%{id, position,
/// height}`).
#[derive(Clone, Debug, PartialEq)]
pub struct Player {
    pub id: i64,
    pub position: [f64; 3],
    pub height: f64,
}

impl Player {
    /// Its term (`attack`).
    pub fn term(&self) -> Value {
        Value::Map(Map::from_atoms([
            ("id", Value::Int(self.id)),
            ("position", Value::vec3(self.position)),
            ("height", Value::Float(self.height)),
        ]))
    }
}

/// An end crystal of the group (`crystal_bodies`).
#[derive(Clone, Debug, PartialEq)]
pub struct Crystal {
    pub uuid: [u8; 16],
    pub position: [f64; 3],
    pub bbox: [f64; 6],
}

/// A mob the dragon may hit (`arena.targets`' sensed row): where it is now,
/// its own box where it has one, and whether it was hurt by a mob within two
/// ticks (`recent_mob_hurt`).
#[derive(Clone, Debug, PartialEq)]
pub struct MobTarget {
    pub uuid: [u8; 16],
    pub position: [f64; 3],
    pub width: f64,
    pub height: f64,
    pub bbox: Option<[f64; 6]>,
    pub recent: bool,
}

/// What the dragon's wings and head may touch (`env.targets`).
#[derive(Clone, Debug, PartialEq)]
pub struct Target {
    pub target: Ref,
    pub position: [f64; 3],
    pub recent: bool,
    pub bbox: [f64; 6],
}

/// What its owner gives a tick (`world.dragon`).
pub struct Arena<'a> {
    /// A column's `MOTION_BLOCKING_NO_LEAVES` height (`Arena.height/4`),
    /// read when its brain has no graph yet.
    pub height: &'a dyn Fn(i64, i64) -> i64,
    pub podium: [i64; 3],
    /// The fight's alive crystals (None: no fight).
    pub crystals: Option<i64>,
    pub crystal_bodies: Vec<Crystal>,
    pub mobs: Vec<MobTarget>,
    /// The fight was won before (`previous_kill`; no fight counts as won).
    pub previous_kill: bool,
    /// The uuid a breath started this tick takes.
    pub flame_uuid: [u8; 16],
}

/// The actor's inputs (`Actor.environment/3`'s map).
pub struct Env<'a> {
    pub facts: &'a DragonFacts,
    pub level: &'a Level<'a>,
    pub graph: Graph,
    pub podium: [i64; 3],
    pub crystals: Option<i64>,
    pub crystal_bodies: &'a [Crystal],
    pub previous_kill: bool,
    pub flame_uuid: [u8; 16],
    /// The combat-eligible players.
    pub players: Vec<Player>,
    /// Every player's id and eye, for sight.
    pub sight: Vec<(i64, [f64; 3])>,
    /// The dragon's eye as its tick began.
    pub eye: [f64; 3],
    pub targets: Vec<Target>,
    /// Its flight hit a wall last tick.
    pub wall: bool,
    /// It collided (`horizontalCollision`, `verticalCollision`): never in
    /// play, where it does not move by collision; an oracle's scene sets it.
    pub collision: bool,
    /// An oracle's fixed answer to whether it sees a player (its scene's
    /// `visible`); None: by line of sight.
    pub sees: Option<bool>,
}

fn eligible(p: &SensedPlayer) -> bool {
    p.alive && !matches!(p.mode, GameMode::Creative | GameMode::Spectator) && !p.invulnerable
}

/// `Actor.environment/3`: the actor's inputs from the arena and the group's
/// players.
pub fn environment<'a>(
    facts: &'a DragonFacts,
    mob_facts: &MobFacts,
    level: &'a Level<'a>,
    mob: &NativeMob,
    arena: &'a Arena<'a>,
    players: &[SensedPlayer],
) -> Env<'a> {
    let kept = mob
        .body
        .data
        .get("brain")
        .and_then(Value::as_map)
        .and_then(|m| m.get_atom("graph"))
        .filter(|g| !g.is_nil())
        .and_then(codec::graph);
    let graph = kept.unwrap_or_else(|| paths::graph(facts, arena.height));
    let eye_height = crate::mobs::living::mob::Type::of(mob_facts, &mob.body.entity_type)
        .map_or(0.0, |t| t.facts.eye_height);
    let [x, y, z] = mob.position;
    let mut targets: Vec<Target> = arena
        .mobs
        .iter()
        .filter(|m| m.uuid != mob.uuid)
        .map(|m| {
            let [tx, ty, tz] = m.position;
            let half = m.width / 2.0;
            Target {
                target: Ref {
                    kind: RefKind::Mob,
                    uuid: m.uuid,
                },
                position: m.position,
                recent: m.recent,
                bbox: m.bbox.unwrap_or([
                    tx - half,
                    ty,
                    tz - half,
                    tx + half,
                    ty + m.height,
                    tz + half,
                ]),
            }
        })
        .collect();
    targets.extend(
        players
            .iter()
            .filter(|p| {
                p.uuid != mob.uuid && !matches!(p.mode, GameMode::Creative | GameMode::Spectator)
            })
            .map(|p| {
                let [tx, ty, tz] = p.position;
                let half = p.width / 2.0;
                Target {
                    target: Ref {
                        kind: RefKind::Player,
                        uuid: p.uuid,
                    },
                    position: p.position,
                    recent: false,
                    bbox: [
                        tx - half,
                        ty,
                        tz - half,
                        tx + half,
                        ty + p.height,
                        tz + half,
                    ],
                }
            }),
    );
    Env {
        facts,
        level,
        graph,
        podium: arena.podium,
        crystals: arena.crystals,
        crystal_bodies: &arena.crystal_bodies,
        previous_kill: arena.previous_kill,
        flame_uuid: arena.flame_uuid,
        players: players
            .iter()
            .filter(|p| eligible(p))
            .map(|p| Player {
                id: p.id as i64,
                position: p.position,
                height: p.height,
            })
            .collect(),
        sight: players
            .iter()
            .map(|p| {
                let [px, py, pz] = p.position;
                (p.id as i64, [px, py + p.eye, pz])
            })
            .collect(),
        eye: [x, y + eye_height, z],
        targets,
        wall: false,
        collision: false,
        sees: None,
    }
}

impl Env<'_> {
    /// `visible`: nothing blocks the dragon's eye from the player's.
    pub fn visible(&self, player: &Player) -> bool {
        if let Some(sees) = self.sees {
            return sees;
        }
        match self.sight.iter().find(|(id, _)| *id == player.id) {
            Some((_, eye)) => crate::mobs::sensing::sight::clear(self.level, self.eye, *eye),
            None => false,
        }
    }

    /// `nearest/5`: the eligible player nearest `at` within `range` (and
    /// `vertical` up or down), seen where `sight`; the first of equals.
    pub fn nearest(
        &self,
        at: [f64; 3],
        range: Option<f64>,
        sight: bool,
        vertical: Option<f64>,
    ) -> Option<Player> {
        let distance = |p: &Player| {
            let d = sub(p.position, at);
            dot(d, d)
        };
        let mut best: Option<(&Player, f64)> = None;
        for p in &self.players {
            let d = distance(p);
            if range.is_some_and(|r| d > r * r)
                || vertical.is_some_and(|v| (p.position[1] - at[1]).abs() > v)
                || (sight && !self.visible(p))
            {
                continue;
            }
            if best.is_none_or(|(_, b)| d < b) {
                best = Some((p, d));
            }
        }
        best.map(|(p, _)| p.clone())
    }

    /// Not air, and readable (`solid`).
    fn solid(&self, p: [i32; 3]) -> bool {
        self.level.block(p).is_some() && !self.level.air(p)
    }

    /// `flame_floor/5`: down from `y` to the first solid block, or the
    /// start where there is none above zero.
    pub fn flame_floor(&self, x: f64, mut y: f64, z: f64, initial: f64) -> f64 {
        loop {
            if y < 0.0 {
                return initial;
            }
            if self.solid([x.floor() as i32, y.floor() as i32, z.floor() as i32]) {
                return y;
            }
            y -= 1.0;
        }
    }

    /// `BlockFacts.air?/1` of a state.
    pub fn air_state(&self, state: u16) -> bool {
        self.level.physics.flags(state) >> AIR & 1 == 1
    }
}

/// What a tick shows (`events`).
#[derive(Clone, Debug, PartialEq)]
pub enum DragonEvent {
    /// Its ambient growl at `pitch`.
    Ambient { pitch: f64 },
    /// A death explosion particle.
    Particles { name: &'static str, at: [f64; 3] },
}

impl DragonEvent {
    /// The Elixir's event term.
    pub fn value(&self) -> Value {
        match self {
            DragonEvent::Ambient { pitch } => Value::Tuple(vec![
                Value::atom("sound"),
                Value::Binary(b"minecraft:entity.ender_dragon.ambient".to_vec()),
                Value::Binary(b"hostile".to_vec()),
                Value::Float(5.0),
                Value::Float(*pitch),
                Value::Int(0),
            ]),
            DragonEvent::Particles { name, at } => Value::Tuple(vec![
                Value::atom("particles"),
                Value::Binary(name.as_bytes().to_vec()),
                Value::vec3(*at),
                Value::vec3([0.0; 3]),
                Value::Float(0.0),
                Value::Int(1),
            ]),
        }
    }
}

/// What a tick asks of its owner (`effects`).
#[derive(Clone, Debug, PartialEq)]
pub enum DragonEffect {
    /// `{:level_event, cell, kind, data}`: a fireball's sound (1017), a
    /// wall broken (2008).
    LevelEvent {
        cell: [i32; 3],
        kind: i32,
        data: i32,
    },
    /// A wing's push (and hit) or a head's bite.
    Contact {
        target: Ref,
        push: [f64; 3],
        amount: f64,
        wing: bool,
    },
    /// A block its body broke through, with the state it broke.
    Break {
        cell: [i32; 3],
        state: u16,
    },
    /// A phase's request passed on (`:scan_crystals`, `{:health, v}`,
    /// `{:fireball, at, direction}`).
    ScanCrystals,
    Health(f64),
    Fireball {
        at: [f64; 3],
        direction: [f64; 3],
    },
    /// Its breath begins (an area cloud of `uuid`).
    Flame {
        uuid: [u8; 16],
        at: [f64; 3],
    },
    /// Its breath ends (the cloud, if it knew one).
    EndFlame(Option<Vec<u8>>),
    /// Experience orbs worth `amount`.
    Xp {
        amount: i64,
        at: [f64; 3],
    },
    /// `{:global_event, id}`.
    GlobalEvent(i32),
    /// The fight is won.
    Killed,
    /// It is removed.
    Discard,
}

impl DragonEffect {
    /// The Elixir's effect term.
    pub fn value(&self) -> Value {
        let ref_value = |r: &Ref| {
            let kind = match r.kind {
                RefKind::Player => "player",
                RefKind::Mob => "mob",
                RefKind::Item => "item",
            };
            Value::tuple([Value::atom(kind), Value::Binary(r.uuid.to_vec())])
        };
        let cell = |c: &[i32; 3]| Value::ivec3([c[0] as i64, c[1] as i64, c[2] as i64]);
        match self {
            DragonEffect::LevelEvent {
                cell: c,
                kind,
                data,
            } => Value::Tuple(vec![
                Value::atom("level_event"),
                cell(c),
                Value::Int(*kind as i64),
                Value::Int(*data as i64),
            ]),
            DragonEffect::Contact {
                target,
                push,
                amount,
                wing,
            } => Value::Tuple(vec![
                Value::atom("dragon_contact"),
                ref_value(target),
                Value::vec3(*push),
                Value::Float(*amount),
                Value::bool(*wing),
            ]),
            DragonEffect::Break { cell: c, state } => Value::Tuple(vec![
                Value::atom("dragon_break"),
                cell(c),
                Value::Int(*state as i64),
            ]),
            DragonEffect::ScanCrystals => Value::atom("scan_crystals"),
            DragonEffect::Health(v) => Value::tuple([Value::atom("health"), Value::Float(*v)]),
            DragonEffect::Fireball { at, direction } => Value::Tuple(vec![
                Value::atom("fireball"),
                Value::vec3(*at),
                Value::vec3(*direction),
            ]),
            DragonEffect::Flame { uuid, at } => Value::Tuple(vec![
                Value::atom("dragon_flame"),
                Value::Binary(uuid.to_vec()),
                Value::vec3(*at),
            ]),
            DragonEffect::EndFlame(uuid) => Value::tuple([
                Value::atom("dragon_end_flame"),
                Value::or_nil(uuid.clone(), Value::Binary),
            ]),
            DragonEffect::Xp { amount, at } => Value::Tuple(vec![
                Value::atom("dragon_xp"),
                Value::Int(*amount),
                Value::vec3(*at),
            ]),
            DragonEffect::GlobalEvent(id) => {
                Value::tuple([Value::atom("global_event"), Value::Int(*id as i64)])
            }
            DragonEffect::Killed => Value::atom("dragon_killed"),
            DragonEffect::Discard => Value::atom("discard"),
        }
    }
}

/// `Dragon.timers/1` (`Body.tick/1` of a dragon): its portal cooldown and
/// living timers, without an ordinary mob's poof or removal: its death actor
/// ends it.
pub fn timers(body: &mut Body) {
    if body.portal_cooldown > 0 {
        body.portal_cooldown -= 1;
    }
    crate::mobs::living::mob::tick(&mut body.mob);
}

/// `Actor.recent?/1` of a mob the dragon touches: hurt (by a mob, as its
/// mind keeps it) within two ticks, or within its first two ticks.
pub fn recent(mob: &Mob) -> bool {
    match mob.ai.as_ref().and_then(|m: &Mind| m.state.as_ref()) {
        Some(s) => match s.hurt_by {
            Some((_, at)) => at >= s.tick - 2,
            None => s.tick <= 2,
        },
        None => false,
    }
}

/// The dragon family's damage and body rules (`Valimc.Entity.Dragon`).
pub struct Dragon {
    types: [&'static str; 1],
    /// Each phase's sitting flag.
    sitting: Vec<bool>,
    ambient_interval: i32,
    /// By damage type: `always_hurts_ender_dragons`, `is_fire`, `is_fall`.
    always: Vec<bool>,
    fire: Vec<bool>,
    fall: Vec<bool>,
    /// Its type is fire immune, fall damage immune.
    fire_immune: bool,
    fall_immune: bool,
}

impl Dragon {
    pub fn new(facts: &MobFacts) -> Dragon {
        let dragon = facts.dragon.as_ref();
        let types = facts.damage_types.types.len();
        let tagged = |tag: &str| {
            (0..types)
                .map(|id| facts.damage_tag(id as u16, tag))
                .collect::<Vec<_>>()
        };
        let id = facts.entities.id(DRAGON);
        Dragon {
            types: [DRAGON],
            sitting: dragon.map_or_else(Vec::new, |d| d.phases.iter().map(|p| p.sitting).collect()),
            ambient_interval: dragon.map_or(0, |d| d.ambient_interval as i32),
            always: tagged("minecraft:always_hurts_ender_dragons"),
            fire: tagged("minecraft:is_fire"),
            fall: tagged("minecraft:is_fall"),
            fire_immune: id
                .and_then(|id| facts.entities.get(id))
                .is_some_and(|t| t.fire_immune),
            fall_immune: id.is_some_and(|id| facts.entity_tag(id, "minecraft:fall_damage_immune")),
        }
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[
            ("phase", Value::Int(10)),
            ("sitting_damage", Value::Float(0.0)),
            ("death_time", Value::Int(0)),
            ("brain", Value::atom("nil")),
            ("aged_tick", Value::atom("nil")),
        ])
    }

    fn phase(body: &Body) -> i64 {
        body.data.get("phase").and_then(Value::as_int).unwrap_or(10)
    }

    /// `sitting?/1`.
    fn sitting(&self, body: &Body) -> bool {
        usize::try_from(Dragon::phase(body))
            .ok()
            .and_then(|p| self.sitting.get(p))
            .copied()
            .unwrap_or(false)
    }

    fn tag(tags: &[bool], source: u16) -> bool {
        tags.get(source as usize).copied().unwrap_or(false)
    }

    /// `ignites?/2`: a podium phase turns away and ignites arrows, tridents
    /// and wind charges.
    pub fn ignites(body: &Body, hit: &Hit) -> bool {
        matches!(Dragon::phase(body), 5..=7)
            && hit
                .direct
                .as_ref()
                .is_some_and(|d| ARROWS.contains(&d.entity_type.as_str()))
    }

    /// The part's own `isInvulnerableToBase` before it forwards a hit.
    fn part_immune(&self, hit: &Hit) -> bool {
        hit.dragon_part.is_some()
            && ((Dragon::tag(&self.fire, hit.source) && self.fire_immune)
                || (Dragon::tag(&self.fall, hit.source) && self.fall_immune))
    }
}

impl Hooks for Dragon {}

impl Family for Dragon {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Dragon::data_of()).unwrap_or_else(FamilyData::empty)
    }

    /// `taken/2`: nothing from an ignited arrow; a quarter plus up to one
    /// on any part but the head and neck.
    fn taken(&self, body: &Body, hit: &Hit) -> Option<Hit> {
        let f = crate::mobs::ai::fmath::f;
        let damage = if Dragon::ignites(body, hit) {
            0.0
        } else {
            f(hit.amount)
        };
        let damage = match hit.dragon_part.unwrap_or(2) {
            0 | 1 => damage,
            _ => f(f(damage / 4.0) + crate::mobs::ai::fmath::emin(damage, 1.0)),
        };
        Some(Hit {
            amount: damage,
            ..hit.clone()
        })
    }

    fn knockback(&self, body: &Body) -> bool {
        !self.sitting(body)
    }

    /// `ignores?/2`: what it would not admit, or a hit from neither a player
    /// nor a source that always hurts it.
    fn ignores(&self, body: &Body, hit: &Hit) -> bool {
        !self.admits_ignored(body, hit)
            || !(hit.attacker.as_ref().is_some_and(|a| a.player)
                || Dragon::tag(&self.always, hit.source))
    }

    /// `admits_ignored?/2`: `EnderDragon.hurt` admits a hit even when it
    /// takes no health, while not dying and above a hundredth.
    fn admits_ignored(&self, body: &Body, hit: &Hit) -> bool {
        Dragon::phase(body) != 9 && hit.amount >= 0.01_f32 as f64 && !self.part_immune(hit)
    }

    /// `damage_result/3`: sitting, it counts what it takes and takes off
    /// past a quarter of its maximum; in flight a killing blow leaves it at
    /// one health, dying.
    fn damage_result(&self, body: &mut Body, health_before: f64, outcome: &mut Outcome) {
        let f = crate::mobs::ai::fmath::f;
        if self.sitting(body) {
            let sitting = body
                .data
                .get("sitting_damage")
                .and_then(Value::as_number)
                .unwrap_or(0.0);
            let health = &body.mob.living.health;
            let received = f(f(sitting + health_before) - health.value);
            if received > f(0.25 * health.maximum) {
                body.data.set("sitting_damage", Value::Float(0.0));
                body.data.set("phase", Value::Int(4));
            } else {
                body.data.set("sitting_damage", Value::Float(received));
            }
        } else if outcome.died {
            body.mob.living.health.value = 1.0;
            body.mob.living.health.death_ticks = 0;
            body.data.set("phase", Value::Int(9));
            outcome.died = false;
        }
    }

    /// `hurt/2`: its hurt sound restarted its mind's ambient clock, which
    /// its actor keeps.
    fn hurt(&self, body: &mut Body, _hit: &Hit, _events: &mut Vec<Event>) {
        let Some(ambient) = body
            .mob
            .ai
            .as_ref()
            .and_then(|m| m.state.as_ref())
            .map(|s| s.ambient)
        else {
            return;
        };
        let Some(brain) = body.data.get("brain") else {
            return;
        };
        if !brain.is_struct(codec::ACTOR) {
            return;
        }
        if let Some(Value::Map(mut map)) = body.data.get("brain").cloned() {
            map.insert_atom("ambient", Value::Int(ambient));
            body.data.set("brain", Value::Map(map));
        }
    }

    fn volume(&self, _body: &Body, _volume: f64) -> f64 {
        5.0
    }

    /// Its death actor gives experience in its own bursts.
    fn experience(&self, _body: &Body) -> Option<i32> {
        Some(0)
    }

    fn ambient_interval(&self) -> Option<i32> {
        Some(self.ambient_interval)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        vec![value(
            "dragon_phase",
            Value::Int(Dragon::phase(body)),
            Value::Int(10),
        )]
    }
}

impl Kind for Dragon {
    fn module(&self) -> &'static str {
        "Valimc.Entity.Dragon"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered::default()
    }

    fn kernel_motion(&self) -> KindMotion {
        KindMotion {
            fixed: true,
            pushable: false,
            pushes: false,
            fluid_pushed: false,
            emission: Emission::None,
            ..KindMotion::default()
        }
    }

    fn falls(&self) -> bool {
        false
    }

    fn affected(&self, _effect: i32) -> bool {
        false
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Dragon::data_of()
    }
}
