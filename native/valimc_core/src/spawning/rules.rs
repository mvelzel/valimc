//! The spawn rules (VMC-042a): `SpawnPlacementTypes`' position tests,
//! `SpawnPlacements`' registered predicates, light (`Monster`'s darkness,
//! `Animal`'s brightness, the walk target's light cost) and a fresh mob's own
//! `checkSpawnRules` and `checkSpawnObstruction`.

use super::facts::{
    bits, Count, DimensionFacts, Facts, Obstruction, Placement, Rule, TypeFacts, Walk,
};
use super::level::{Level, Source, WORLD_SURFACE};
use crate::facts::StateFacts;
use crate::physics::collide::{no_collision, Extra};
use crate::physics::{Aabb, Context, ShapeTable};
use crate::worldgen::random::Random;

const FULL_COLLISION: u64 = 1 << 23;
const REDSTONE_CONDUCTOR: u64 = 1 << 35;
const SIGNAL_SOURCE: u64 = 1 << 36;
const AIR: u64 = 1;

/// A player as the spawner sees it.
#[derive(Clone, Copy, Debug)]
pub struct Player {
    pub pos: [f64; 3],
    pub spectator: bool,
    pub creative: bool,
}

/// The level a spawn reads, with the tick's environment.
pub struct World<'a> {
    pub level: &'a dyn Level,
    pub facts: &'a Facts,
    pub states: &'a StateFacts,
    pub table: &'a ShapeTable,
    pub dimension: DimensionFacts,
    pub sea_level: i32,
    /// The highest block y (`getMaxY`).
    pub max_y: i32,
    /// `skyDarken` (0 at generation, as a `WorldGenRegion`'s).
    pub darken: i32,
    pub thundering: bool,
    /// 0 peaceful .. 3 hard.
    pub difficulty: i32,
    pub seed: i64,
    pub slime_chance: f32,
    /// The world border's `[min x, min z, max x, max z]`.
    pub border: [f64; 4],
    pub players: Vec<Player>,
    /// Boxes of the living entities (`blocksBuilding`) a new mob must not
    /// overlap, the tick's new mobs added as they spawn; none at generation.
    pub bodies: std::cell::RefCell<Vec<Aabb>>,
}

impl World<'_> {
    pub fn state(&self, p: [i32; 3]) -> u16 {
        self.level.state(p).unwrap_or(0)
    }

    fn flags(&self, state: u16) -> u64 {
        self.states.flags.get(state as usize).copied().unwrap_or(0)
    }

    pub fn redstone_conductor(&self, state: u16) -> bool {
        self.flags(state) & REDSTONE_CONDUCTOR != 0
    }

    fn air(&self, state: u16) -> bool {
        self.flags(state) & AIR != 0
    }

    /// The contained fluid: 0 none, 1 water, 2 lava.
    fn fluid(&self, state: u16) -> u8 {
        match self.states.fluid.get(state as usize).copied().unwrap_or(0) {
            1 | 2 => 1,
            3 | 4 => 2,
            _ => 0,
        }
    }

    fn water(&self, p: [i32; 3]) -> bool {
        self.fluid(self.state(p)) == 1
    }

    fn lava(&self, p: [i32; 3]) -> bool {
        self.fluid(self.state(p)) == 2
    }

    fn has(&self, p: [i32; 3], bit: u32) -> bool {
        self.facts.has(self.state(p), bit)
    }

    pub fn within_border(&self, x: f64, z: f64) -> bool {
        let b = self.border;
        x >= b[0] && x < b[2] && z >= b[1] && z < b[3]
    }

    fn sky(&self, p: [i32; 3]) -> i32 {
        self.level.light(p).0 as i32
    }

    fn block(&self, p: [i32; 3]) -> i32 {
        self.level.light(p).1 as i32
    }

    /// `getMaxLocalRawBrightness(pos, darken)`.
    pub fn raw(&self, p: [i32; 3], darken: i32) -> i32 {
        if p[0] < -30_000_000 || p[2] < -30_000_000 || p[0] >= 30_000_000 || p[2] >= 30_000_000 {
            return 15;
        }
        let (sky, block) = self.level.light(p);
        (sky as i32 - darken).max(block as i32)
    }

    fn can_see_sky(&self, p: [i32; 3]) -> bool {
        self.sky(p) >= 15
    }

    /// `canSeeSkyFromBelowWater`.
    fn can_see_sky_below_water(&self, p: [i32; 3]) -> bool {
        if p[1] >= self.sea_level {
            return self.can_see_sky(p);
        }
        let scan = [p[0], self.sea_level, p[2]];
        if !self.can_see_sky(scan) {
            return false;
        }
        let mut y = scan[1] - 1;
        while y > p[1] {
            if self.has([p[0], y, p[2]], bits::LIGHT_BLOCKS_SKY) {
                return false;
            }
            y -= 1;
        }
        true
    }

    /// `getPathfindingCostFromLightLevels`: the light's magic value less a
    /// half, in floats.
    fn light_cost(&self, p: [i32; 3]) -> f32 {
        let v = self.raw(p, self.darken) as f32 / 15.0f32;
        let curved = v / (4.0f32 - 3.0f32 * v);
        let a = self.dimension.ambient_light;
        (curved + a * (1.0f32 - curved)) - 0.5f32
    }

    /// `NaturalSpawner.isValidEmptySpawnBlock`.
    fn empty_spawn_block(&self, p: [i32; 3], kind: &TypeFacts) -> bool {
        let state = self.state(p);
        let flags = self.flags(state);
        flags & FULL_COLLISION == 0
            && flags & SIGNAL_SOURCE == 0
            && self.fluid(state) == 0
            && !self.facts.has(state, bits::PREVENT_SPAWNING_INSIDE)
            && !self.dangerous(state, kind)
    }

    /// `EntityType.isBlockDangerous`.
    fn dangerous(&self, state: u16, kind: &TypeFacts) -> bool {
        if kind.immune.is_some_and(|bit| self.facts.has(state, bit)) {
            return false;
        }
        if !kind.fire_immune && self.facts.has(state, bits::BURNING) {
            return true;
        }
        self.facts.has(state, bits::DANGEROUS)
    }

    /// `SpawnPlacements.isSpawnPositionOk`.
    pub fn position_ok(&self, kind: &TypeFacts, p: [i32; 3]) -> bool {
        let inside = self.within_border(p[0] as f64, p[2] as f64);
        let above = [p[0], p[1] + 1, p[2]];
        match kind.placement {
            Placement::NoRestrictions => true,
            Placement::InWater => {
                inside && self.water(p) && !self.redstone_conductor(self.state(above))
            }
            Placement::InLava => inside && self.lava(p),
            Placement::OnGround => {
                inside
                    && self
                        .facts
                        .valid_spawn(self.state([p[0], p[1] - 1, p[2]]), kind)
                    && self.empty_spawn_block(p, kind)
                    && self.empty_spawn_block(above, kind)
            }
        }
    }

    /// `SpawnPlacementType.adjustSpawnPosition` (at generation).
    pub fn adjust(&self, kind: &TypeFacts, p: [i32; 3]) -> [i32; 3] {
        let below = [p[0], p[1] - 1, p[2]];
        if kind.placement == Placement::OnGround && self.has(below, bits::PATHFINDABLE_LAND) {
            below
        } else {
            p
        }
    }

    fn sample(count: Count, random: &mut Random) -> i32 {
        match count {
            Count::Constant(v) => v,
            Count::Uniform(min, max) => random.next_int_bounded(max - min + 1) + min,
        }
    }

    /// `Monster.isDarkEnoughToSpawn`.
    fn dark(&self, p: [i32; 3], random: &mut Random) -> bool {
        if self.sky(p) > random.next_int_bounded(32) {
            return false;
        }
        let limit = self.dimension.block_light_limit;
        if limit < 15 && self.block(p) > limit {
            return false;
        }
        let brightness = if self.thundering {
            self.raw(p, 10)
        } else {
            self.raw(p, self.darken)
        };
        brightness <= Self::sample(self.dimension.monster_light, random)
    }

    /// `Animal.isBrightEnoughToSpawn`.
    fn bright(&self, p: [i32; 3]) -> bool {
        self.raw(p, 0) > 8
    }

    fn below(p: [i32; 3]) -> [i32; 3] {
        [p[0], p[1] - 1, p[2]]
    }

    fn mob_rule(&self, kind: &TypeFacts, p: [i32; 3]) -> bool {
        self.facts.valid_spawn(self.state(Self::below(p)), kind)
    }

    fn monster(&self, kind: &TypeFacts, p: [i32; 3], random: &mut Random) -> bool {
        self.dark(p, random) && self.mob_rule(kind, p)
    }

    fn animal(&self, p: [i32; 3]) -> bool {
        self.has(Self::below(p), bits::ANIMALS) && self.bright(p)
    }

    fn surface_water(&self, p: [i32; 3], low: i32, high: i32) -> bool {
        p[1] >= self.sea_level - low
            && p[1] <= self.sea_level - high
            && self.water(Self::below(p))
            && self.has([p[0], p[1] + 1, p[2]], self.facts.named.water)
    }

    fn peaceful(&self) -> bool {
        self.difficulty == 0
    }

    /// `SpawnPlacements.checkSpawnRules` at a natural spawn or a chunk's
    /// generation.
    pub fn spawn_rules(&self, kind: &TypeFacts, p: [i32; 3], random: &mut Random) -> bool {
        if !kind.peaceful && self.peaceful() {
            return false;
        }
        let biome = self.facts.biome(self.level.biome(p));
        let named = self.facts.named;
        match kind.rule {
            Rule::None | Rule::Always => true,
            Rule::Mob => self.mob_rule(kind, p),
            Rule::Monster => self.monster(kind, p, random),
            Rule::SurfaceMonster => self.monster(kind, p, random) && self.can_see_sky(p),
            Rule::Animal => self.animal(p),
            Rule::TagBright(bit) => self.has(Self::below(p), bit) && self.bright(p),
            Rule::Axolotl => self.has(Self::below(p), bits::AXOLOTLS),
            // Below the surface, half the time, dark enough for a random
            // brightness under four; then bat ground below.
            Rule::Bat => {
                p[1] < self.level.height(WORLD_SURFACE, p[0], p[2])
                    && !random.next_bool()
                    && self.raw(p, self.darken) <= random.next_int_bounded(4)
                    && self.has(Self::below(p), bits::BATS)
                    && self.mob_rule(kind, p)
            }
            Rule::SurfaceWater => self.surface_water(p, 13, 0),
            Rule::Nautilus => self.surface_water(p, 25, 5),
            Rule::TropicalFish => {
                self.water(Self::below(p))
                    && self.has([p[0], p[1] + 1, p[2]], named.water)
                    && (biome.tropical_any_height || self.surface_water(p, 13, 0))
            }
            Rule::Drowned => {
                if !self.water(Self::below(p)) {
                    return false;
                }
                let can = !self.peaceful() && self.dark(p, random) && self.water(p);
                if biome.frequent_drowned {
                    random.next_int_bounded(15) == 0 && can
                } else {
                    random.next_int_bounded(40) == 0 && p[1] < self.sea_level - 5 && can
                }
            }
            Rule::Guardian => {
                (random.next_int_bounded(20) == 0 || !self.can_see_sky_below_water(p))
                    && !self.peaceful()
                    && self.water(p)
                    && self.water(Self::below(p))
            }
            Rule::Ghast => {
                !self.peaceful() && random.next_int_bounded(20) == 0 && self.mob_rule(kind, p)
            }
            Rule::GlowSquid => {
                p[1] <= self.sea_level - 33 && self.raw(p, 0) == 0 && self.has(p, named.water)
            }
            Rule::MagmaCube => !self.peaceful(),
            Rule::Ocelot => random.next_int_bounded(3) != 0,
            Rule::NotOnWart => !self.has(Self::below(p), named.nether_wart_block),
            Rule::ZombifiedPiglin => {
                !self.peaceful() && !self.has(Self::below(p), named.nether_wart_block)
            }
            Rule::Patrolling => self.block(p) <= 8 && self.mob_rule(kind, p),
            Rule::PolarBear => {
                if biome.polar_alternate {
                    self.bright(p) && self.has(Self::below(p), bits::POLAR_ALTERNATE)
                } else {
                    self.animal(p)
                }
            }
            Rule::Slime => self.slime(kind, p, random, biome.surface_slimes),
            Rule::Stray => {
                let mut sky = [p[0], p[1] + 1, p[2]];
                while self.has(sky, named.powder_snow) {
                    sky[1] += 1;
                }
                self.monster(kind, p, random) && self.can_see_sky([sky[0], sky[1] - 1, sky[2]])
            }
            Rule::Strider => {
                let mut at = [p[0], p[1] + 1, p[2]];
                while self.lava(at) {
                    at[1] += 1;
                }
                self.air(self.state(at))
            }
            Rule::Turtle => {
                p[1] < self.sea_level + 4 && self.has(Self::below(p), bits::SAND) && self.bright(p)
            }
            Rule::NoPlayerNear => {
                let (x, y, z) = (p[0] as f64 + 0.5, p[1] as f64 + 0.5, p[2] as f64 + 0.5);
                self.mob_rule(kind, p)
                    && !self.players.iter().any(|pl| {
                        !pl.spectator && !pl.creative && distance_sqr(pl.pos, [x, y, z]) < 25.0
                    })
            }
        }
    }

    /// `Slime.checkSlimeSpawnRules` (natural): surface slimes in their
    /// biomes by the moon's chance, else slime chunks below y 40.
    fn slime(&self, kind: &TypeFacts, p: [i32; 3], random: &mut Random, surface: bool) -> bool {
        if self.peaceful() {
            return false;
        }
        if surface
            && p[1] > 50
            && p[1] < 70
            && random.next_float() < self.slime_chance
            && self.raw(p, self.darken) <= random.next_int_bounded(8)
        {
            return self.mob_rule(kind, p);
        }
        let (cx, cz) = (p[0] >> 4, p[2] >> 4);
        let chunk = slime_chunk(cx, cz, self.seed);
        if random.next_int_bounded(10) == 0 && chunk && p[1] < 40 {
            return self.mob_rule(kind, p);
        }
        false
    }

    /// A fresh mob's `checkSpawnRules` at block `p` (`PathfinderMob`: its
    /// walk target value is not negative).
    pub fn mob_spawn_rules(&self, kind: &TypeFacts, p: [i32; 3]) -> bool {
        let named = self.facts.named;
        let below = Self::below(p);
        let value = match kind.walk {
            Walk::None => return true,
            Walk::Zero => 0.0f32,
            Walk::Animal => {
                if self.has(below, named.grass_block) {
                    10.0
                } else {
                    self.light_cost(p)
                }
            }
            Walk::Mooshroom => {
                if self.has(below, named.mycelium) {
                    10.0
                } else {
                    self.light_cost(p)
                }
            }
            Walk::Monster => -self.light_cost(p),
            Walk::Silverfish => {
                if self.has(below, named.infested_host) {
                    10.0
                } else {
                    -self.light_cost(p)
                }
            }
            Walk::Guardian => {
                if self.water(p) {
                    10.0 + self.light_cost(p)
                } else {
                    -self.light_cost(p)
                }
            }
            Walk::Turtle => {
                if self.water(p) || self.has(below, bits::SAND) {
                    10.0
                } else {
                    self.light_cost(p)
                }
            }
            Walk::Strider => {
                if self.lava(p) {
                    10.0
                } else {
                    0.0
                }
            }
            Walk::Hoglin => {
                if self.has(below, named.crimson_nylium) {
                    10.0
                } else {
                    0.0
                }
            }
        };
        value >= 0.0
    }

    /// A fresh mob's bounding box at `(x, y, z)` (`EntityDimensions.makeBoundingBox`).
    pub fn body(kind: &TypeFacts, x: f64, y: f64, z: f64) -> Aabb {
        let w = kind.width as f64 / 2.0;
        Aabb::new([x - w, y, z - w], [x + w, y + kind.height as f64, z + w])
    }

    /// `containsAnyLiquid` over the blocks `BlockPos.containing` the box's corners span.
    fn any_liquid(&self, b: &Aabb) -> bool {
        let [x0, y0, z0, x1, y1, z1] = b.to_array().map(|v| v.floor() as i32);
        for x in x0..=x1 {
            for y in y0..=y1 {
                for z in z0..=z1 {
                    if self.fluid(self.state([x, y, z])) != 0 {
                        return true;
                    }
                }
            }
        }
        false
    }

    /// `isUnobstructed(mob)`: no living entity's box overlaps the mob's.
    fn unobstructed(&self, b: &Aabb) -> bool {
        let [ax0, ay0, az0, ax1, ay1, az1] = b.to_array();
        !self.bodies.borrow().iter().any(|o| {
            let [bx0, by0, bz0, bx1, by1, bz1] = o.to_array();
            ax0 < bx1 && ax1 > bx0 && ay0 < by1 && ay1 > by0 && az0 < bz1 && az1 > bz0
        })
    }

    /// A fresh mob's `checkSpawnObstruction` at `(x, y, z)`.
    pub fn obstruction(&self, kind: &TypeFacts, x: f64, y: f64, z: f64) -> bool {
        let b = Self::body(kind, x, y, z);
        match kind.obstruction {
            Obstruction::Default => !self.any_liquid(&b) && self.unobstructed(&b),
            Obstruction::Unobstructed => self.unobstructed(&b),
            Obstruction::Ocelot => {
                if !self.unobstructed(&b) || self.any_liquid(&b) {
                    return false;
                }
                let p = [x.floor() as i32, y.floor() as i32, z.floor() as i32];
                if p[1] < self.sea_level {
                    return false;
                }
                let below = self.state(Self::below(p));
                self.facts.has(below, self.facts.named.grass_block)
                    || self.facts.has(below, bits::LEAVES)
            }
        }
    }

    /// `noCollision(type.getSpawnAABB(x, y, z))`: no block collider.
    pub fn no_collision(&self, kind: &TypeFacts, x: f64, y: f64, z: f64) -> bool {
        let (w, h) = (kind.box_half as f64, kind.box_height as f64);
        let b = Aabb::new([x - w, y, z - w], [x + w, y + h, z + w]);
        let extra = Extra {
            entities: Vec::new(),
            border: None,
            subject: [x, z],
        };
        no_collision(
            &Source(self.level),
            self.table,
            &b,
            &Context::default(),
            &extra,
        )
        .unwrap_or(false)
    }

    /// The nearest player that is not a spectator, with its squared distance.
    pub fn nearest(&self, p: [f64; 3]) -> Option<f64> {
        let mut best = -1.0f64;
        for player in self.players.iter().filter(|p| !p.spectator) {
            let d = distance_sqr(player.pos, p);
            if best == -1.0 || d < best {
                best = d;
            }
        }
        (best >= 0.0).then_some(best)
    }
}

pub fn distance_sqr(a: [f64; 3], b: [f64; 3]) -> f64 {
    let (x, y, z) = (a[0] - b[0], a[1] - b[1], a[2] - b[2]);
    x * x + y * y + z * z
}

/// `WorldgenRandom.seedSlimeChunk(x, z, seed, 987234911).nextInt(10) == 0`.
pub fn slime_chunk(x: i32, z: i32, seed: i64) -> bool {
    let a = x.wrapping_mul(x).wrapping_mul(4_987_142) as i64;
    let b = x.wrapping_mul(5_947_611) as i64;
    let c = (z.wrapping_mul(z) as i64).wrapping_mul(4_392_871);
    let d = z.wrapping_mul(389_711) as i64;
    let s = seed
        .wrapping_add(a)
        .wrapping_add(b)
        .wrapping_add(c)
        .wrapping_add(d)
        ^ 987_234_911;
    Random::legacy(s).next_int_bounded(10) == 0
}
