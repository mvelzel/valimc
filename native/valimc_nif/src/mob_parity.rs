//! Native mob facts, level and sensing against `Valimc.AI` (VMC-081d),
//! built only with the `parity` feature: `mob_parity_fact` answers one
//! facts accessor, `mob_parity_level` the level's predicates over a region's
//! store, `mob_parity_sight` lines of sight over it and
//! `mob_parity_sensing` a seer's targeting queries over sensed rows.

use crate::facts::{PHYSICS, STATES};
use crate::mob_facts::facts;
use crate::region::{with_store, Region};
use rustler::types::tuple::{get_tuple, make_tuple};
use rustler::{Atom, Binary, Encoder, Env, NifMap, NifResult, ResourceArc, Term};
use valimc_core::mobs::facts::{MobFacts, Slot};
use valimc_core::mobs::level::{self, Difficulty, FluidKind, Level, StoreBlocks};
use valimc_core::mobs::random::LegacyRandom;
use valimc_core::mobs::sensing::{
    self, Conditions, Entity, GameMode, Kind, Ref, Seer, Select, SensedMob, SensedPlayer,
    Sensing, SightCache, Uuid,
};
use valimc_core::physics::Aabb;

mod atoms {
    rustler::atoms! {
        empty, water, lava, any, player,
        uuid, id, x, y, z, eye, width, height, alive, invulnerable,
        cell, motion_blocking, fits, in_water,
        survival, creative, adventure, spectator,
        peaceful, easy, normal, hard,
        mainhand, offhand, head, chest, legs, feet,
    }
}

fn bad() -> rustler::Error {
    rustler::Error::BadArg
}

fn tuple<'a>(env: Env<'a>, items: Vec<Term<'a>>) -> Term<'a> {
    make_tuple(env, &items)
}

fn slot_name(slot: Slot) -> &'static str {
    match slot {
        Slot::MainHand => "mainhand",
        Slot::OffHand => "offhand",
        Slot::Feet => "feet",
        Slot::Legs => "legs",
        Slot::Chest => "chest",
        Slot::Head => "head",
        Slot::Body => "body",
        Slot::Saddle => "saddle",
    }
}

fn dims<'a>(env: Env<'a>, d: &[f32; 3]) -> Term<'a> {
    (d[0] as f64, d[1] as f64, d[2] as f64).encode(env)
}

/// One facts accessor: `{name, args...}` as the ExUnit test names it.
#[rustler::nif]
fn mob_parity_fact<'a>(env: Env<'a>, query: Term<'a>) -> NifResult<Term<'a>> {
    let f = facts()?;
    let q = get_tuple(query)?;
    let op = q.first().ok_or(bad())?.atom_to_string()?;
    let s = |i: usize| -> NifResult<String> { q.get(i).ok_or(bad())?.decode() };
    let n = |i: usize| -> NifResult<i64> { q.get(i).ok_or(bad())?.decode() };
    let entity = |i: usize| -> NifResult<u16> { f.entities.id(&s(i)?).ok_or(bad()) };
    let nil = rustler::types::atom::nil().encode(env);
    Ok(match op.as_str() {
        "entity" => match f.entities.fetch(&s(1)?) {
            None => nil,
            Some(t) => tuple(
                env,
                vec![
                    t.id.encode(env),
                    t.category.encode(env),
                    t.width.encode(env),
                    t.height.encode(env),
                    t.eye_height.encode(env),
                    t.fire_immune.encode(env),
                    t.enemy.encode(env),
                    t.tracking_range.encode(env),
                    t.update_interval.encode(env),
                    t.living().encode(env),
                    t.attributes.clone().unwrap_or_default().encode(env),
                    t.loot_table.encode(env),
                ],
            ),
        },
        "entity_tag" => f.entity_tag(entity(1)?, &s(2)?).encode(env),
        "category" => {
            let c = f.entities.categories.get(&s(1)?).ok_or(bad())?;
            (c.max, c.friendly, c.persistent, c.despawn_distance, c.no_despawn_distance).encode(env)
        }
        "attribute" => {
            let a = f.attributes.fetch(&s(1)?).ok_or(bad())?;
            (a.id, a.default, a.min, a.max).encode(env)
        }
        "effect" => f.effects.id(&s(1)?).encode(env),
        "item" => f.items.id(&s(1)?).encode(env),
        "block" => {
            let state = n(1)? as u16;
            let props: Vec<(String, String)> = f
                .blocks
                .properties(state)
                .ok_or(bad())?
                .into_iter()
                .map(|(k, v)| (k.to_owned(), v.to_owned()))
                .collect();
            (f.blocks.block_id(state), props).encode(env)
        }
        "tag" => f
            .tags
            .has(&s(1)?, &s(2)?, n(3)? as i32)
            .encode(env),
        "sound" => f.sounds.id(&s(1)?).encode(env),
        "mob_sounds" => {
            let m = f.combat.mob_sounds(entity(1)?);
            (m.hurt.clone(), m.death.clone(), m.source, m.animal).encode(env)
        }
        "ai_mob" => match f.ai.mob(entity(1)?) {
            None => nil,
            Some(m) => {
                let goals = |g: &[valimc_core::mobs::facts::ai::GoalFact]| {
                    g.iter()
                        .map(|g| (g.priority, g.name.clone(), g.flags))
                        .collect::<Vec<_>>()
                };
                tuple(
                    env,
                    vec![
                        m.max_head_y_rot.encode(env),
                        m.max_head_x_rot.encode(env),
                        m.head_rot_speed.encode(env),
                        m.ambient_sound.encode(env),
                        m.ambient_interval.encode(env),
                        m.volume.encode(env),
                        m.monster.encode(env),
                        m.malus.encode(env),
                        goals(&m.goals).encode(env),
                        goals(&m.targets).encode(env),
                    ],
                )
            }
        },
        "path_types" => f.ai.path_types.encode(env),
        "visibility" => {
            let item = f.items.id(&s(1)?).ok_or(bad())?;
            match f.ai.visibility.get(&item) {
                None => nil,
                Some(v) => {
                    let types: Vec<&str> = v
                        .types
                        .iter()
                        .filter_map(|&t| f.entities.name(t))
                        .collect();
                    (v.visibility, slot_name(v.slot), types).encode(env)
                }
            }
        }
        "shulker_look" => f
            .ai
            .shulker_look
            .get(n(1)? as usize)
            .ok_or(bad())?
            .map(|v| v as f64)
            .to_vec()
            .encode(env),
        "swing" => {
            let fields = f.ai.swing_fields(q.get(1).ok_or(bad())?.decode::<bool>()?);
            crate::binary(env, &fields).encode(env)
        }
        "drop_chance" => (f.hostile.drop_chance as f64).encode(env),
        "baby" => match f.hostile.babies.get(&entity(1)?) {
            None => nil,
            Some(d) => dims(env, d),
        },
        "monsters_burn" => f.hostile.monsters_burn(n(1)?).encode(env),
        "equippable" => {
            let item = f.items.id(&s(1)?).ok_or(bad())?;
            match f.hostile.equippable.get(&item) {
                None => nil,
                Some((slot, types, sound)) => {
                    let types = types.as_ref().map(|t| {
                        t.iter()
                            .filter_map(|&t| f.entities.name(t))
                            .collect::<Vec<_>>()
                    });
                    (slot_name(*slot), types, sound.clone()).encode(env)
                }
            }
        }
        "water_sensitive" => f.hostile.water_sensitive.contains(&entity(1)?).encode(env),
        "effect_modifiers" => {
            let effect = f.effects.id(&s(1)?).ok_or(bad())? as u16;
            f.hostile
                .effect_modifiers(effect, n(2)? as i32)
                .into_iter()
                .map(|(a, id, amount, op)| {
                    let name = f.attributes.attributes[a as usize].name.clone();
                    (name, id.to_owned(), amount, op)
                })
                .collect::<Vec<_>>()
                .encode(env)
        }
        "villager_type" => f.hostile.villager_type(&s(1)?).encode(env),
        "armour" => {
            let slot = Slot::parse(&s(1)?).map_err(|_| bad())?;
            f.hostile
                .armour(slot, n(2)? as usize)
                .and_then(|i| f.items.name(i))
                .encode(env)
        }
        "group_baby_chance" => (f.animal.group_baby_chance as f64).encode(env),
        "water_ageable" => {
            let (chance, baby) = f.animal.water_ageable.get(&entity(1)?).ok_or(bad())?;
            (*chance as f64, dims(env, baby)).encode(env)
        }
        "animal" => f.animal.animal(entity(1)?).encode(env),
        "animal_baby" => dims(env, &f.animal.animals[&entity(1)?].baby),
        "food" => {
            let item: Option<i32> = q.get(2).ok_or(bad())?.decode()?;
            f.animal.food(entity(1)?, item).encode(env)
        }
        "monster" => f.animal.monster(entity(1)?).encode(env),
        "biome_in" => {
            let biome = f
                .registries
                .id("minecraft:worldgen/biome", &s(1)?)
                .map(|b| b as u16);
            f.biome_in(biome, &s(2)?).encode(env)
        }
        "profession" => {
            let p = f.village.profession(&s(1)?).ok_or(bad())?;
            (
                p.id,
                p.held.clone(),
                p.acquirable.clone(),
                p.secondary.clone(),
                p.work_sound.clone(),
            )
                .encode(env)
        }
        "scheduled" => f
            .village
            .scheduled(n(1)?, q.get(2).ok_or(bad())?.decode()?)
            .encode(env),
        "type_of_biome" => f.village.type_of_biome(&s(1)?).encode(env),
        "damage" => f.damage_types.id(&s(1)?).encode(env),
        "damage_tag" => {
            let id = f.damage_types.id(&s(1)?).ok_or(bad())?;
            f.damage_tag(id, &s(2)?).encode(env)
        }
        "climate" => {
            let id = f
                .registries
                .id("minecraft:worldgen/biome", &s(1)?)
                .ok_or(bad())?;
            let c = f.climates[id as usize];
            (c.temperature, c.frozen, c.precipitation).encode(env)
        }
        "experience" => f.combat.experience.get(&entity(1)?).encode(env),
        _ => return Err(bad()),
    })
}

fn difficulty(atom: Atom) -> NifResult<Difficulty> {
    Ok(if atom == atoms::peaceful() {
        Difficulty::Peaceful
    } else if atom == atoms::easy() {
        Difficulty::Easy
    } else if atom == atoms::normal() {
        Difficulty::Normal
    } else if atom == atoms::hard() {
        Difficulty::Hard
    } else {
        return Err(bad());
    })
}

type BoxT = (f64, f64, f64, f64, f64, f64);

fn aabb(b: BoxT) -> Aabb {
    Aabb::new([b.0, b.1, b.2], [b.3, b.4, b.5])
}

/// A region's store as a level: its blocks, light and biomes.
fn over_region<T>(
    region: &Region,
    zoom_seed: i64,
    f: impl FnOnce(&mut Level) -> NifResult<T>,
) -> NifResult<T> {
    let facts = facts()?;
    let physics = PHYSICS.get().ok_or(bad())?;
    let states = STATES.get().ok_or(bad())?;
    let plains = facts
        .registries
        .id("minecraft:worldgen/biome", "minecraft:plains")
        .ok_or(bad())? as u16;
    let mut result = None;
    with_store(region, |store| {
        let blocks = StoreBlocks(store);
        let environment = level::Store {
            store,
            zoom_seed,
            plains,
        };
        let mut level = Level::new(
            &blocks,
            &environment,
            facts,
            physics,
            states,
            LegacyRandom::new(0),
        );
        result = Some(f(&mut level));
        Ok(())
    })
    .map_err(|a| rustler::Error::Term(Box::new(a)))?;
    result.ok_or(bad())?
}

/// The level's answers over a region's store with the sky darkened by
/// `darken`: `{:cell, pos}` gives `{state, air, solid, collides, fluid,
/// conductor, solid_render, light, sees_sky, biome}`, `{:motion_blocking, x,
/// z}`, `{:fits, box}` and `{:in_water, box}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn mob_parity_level<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    zoom_seed: i64,
    darken: i32,
    queries: Vec<Term<'a>>,
) -> NifResult<Vec<Term<'a>>> {
    over_region(&region, zoom_seed, |level| {
        level.darken = darken;
        queries
            .iter()
            .map(|q| {
                let q = get_tuple(*q)?;
                let op: Atom = q[0].decode()?;
                Ok(if op == atoms::cell() {
                    let (x, y, z): (i32, i32, i32) = q[1].decode()?;
                    let p = [x, y, z];
                    let fluid = match level.fluid(p) {
                        FluidKind::Empty => atoms::empty(),
                        FluidKind::Water => atoms::water(),
                        FluidKind::Lava => atoms::lava(),
                    };
                    tuple(
                        env,
                        vec![
                            level.block(p).encode(env),
                            level.air(p).encode(env),
                            level.solid(p).encode(env),
                            level.collides(p).encode(env),
                            fluid.encode(env),
                            level.conductor(p).encode(env),
                            level.solid_render(p).encode(env),
                            (level.light(p) as f64).encode(env),
                            level.sees_sky(p).encode(env),
                            level.biome_name(p).encode(env),
                        ],
                    )
                } else if op == atoms::motion_blocking() {
                    level
                        .motion_blocking(q[1].decode()?, q[2].decode()?)
                        .encode(env)
                } else if op == atoms::fits() {
                    level.fits(&aabb(q[1].decode()?)).encode(env)
                } else if op == atoms::in_water() {
                    level.in_water(&aabb(q[1].decode()?)).encode(env)
                } else {
                    return Err(bad());
                })
            })
            .collect()
    })
}

type V3 = (f64, f64, f64);

/// Lines of sight between eye points over a region's store.
#[rustler::nif(schedule = "DirtyCpu")]
fn mob_parity_sight(region: ResourceArc<Region>, pairs: Vec<(V3, V3)>) -> NifResult<Vec<bool>> {
    over_region(&region, 0, |level| {
        Ok(pairs
            .iter()
            .map(|&(a, b)| sensing::sight::line_of_sight(level, [a.0, a.1, a.2], [b.0, b.1, b.2]))
            .collect())
    })
}

#[derive(NifMap)]
struct PlayerT<'a> {
    uuid: Binary<'a>,
    id: i32,
    x: f64,
    y: f64,
    z: f64,
    eye: f64,
    width: f64,
    height: f64,
    mode: Atom,
    invulnerable: bool,
    alive: bool,
    crouching: bool,
    invisible: bool,
    armor_cover: f64,
    equipment: Term<'a>,
}

fn uuid(b: &Binary) -> NifResult<Uuid> {
    b.as_slice().try_into().map_err(|_| bad())
}

fn player_row(env: Env, p: PlayerT) -> NifResult<SensedPlayer> {
    let mode = if p.mode == atoms::survival() {
        GameMode::Survival
    } else if p.mode == atoms::creative() {
        GameMode::Creative
    } else if p.mode == atoms::adventure() {
        GameMode::Adventure
    } else if p.mode == atoms::spectator() {
        GameMode::Spectator
    } else {
        return Err(bad());
    };
    let slots = [
        atoms::chest(),
        atoms::feet(),
        atoms::head(),
        atoms::legs(),
        atoms::mainhand(),
        atoms::offhand(),
    ];
    let mut equipment = [None; 6];
    for (e, slot) in equipment.iter_mut().zip(slots) {
        *e = match p.equipment.map_get(slot.to_term(env)) {
            Ok(v) => v.decode()?,
            Err(_) => None,
        };
    }
    Ok(SensedPlayer {
        uuid: uuid(&p.uuid)?,
        id: p.id,
        position: [p.x, p.y, p.z],
        yaw: 0.0,
        pitch: 0.0,
        eye: p.eye,
        width: p.width,
        height: p.height,
        mode,
        invulnerable: p.invulnerable,
        alive: p.alive,
        crouching: p.crouching,
        swimming: false,
        invisible: p.invisible,
        armor_cover: p.armor_cover,
        equipment,
        movement: [0.0; 3],
        velocity: [0.0; 3],
        health: 20.0,
        effects: vec![],
    })
}

/// A sensed mob map (`AI.sensed/1`'s keys the sensing reads).
fn mob_row(env: Env, f: &MobFacts, m: Term) -> NifResult<SensedMob> {
    let get = |key: Atom| m.map_get(key.to_term(env));
    let kind: String = m.map_get(Atom::from_str(env, "type")?.to_term(env))?.decode()?;
    Ok(SensedMob {
        uuid: uuid(&get(atoms::uuid())?.decode()?)?,
        id: get(atoms::id())?.decode()?,
        type_id: f.entities.id(&kind).ok_or(bad())?,
        position: [
            get(atoms::x())?.decode()?,
            get(atoms::y())?.decode()?,
            get(atoms::z())?.decode()?,
        ],
        yaw: 0.0,
        pitch: 0.0,
        eye: get(atoms::eye())?.decode()?,
        width: get(atoms::width())?.decode()?,
        height: get(atoms::height())?.decode()?,
        own_box: None,
        alive: get(atoms::alive())?.decode()?,
        recent_mob_hurt: false,
        baby: false,
        huntable: true,
        target: None,
        in_love: 0,
        age: 0,
        in_water: false,
        invulnerable: get(atoms::invulnerable())?.decode()?,
        killed_by: None,
        panicking: false,
        extra: (),
    })
}

struct Me {
    uuid: Uuid,
    type_id: u16,
    position: [f64; 3],
    eye: f64,
    sight: SightCache,
}

impl Seer<()> for Me {
    fn uuid(&self) -> Uuid {
        self.uuid
    }
    fn type_id(&self) -> u16 {
        self.type_id
    }
    fn position(&self) -> [f64; 3] {
        self.position
    }
    fn eye_y(&self) -> f64 {
        self.position[1] + self.eye
    }
    fn sight(&mut self) -> &mut SightCache {
        &mut self.sight
    }
}

/// `{combat, range, sight, invisible}`.
type ConditionsT = (bool, f64, bool, bool);

fn conditions<'f>(c: ConditionsT) -> Conditions<'f, (), Me> {
    Conditions {
        combat: c.0,
        range: c.1,
        sight: c.2,
        invisible: c.3,
        select: None,
    }
}

fn select<'s>(term: Term, f: &MobFacts, types: &'s mut Vec<u16>) -> NifResult<Select<'s>> {
    if term.decode::<Atom>().is_ok_and(|a| a == atoms::any()) {
        return Ok(Select::Any);
    }
    let names: Vec<String> = term.decode()?;
    *types = names
        .iter()
        .map(|n| f.entities.id(n).ok_or(bad()))
        .collect::<NifResult<_>>()?;
    Ok(Select::Types(types))
}

/// A seer's queries in order over sensed players and mobs, its sight cache
/// kept between them (as the Elixir threads `self`): `{:test, {kind, i},
/// conditions}`, `{:visibility, i}`, `{:nearest_player, conditions,
/// point}`, `{:nearest_mob, types | :any, box, conditions, point}`,
/// `{:mobs_in, types | :any, box}`, `{:resense, uuid, {x, y, z}, alive}`.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn mob_parity_sensing<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    difficulty_atom: Atom,
    seer: (Binary<'a>, String, V3, f64),
    players: Vec<PlayerT<'a>>,
    mobs: Vec<Term<'a>>,
    queries: Vec<Term<'a>>,
) -> NifResult<Vec<Term<'a>>> {
    let f = facts()?;
    let players = players
        .into_iter()
        .map(|p| player_row(env, p))
        .collect::<NifResult<Vec<_>>>()?;
    let mobs = mobs
        .into_iter()
        .map(|m| mob_row(env, f, m))
        .collect::<NifResult<Vec<_>>>()?;
    let mut sensing: Sensing = Sensing::new(players, vec![], mobs);
    let mut me = Me {
        uuid: uuid(&seer.0)?,
        type_id: f.entities.id(&seer.1).ok_or(bad())?,
        position: [seer.2 .0, seer.2 .1, seer.2 .2],
        eye: seer.3,
        sight: SightCache::default(),
    };
    let nil = rustler::types::atom::nil().encode(env);
    over_region(&region, 0, |level| {
        level.difficulty = difficulty(difficulty_atom)?;
        let mut out = Vec::with_capacity(queries.len());
        for q in &queries {
            let q = get_tuple(*q)?;
            let op = q[0].atom_to_string()?;
            let point = |t: Term| -> NifResult<[f64; 3]> {
                let p: V3 = t.decode()?;
                Ok([p.0, p.1, p.2])
            };
            out.push(match op.as_str() {
                "test" => {
                    let (kind, i): (Atom, usize) = q[1].decode()?;
                    let target = if kind == atoms::player() {
                        Entity::Player(sensing.players.get(i).ok_or(bad())?)
                    } else {
                        Entity::Mob(sensing.mobs().get(i).ok_or(bad())?)
                    };
                    let c = conditions(q[2].decode()?);
                    sensing::test(level, &mut me, target, &c).encode(env)
                }
                "visibility" => {
                    let i: usize = q[1].decode()?;
                    let p = sensing.players.get(i).ok_or(bad())?;
                    sensing::visibility(level, Entity::<()>::Player(p), me.type_id).encode(env)
                }
                "nearest_player" => {
                    let c = conditions(q[1].decode()?);
                    match sensing::nearest_player(level, &sensing, &mut me, &c, point(q[2])?) {
                        Some(p) => crate::binary(env, &p.uuid).encode(env),
                        None => nil,
                    }
                }
                "nearest_mob" => {
                    let mut types = Vec::new();
                    let s = select(q[1], f, &mut types)?;
                    let c = conditions(q[3].decode()?);
                    let b = aabb(q[2].decode()?);
                    match sensing::nearest_mob(level, &sensing, &mut me, &s, &b, &c, point(q[4])?)
                    {
                        Some(m) => crate::binary(env, &m.uuid).encode(env),
                        None => nil,
                    }
                }
                "mobs_in" => {
                    let mut types = Vec::new();
                    let s = select(q[1], f, &mut types)?;
                    let b = aabb(q[2].decode()?);
                    sensing
                        .mobs_in(&s, &b)
                        .into_iter()
                        .map(|i| crate::binary(env, &sensing.mob_at(i).uuid).encode(env))
                        .collect::<Vec<_>>()
                        .encode(env)
                }
                "resense" => {
                    let id: Binary = q[1].decode()?;
                    let at = point(q[2])?;
                    let alive: bool = q[3].decode()?;
                    let found = sensing.resense(&uuid(&id)?, |m| {
                        m.position = at;
                        m.alive = alive;
                    });
                    found.encode(env)
                }
                "target" => {
                    let (kind, id): (Atom, Binary) = q[1].decode()?;
                    let r = Ref {
                        kind: if kind == atoms::player() {
                            Kind::Player
                        } else {
                            Kind::Mob
                        },
                        uuid: uuid(&id)?,
                    };
                    match sensing.target(level, &me, Some(&r)) {
                        Some(e) => crate::binary(env, &e.uuid()).encode(env),
                        None => nil,
                    }
                }
                _ => return Err(bad()),
            });
        }
        Ok(out)
    })
}
