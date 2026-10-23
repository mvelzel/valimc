//! Spawner blocks (VMC-042b): `BaseSpawner.serverTick` over the level a
//! natural spawn reads. A spawner near a player counts down its delay, then
//! tries `count` spots around itself for its mob, which must pass the
//! spawner's spawn rules, fit, and find fewer than `max_nearby` of its type
//! around; any success restarts the delay. The mob's `finalizeSpawn` is its
//! family's, drawing from a random of its own (`Finalize`).

use super::facts::TypeFacts;
use super::rules::{distance_sqr, World};
use super::spawner::Spawned;
use crate::physics::Aabb;
use crate::worldgen::random::Random;

/// A spawner's saved configuration (`BaseSpawner.load`): the type its next
/// spawn data names (none for an empty spawner), delays, spawn count and
/// ranges. Its spawn potentials are empty (generated spawners and those a
/// spawn egg set): no delay draws a new spawn data.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Config {
    pub kind: Option<u16>,
    pub min_delay: i32,
    pub max_delay: i32,
    pub count: i32,
    pub max_nearby: i32,
    pub player_range: i32,
    pub spawn_range: i32,
}

/// A spawner block at `pos` with its countdown.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Spawner {
    pub pos: [i32; 3],
    pub delay: i32,
    pub config: Config,
}

/// What a tick of one spawner did: its spawns (each a level event 2004 at
/// the spawner) and whether it restarted its delay (block event 1).
#[derive(Debug, Default, PartialEq)]
pub struct Ticked {
    pub spawned: Vec<Spawned>,
    pub delayed: bool,
}

/// `isNearPlayer`: a player that is not a spectator within the range of
/// the block's centre.
fn near_player(world: &World, spawner: &Spawner) -> bool {
    let p = spawner.pos;
    let centre = [p[0] as f64 + 0.5, p[1] as f64 + 0.5, p[2] as f64 + 0.5];
    let range = spawner.config.player_range as f64;
    world
        .players
        .iter()
        .any(|pl| !pl.spectator && distance_sqr(pl.pos, centre) < range * range)
}

/// `delay`: a new countdown between the delays (the spawn potentials are
/// empty, so nothing else is drawn).
fn delay(spawner: &mut Spawner, random: &mut Random) {
    let c = spawner.config;
    spawner.delay = if c.max_delay <= c.min_delay {
        c.min_delay
    } else {
        c.min_delay + random.next_int_bounded(c.max_delay - c.min_delay)
    };
}

/// The mobs of the group the nearby count sees: type and box, the tick's
/// spawns added as they spawn.
pub type Mobs = Vec<(u16, Aabb)>;

/// `serverTick` of `spawner` (spawner blocks working, checked by the
/// caller), drawing from the level's `random`; `finalize` runs after each
/// mob passes its checks, with the spawn's index.
pub fn tick(
    world: &World,
    spawner: &mut Spawner,
    mobs: &mut Mobs,
    random: &mut Random,
    finalize: &mut dyn FnMut(&mut Random, usize),
) -> Ticked {
    let mut out = Ticked::default();
    if !near_player(world, spawner) {
        return out;
    }
    if spawner.delay == -1 {
        delay(spawner, random);
        out.delayed = true;
    }
    if spawner.delay > 0 {
        spawner.delay -= 1;
        return out;
    }
    let config = spawner.config;
    let Some(kind) = config.kind.and_then(|k| world.facts.kind(k)) else {
        // No type to spawn (or none ValiMC knows): `delay` and stop.
        delay(spawner, random);
        out.delayed = true;
        return out;
    };
    let p = spawner.pos;
    let range = config.spawn_range as f64;
    let mut spawned = false;
    for _ in 0..config.count {
        let x = p[0] as f64 + (random.next_double() - random.next_double()) * range + 0.5;
        let y = (p[1] + random.next_int_bounded(3) - 1) as f64;
        let z = p[2] as f64 + (random.next_double() - random.next_double()) * range + 0.5;
        if !world.no_collision(kind, x, y, z) {
            continue;
        }
        let block = [x.floor() as i32, y.floor() as i32, z.floor() as i32];
        if !world.spawner_rules(kind, block, random) {
            continue;
        }
        if nearby(kind, p, range, mobs) >= config.max_nearby as usize {
            delay(spawner, random);
            out.delayed = true;
            return out;
        }
        let yaw = random.next_float() * 360.0;
        if !world.mob_spawn_rules(kind, block) || !world.obstruction(kind, x, y, z) {
            continue;
        }
        finalize(random, out.spawned.len());
        let body = World::body(kind, x, y, z);
        mobs.push((kind.id, body));
        world.bodies.borrow_mut().push(body);
        out.spawned.push(Spawned {
            kind: kind.id,
            pos: [x, y, z],
            yaw,
            school: true,
        });
        spawned = true;
    }
    if spawned {
        delay(spawner, random);
        out.delayed = true;
    }
    out
}

/// Mobs of the spawner's type (`forExactClass`) whose boxes meet the block
/// inflated by the spawn range.
fn nearby(kind: &TypeFacts, p: [i32; 3], range: f64, mobs: &Mobs) -> usize {
    let area = Aabb::new(
        [p[0] as f64, p[1] as f64, p[2] as f64],
        [p[0] as f64 + 1.0, p[1] as f64 + 1.0, p[2] as f64 + 1.0],
    )
    .inflate(range);
    mobs.iter()
        .filter(|(k, b)| *k == kind.id && b.intersects(&area))
        .count()
}
