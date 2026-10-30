//! Vanilla's `NaturalSpawner` (VMC-042a): a tick's spawn state (counts,
//! potential charges, per-player local caps), the categories a tick spawns,
//! each spawning chunk's attempts with their packs, and the creatures a chunk
//! gets when it generates.

use super::facts::{Category, Count, Spawner, TypeFacts, CATEGORIES};
use super::level::WORLD_SURFACE;
use super::rules::World;
use crate::column::MIN_Y;
use crate::worldgen::random::Random;

/// A mob the spawner made: its type, position and yaw (bits), and whether a
/// tropical fish swims in a school.
#[derive(Clone, Debug, PartialEq)]
pub struct Spawned {
    pub kind: u16,
    pub pos: [f64; 3],
    pub yaw: f32,
    pub school: bool,
    /// Index of the pack's first admitted member in this result. Spawner
    /// blocks have no shared group data and use None.
    pub pack: Option<usize>,
}

/// A mob counted toward the caps (`createState`): not persistent, in a
/// held chunk.
#[derive(Clone, Copy, Debug)]
pub struct Counted {
    pub kind: u16,
    pub block: [i32; 3],
}

/// The potential charges (`PotentialCalculator`): built when the tick
/// starts, or by `load` when a spawn first needs them (a group's are
/// gathered only where a biome's spawn costs apply, VMC-081g2).
pub type Charges = Vec<([i32; 3], f64)>;

/// `NaturalSpawner.SpawnState` with its `LocalMobCapCalculator`, for the
/// players of one group.
pub struct SpawnState<'l> {
    pub spawnable: i32,
    pub counts: [i32; 8],
    charges: Option<Charges>,
    load: Option<&'l dyn Fn() -> Charges>,
    /// Per player (by index into the world's players), per category.
    pub local: Vec<[i32; 8]>,
}

/// `distanceManager.hasPlayersNearby`: any player's chunk within eight
/// chunks (chessboard), spectators included.
fn near_spawn_tracker(world: &World, chunk: (i32, i32)) -> bool {
    world.players.iter().any(|p| {
        let (cx, cz) = (
            (p.pos[0].floor() as i32) >> 4,
            (p.pos[2].floor() as i32) >> 4,
        );
        (cx - chunk.0).abs() <= 8 && (cz - chunk.1).abs() <= 8
    })
}

/// `getPlayersCloseForSpawning`: players that are not spectators within 128
/// blocks of the chunk's centre (horizontally), by index.
pub fn near<'w>(world: &'w World, chunk: (i32, i32)) -> impl Iterator<Item = usize> + 'w {
    let tracked = near_spawn_tracker(world, chunk);
    let (x, z) = ((chunk.0 * 16 + 8) as f64, (chunk.1 * 16 + 8) as f64);
    world
        .players
        .iter()
        .enumerate()
        .filter(move |(_, p)| {
            let (dx, dz) = (x - p.pos[0], z - p.pos[2]);
            tracked && !p.spectator && dx * dx + dz * dz < 16384.0
        })
        .map(|(i, _)| i)
}

/// `getPlayersCloseForSpawning` as a list.
pub fn players_near(world: &World, chunk: (i32, i32)) -> Vec<usize> {
    near(world, chunk).collect()
}

/// The number of chunks within eight (chessboard) of any player's chunk
/// (`getNaturalSpawnChunkCount`).
pub fn spawnable_chunks(world: &World) -> i32 {
    let mut chunks = std::collections::HashSet::new();
    for p in &world.players {
        let (cx, cz) = (
            (p.pos[0].floor() as i32) >> 4,
            (p.pos[2].floor() as i32) >> 4,
        );
        for dx in -8..=8 {
            for dz in -8..=8 {
                chunks.insert((cx + dx, cz + dz));
            }
        }
    }
    chunks.len() as i32
}

impl<'l> SpawnState<'l> {
    /// `createState` over the counted mobs.
    pub fn new(world: &World, spawnable: i32, mobs: &[Counted]) -> SpawnState<'l> {
        let mut state = SpawnState {
            spawnable,
            counts: [0; 8],
            charges: Some(Vec::new()),
            load: None,
            local: vec![[0; 8]; world.players.len()],
        };
        for mob in mobs {
            let Some(kind) = world.facts.kind(mob.kind) else {
                continue;
            };
            if kind.category == Category::Misc {
                continue;
            }
            if let Some(&(_, charge)) = world
                .facts
                .biome(world.level.biome(mob.block))
                .costs
                .get(&mob.kind)
            {
                state.add_charge(mob.block, charge);
            }
            state.add_local(world, mob.block, kind.category);
            state.counts[kind.category.index()] += 1;
        }
        state
    }

    /// `createState` from counts kept elsewhere: the categories' counts,
    /// each player's local counts and the charges `load` gathers when a
    /// spawn first needs them.
    pub fn resident(
        spawnable: i32,
        counts: [i32; 8],
        local: Vec<[i32; 8]>,
        load: &'l dyn Fn() -> Charges,
    ) -> SpawnState<'l> {
        SpawnState {
            spawnable,
            counts,
            charges: None,
            load: Some(load),
            local,
        }
    }

    fn charges(&mut self) -> &mut Charges {
        let load = self.load;
        self.charges
            .get_or_insert_with(|| load.map_or_else(Vec::new, |f| f()))
    }

    fn add_charge(&mut self, pos: [i32; 3], charge: f64) {
        if charge != 0.0 {
            self.charges().push((pos, charge));
        }
    }

    fn add_local(&mut self, world: &World, block: [i32; 3], category: Category) {
        for i in near(world, (block[0] >> 4, block[2] >> 4)) {
            self.local[i][category.index()] += 1;
        }
    }

    /// `canSpawnForCategoryGlobal`.
    pub fn global(&self, world: &World, category: Category) -> bool {
        let max = world.facts.category(category).max * self.spawnable / 289;
        self.counts[category.index()] < max
    }

    /// `canSpawnForCategoryLocal`.
    pub fn local(&self, world: &World, category: Category, chunk: (i32, i32)) -> bool {
        let max = world.facts.category(category).max;
        near(world, chunk).any(|i| self.local[i][category.index()] < max)
    }

    /// `canSpawn`: the potential's energy change within the type's budget.
    fn potential(&mut self, world: &World, kind: u16, pos: [i32; 3]) -> (bool, f64) {
        match world.facts.biome(world.level.biome(pos)).costs.get(&kind) {
            None => (true, 0.0),
            Some(&(budget, charge)) => {
                let mut change = 0.0f64;
                for (at, c) in self.charges().iter() {
                    let d = (0..3)
                        .map(|a| ((at[a] - pos[a]) as f64).powi(2))
                        .sum::<f64>();
                    change += if d == 0.0 {
                        f64::INFINITY
                    } else {
                        c / d.sqrt()
                    };
                }
                (change * charge <= budget, charge)
            }
        }
    }

    /// `afterSpawn`.
    fn after(&mut self, world: &World, kind: &TypeFacts, block: [i32; 3], charge: f64) {
        self.add_charge(block, charge);
        self.counts[kind.category.index()] += 1;
        self.add_local(world, block, kind.category);
    }
}

/// `getFilteredSpawningCategories`.
pub fn categories(
    world: &World,
    state: &SpawnState,
    enemies: bool,
    persistent: bool,
) -> Vec<Category> {
    CATEGORIES
        .into_iter()
        .filter(|&c| c != Category::Misc)
        .filter(|&c| {
            let f = world.facts.category(c);
            (enemies || f.friendly) && (persistent || !f.persistent) && state.global(world, c)
        })
        .collect()
}

/// `Util.shuffle`.
pub fn shuffle<T>(items: &mut [T], random: &mut Random) {
    let mut i = items.len();
    while i > 1 {
        let to = random.next_int_bounded(i as i32) as usize;
        items.swap(i - 1, to);
        i -= 1;
    }
}

fn sample(count: Count, random: &mut Random) -> i32 {
    match count {
        Count::Constant(v) => v,
        Count::Uniform(min, max) => random.next_int_bounded(max - min + 1) + min,
    }
}

/// `WeightedList.getRandom`: no draw from an empty list.
fn pick(list: &[Spawner], total: i32, random: &mut Random) -> Option<Spawner> {
    if total == 0 {
        return None;
    }
    let mut at = random.next_int_bounded(total);
    for s in list {
        at -= s.weight;
        if at < 0 {
            return Some(*s);
        }
    }
    None
}

/// What a pack's finalized members decide that the spawner reads back: a
/// tropical fish's school (`TropicalFish.finalizeSpawn`, from a random of
/// its own; vanilla shares the level's).
pub trait Finalize {
    /// The school of the tick's `index`th spawn, a tropical fish.
    fn school(&mut self, first_of_pack: bool, index: usize) -> bool;
}

/// Live: the first fish of a pack schools nine times in ten (its group
/// data then makes the rest of the pack school).
pub struct Drawn<'r>(pub &'r mut Random);

impl Finalize for Drawn<'_> {
    fn school(&mut self, first_of_pack: bool, _index: usize) -> bool {
        !first_of_pack || self.0.next_float() < 0.9
    }
}

/// An oracle's recorded schools, by spawn.
pub struct Recorded(pub Vec<bool>);

impl Finalize for Recorded {
    fn school(&mut self, _first_of_pack: bool, index: usize) -> bool {
        self.0.get(index).copied().unwrap_or(true)
    }
}

/// The spawning of one tick in one group.
pub struct Tick<'w, 'a> {
    pub world: &'w World<'a>,
    pub state: SpawnState<'w>,
    pub random: Random,
    pub spawned: Vec<Spawned>,
    /// Chunks whose entities tick (`canSpawnEntitiesInChunk`).
    pub ticking: &'w dyn Fn((i32, i32)) -> bool,
    /// The world spawn in this dimension.
    pub respawn: Option<[i32; 3]>,
    /// Whether the per-player local caps apply (an oracle's scene admits
    /// every category).
    pub caps: bool,
    /// The starts the chunks reference whose structures override spawns.
    pub structures: &'w dyn super::structures::Kept,
}

impl<'w> Tick<'w, '_> {
    /// `spawnForChunk`.
    pub fn chunk(
        &mut self,
        chunk: (i32, i32),
        categories: &[Category],
        finalize: &mut dyn Finalize,
    ) {
        for &category in categories {
            if !self.caps || self.state.local(self.world, category, chunk) {
                self.category_for_chunk(category, chunk, finalize);
            }
        }
    }

    /// `spawnCategoryForChunk`: a random start in the chunk.
    fn category_for_chunk(
        &mut self,
        category: Category,
        chunk: (i32, i32),
        finalize: &mut dyn Finalize,
    ) {
        let x = chunk.0 * 16 + self.random.next_int_bounded(16);
        let z = chunk.1 * 16 + self.random.next_int_bounded(16);
        let top = self.world.level.height(WORLD_SURFACE, x, z);
        let y = self.random.next_int_bounded(top - MIN_Y + 1) + MIN_Y;
        if y > MIN_Y {
            self.category_for_position(category, chunk, [x, y, z], finalize);
        }
    }

    /// `isRightDistanceToPlayerAndSpawnPoint`.
    fn right_distance(&self, chunk: (i32, i32), pos: [i32; 3], d: f64) -> bool {
        if d <= 576.0 {
            return false;
        }
        if let Some(spawn) = self.respawn {
            let c = [pos[0] as f64 + 0.5, pos[1] as f64, pos[2] as f64 + 0.5];
            let s = [
                spawn[0] as f64 + 0.5,
                spawn[1] as f64 + 0.5,
                spawn[2] as f64 + 0.5,
            ];
            if super::rules::distance_sqr(s, c) < 576.0 {
                return false;
            }
        }
        let at = (pos[0] >> 4, pos[2] >> 4);
        at == chunk || (self.ticking)(at)
    }

    /// `mobsAt`: a structure's override there, else the biome's spawners.
    fn list(&self, category: Category, pos: [i32; 3]) -> (&'w [Spawner], i32) {
        list_at(self.world, self.structures, category, pos)
    }

    /// `spawnCategoryForPosition`: three packs from `start`.
    pub fn category_for_position(
        &mut self,
        category: Category,
        chunk: (i32, i32),
        start: [i32; 3],
        finalize: &mut dyn Finalize,
    ) {
        let world = self.world;
        if world.redstone_conductor(world.state(start)) {
            return;
        }
        let y = start[1];
        let mut cluster = 0;
        for _ in 0..3 {
            let pack = self.spawned.len();
            let (mut x, mut z) = (start[0], start[2]);
            let mut current: Option<Spawner> = None;
            let mut max = ceil(self.random.next_float() * 4.0);
            let mut group = 0;
            let mut ll = 0;
            while ll < max {
                x += self.random.next_int_bounded(6) - self.random.next_int_bounded(6);
                z += self.random.next_int_bounded(6) - self.random.next_int_bounded(6);
                let pos = [x, y, z];
                let (xx, zz) = (x as f64 + 0.5, z as f64 + 0.5);
                ll += 1;
                let Some(d) = world.nearest([xx, y as f64, zz]) else {
                    continue;
                };
                if !self.right_distance(chunk, pos, d) {
                    continue;
                }
                if current.is_none() {
                    let biome = world.facts.biome(world.level.biome(pos));
                    if category == Category::WaterAmbient
                        && biome.reduced_water_ambient
                        && self.random.next_float() < 0.98
                    {
                        break;
                    }
                    let (list, total) = self.list(category, pos);
                    match pick(list, total, &mut self.random) {
                        None => break,
                        Some(s) => {
                            current = Some(s);
                            max = sample(s.count, &mut self.random);
                        }
                    }
                }
                let spawner = current.unwrap();
                let Some(kind) = world.facts.kind(spawner.kind) else {
                    return;
                };
                if !self.valid_position_for_type(category, &spawner, kind, pos, d) {
                    continue;
                }
                let (allowed, charge) = self.state.potential(world, spawner.kind, pos);
                if !allowed {
                    continue;
                }
                let yaw = self.random.next_float() * 360.0;
                if !self.valid_position_for_mob(kind, pos, xx, zz, d) {
                    continue;
                }
                let school = kind.name != "minecraft:tropical_fish"
                    || finalize.school(group == 0, self.spawned.len());
                cluster += 1;
                group += 1;
                self.spawned.push(Spawned {
                    kind: spawner.kind,
                    pos: [xx, y as f64, zz],
                    yaw,
                    school,
                    pack: Some(pack),
                });
                self.state.after(world, kind, pos, charge);
                world
                    .bodies
                    .borrow_mut()
                    .push(World::body(kind, xx, y as f64, zz));
                if cluster >= kind.cluster {
                    return;
                }
                if kind.name == "minecraft:tropical_fish" && !school {
                    break;
                }
            }
        }
    }

    /// `isValidSpawnPostitionForType`.
    fn valid_position_for_type(
        &mut self,
        category: Category,
        spawner: &Spawner,
        kind: &TypeFacts,
        pos: [i32; 3],
        d: f64,
    ) -> bool {
        let world = self.world;
        if kind.category == Category::Misc {
            return false;
        }
        let despawn = world.facts.category(kind.category).despawn_distance;
        if !kind.spawn_far && d > (despawn * despawn) as f64 {
            return false;
        }
        // `canSpawnMobAt`: the list there holds an equal `SpawnerData` (type
        // and counts; weights are the list's), a structure's or the biome's.
        let same = |s: &Spawner| s.kind == spawner.kind && counts(s.count) == counts(spawner.count);
        if !kind.summonable || !self.list(category, pos).0.iter().any(same) {
            return false;
        }
        if !world.position_ok(kind, pos) {
            return false;
        }
        if !world.spawn_rules(kind, pos, &mut self.random) {
            return false;
        }
        world.no_collision(
            kind,
            pos[0] as f64 + 0.5,
            pos[1] as f64,
            pos[2] as f64 + 0.5,
        )
    }

    /// `isValidPositionForMob`.
    fn valid_position_for_mob(
        &self,
        kind: &TypeFacts,
        pos: [i32; 3],
        x: f64,
        z: f64,
        d: f64,
    ) -> bool {
        let world = self.world;
        let despawn = world.facts.category(kind.category).despawn_distance;
        if d > (despawn * despawn) as f64 && fresh_removal(kind) {
            return false;
        }
        world.mob_spawn_rules(kind, pos) && world.obstruction(kind, x, pos[1] as f64, z)
    }
}

/// `mobsAt` over `world` and the kept starts `structures`.
fn list_at<'w>(
    world: &'w World,
    structures: &dyn super::structures::Kept,
    category: Category,
    pos: [i32; 3],
) -> (&'w [Spawner], i32) {
    if let Some(list) = super::structures::mobs_at(world, structures, category, pos) {
        return list;
    }
    let biome = world.facts.biome(world.level.biome(pos));
    (
        &biome.spawns[category.index()],
        biome.totals[category.index()],
    )
}

/// `removeWhenFarAway` of a mob that has just spawned.
fn fresh_removal(kind: &TypeFacts) -> bool {
    kind.removal == super::facts::Removal::Always
}

/// A count provider's bounds (`SpawnerData`'s `minCount` and `maxCount`).
fn counts(count: Count) -> (i32, i32) {
    match count {
        Count::Constant(v) => (v, v),
        Count::Uniform(min, max) => (min, max),
    }
}

/// `Mth.ceil(float)`.
fn ceil(v: f32) -> i32 {
    let i = v as i32;
    if v > i as f32 {
        i + 1
    } else {
        i
    }
}

/// `spawnMobsForChunkGeneration` for chunk `(cx, cz)`, drawing from
/// `random` (decoration-seeded by the caller); the rules' own draws, which
/// vanilla takes from the region's random, use `rules`.
pub fn generate(
    world: &World,
    chunk: (i32, i32),
    random: &mut Random,
    rules: &mut Random,
) -> Vec<Spawned> {
    let mut out = Vec::new();
    let (xo, zo) = (chunk.0 * 16, chunk.1 * 16);
    let biome = world.facts.biome(world.level.biome([xo, world.max_y, zo]));
    let c = Category::Creature.index();
    let (list, total) = (&biome.spawns[c], biome.totals[c]);
    if list.is_empty() {
        return out;
    }
    let probability = biome.creature_probability;
    while random.next_float() < probability {
        let pack = out.len();
        let Some(spawner) = pick(list, total, random) else {
            continue;
        };
        let count = sample(spawner.count, random);
        let Some(kind) = world.facts.kind(spawner.kind) else {
            continue;
        };
        let (mut x, mut z) = (
            xo + random.next_int_bounded(16),
            zo + random.next_int_bounded(16),
        );
        let (sx, sz) = (x, z);
        for _ in 0..count {
            let mut success = false;
            let mut attempts = 0;
            while !success && attempts < 4 {
                attempts += 1;
                let pos = top_non_colliding(world, kind, x, z);
                if kind.summonable && world.position_ok(kind, pos) {
                    let width = kind.width as f64;
                    let fx = (x as f64).clamp(xo as f64 + width, xo as f64 + 16.0 - width);
                    let fz = (z as f64).clamp(zo as f64 + width, zo as f64 + 16.0 - width);
                    let block = [fx.floor() as i32, pos[1], fz.floor() as i32];
                    if !world.no_collision(kind, fx, pos[1] as f64, fz)
                        || !world.spawn_rules(kind, block, rules)
                    {
                        continue;
                    }
                    let yaw = random.next_float() * 360.0;
                    if world.mob_spawn_rules(kind, block)
                        && world.obstruction(kind, fx, pos[1] as f64, fz)
                    {
                        out.push(Spawned {
                            kind: spawner.kind,
                            pos: [fx, pos[1] as f64, fz],
                            yaw,
                            school: true,
                            pack: Some(pack),
                        });
                        success = true;
                    }
                }
                x += random.next_int_bounded(5) - random.next_int_bounded(5);
                z += random.next_int_bounded(5) - random.next_int_bounded(5);
                while x < xo || x >= xo + 16 || z < zo || z >= zo + 16 {
                    x = sx + random.next_int_bounded(5) - random.next_int_bounded(5);
                    z = sz + random.next_int_bounded(5) - random.next_int_bounded(5);
                }
            }
        }
    }
    out
}

/// `getTopNonCollidingPos`.
fn top_non_colliding(world: &World, kind: &TypeFacts, x: i32, z: i32) -> [i32; 3] {
    let mut pos = [x, world.level.height(kind.heightmap, x, z), z];
    if world.dimension.ceiling {
        loop {
            pos[1] -= 1;
            if is_air(world, pos) {
                break;
            }
        }
        loop {
            pos[1] -= 1;
            if !(is_air(world, pos) && pos[1] > MIN_Y) {
                break;
            }
        }
    }
    world.adjust(kind, pos)
}

fn is_air(world: &World, p: [i32; 3]) -> bool {
    world
        .states
        .flags
        .get(world.state(p) as usize)
        .copied()
        .unwrap_or(1)
        & 1
        != 0
}

/// What `Mob.checkDespawn` does to a mob this tick.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Despawn {
    Keep,
    /// `discard()`: gone, without drops.
    Discard,
    /// A player within 32 blocks: its idle time (`noActionTime`) restarts.
    Reset,
}

/// `Mob.checkDespawn` for a mob of `kind` at `pos`: `persistent` for
/// `isPersistenceRequired`, `idle` its `noActionTime`, `lived` its
/// `tickCount`; the random despawn draws from `random` (vanilla: the mob's
/// own).
pub fn despawn(
    world: &World,
    kind: &TypeFacts,
    pos: [f64; 3],
    persistent: bool,
    idle: i32,
    lived: i32,
    random: &mut Random,
) -> Despawn {
    if kind.removal == super::facts::Removal::NoCheck {
        return Despawn::Keep;
    }
    if world.difficulty == 0 && !kind.peaceful {
        return Despawn::Discard;
    }
    let Some(d) = world.nearest(pos) else {
        return Despawn::Keep;
    };
    let category = world.facts.category(kind.category);
    let far = match kind.removal {
        super::facts::Removal::Always => true,
        super::facts::Removal::Never | super::facts::Removal::NoCheck => false,
        super::facts::Removal::Aged => lived > 2400,
    };
    let instant = category.despawn_distance * category.despawn_distance;
    let mut discard = !persistent && d > instant as f64 && far;
    let near = category.no_despawn_distance * category.no_despawn_distance;
    if !persistent && idle > 600 && random.next_int_bounded(800) == 0 && d > near as f64 && far {
        discard = true;
    } else if d < near as f64 {
        return if discard {
            Despawn::Discard
        } else {
            Despawn::Reset
        };
    }
    if discard {
        Despawn::Discard
    } else {
        Despawn::Keep
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mth_ceil_rounds_up_only_fractions() {
        assert_eq!(ceil(0.0), 0);
        assert_eq!(ceil(0.25), 1);
        assert_eq!(ceil(3.0), 3);
        assert_eq!(ceil(3.999), 4);
    }

    #[test]
    fn a_weighted_pick_walks_cumulative_weights_and_an_empty_list_draws_nothing() {
        let a = Spawner {
            kind: 1,
            weight: 3,
            count: Count::Constant(1),
        };
        let b = Spawner {
            kind: 2,
            weight: 1,
            count: Count::Uniform(1, 2),
        };
        let mut random = Random::legacy(7);
        let mut seen = [0; 3];
        for _ in 0..4000 {
            seen[pick(&[a, b], 4, &mut random).unwrap().kind as usize] += 1;
        }
        assert!(seen[1] > 2700 && seen[2] > 800);
        let mut empty = Random::legacy(7);
        let before = empty.legacy_state();
        assert_eq!(pick(&[], 0, &mut empty), None);
        assert_eq!(empty.legacy_state(), before);
        // A constant count draws nothing; a uniform one always draws.
        let mut r = Random::legacy(1);
        let s = r.legacy_state();
        assert_eq!(sample(Count::Constant(4), &mut r), 4);
        assert_eq!(r.legacy_state(), s);
        assert!((1..=1).contains(&sample(Count::Uniform(1, 1), &mut r)));
        assert_ne!(r.legacy_state(), s);
    }

    #[test]
    fn shuffle_is_java_util_shuffle_over_a_legacy_random() {
        let mut items = [0, 1, 2, 3, 4];
        shuffle(&mut items, &mut Random::legacy(42));
        let mut sorted = items;
        sorted.sort();
        assert_eq!(sorted, [0, 1, 2, 3, 4]);
        assert_ne!(items, [0, 1, 2, 3, 4]);
    }
}
