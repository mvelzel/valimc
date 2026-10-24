//! The End's features (VMC-026a): end islands, the obsidian spikes with
//! their crystals and cages, end gateways, the arrival platform and chorus
//! plants (with the chorus plant's and flower's shape updates).

use super::blocks::{BlockSet, BlockTable};
use super::feature::Decoration;
use super::json::Json;
use super::predicate::offset;
use super::random::Random;
use super::region::{Entity, Region};

/// `Direction.Plane.HORIZONTAL`: north, east, south, west.
const HORIZONTAL: [[i32; 3]; 4] = [[0, 0, -1], [1, 0, 0], [0, 0, 1], [-1, 0, 0]];

/// `EndIslandFeature`: a cone of end stone, narrowing downwards.
pub fn place_island(d: &Decoration, region: &mut Region, random: &mut Random, origin: [i32; 3]) {
    let end_stone = d.known().end_stone;
    let mut size = random.next_int_bounded(3) as f32 + 4.0;
    let mut y = 0;
    while size > 0.5 {
        let (low, high) = ((-size).floor() as i32, size.ceil() as i32);
        for x in low..=high {
            for z in low..=high {
                if ((x * x + z * z) as f32) <= (size + 1.0) * (size + 1.0) {
                    region.set(offset(origin, [x, y, z]), end_stone, 3);
                }
            }
        }
        size -= random.next_int_bounded(2) as f32 + 0.5;
        y -= 1;
    }
}

/// One obsidian spike (`EndSpikeFeature.EndSpike`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Spike {
    pub x: i32,
    pub z: i32,
    pub radius: i32,
    pub height: i32,
    pub guarded: bool,
}

/// `EndSpikeFeature.getSpikesForLevel`: ten spikes on a circle of radius
/// 42, their sizes shuffled by a key from the world seed.
pub fn spikes_for_seed(seed: i64) -> Vec<Spike> {
    let key = Random::legacy(seed).next_long() & 0xffff;
    let mut sizes: Vec<i32> = (0..10).collect();
    let mut random = Random::legacy(key);
    for i in (2..=10).rev() {
        let swap = random.next_int_bounded(i) as usize;
        sizes.swap(swap, i as usize - 1);
    }
    (0..10)
        .map(|i| {
            let angle = 2.0 * (-std::f64::consts::PI + (std::f64::consts::PI / 10.0) * i as f64);
            let size = sizes[i as usize];
            Spike {
                x: (42.0 * super::java::cos(angle)).floor() as i32,
                z: (42.0 * super::java::sin(angle)).floor() as i32,
                radius: 2 + size / 3,
                height: 76 + size * 3,
                guarded: size == 1 || size == 2,
            }
        })
        .collect()
}

/// `EndSpikeFeature` with the level's spikes (its configuration lists none).
#[derive(Debug)]
pub struct EndSpikes {
    configured: Vec<Spike>,
}

impl EndSpikes {
    pub fn parse(json: &Json) -> Result<EndSpikes, String> {
        let configured = json
            .field("spikes")?
            .as_array()?
            .iter()
            .map(|s| {
                let int = |k: &str| s.get(k).map_or(Ok(0), Json::as_i32);
                Ok(Spike {
                    x: int("centerX")?,
                    z: int("centerZ")?,
                    radius: int("radius")?,
                    height: int("height")?,
                    guarded: s.get("guarded").map_or(Ok(false), Json::as_bool)?,
                })
            })
            .collect::<Result<_, String>>()?;
        if json.get("crystal_invulnerable").is_some() || json.get("crystal_beam_target").is_some() {
            return Err("crystal settings are the dragon fight's, not decoration's".into());
        }
        Ok(EndSpikes { configured })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let spikes = if self.configured.is_empty() {
            spikes_for_seed(region.seed)
        } else {
            self.configured.clone()
        };
        for spike in spikes {
            if spike.x >> 4 == origin[0] >> 4 && spike.z >> 4 == origin[2] >> 4 {
                place_spike(d, region, random, spike)?;
            }
        }
        Ok(true)
    }
}

fn place_spike(
    d: &Decoration,
    region: &mut Region,
    random: &mut Random,
    spike: Spike,
) -> Result<(), String> {
    let min_y = region.min_y();
    spike_blocks(d, spike, min_y, |p, block| {
        region.set(p, block, 3);
    })?;
    let known = d.known();
    let table = d.table.as_ref();
    let yaw = random.next_float() * 360.0;
    region.add_entity(Entity {
        kind: "minecraft:end_crystal",
        pos: [
            spike.x as f64 + 0.5,
            (spike.height + 1) as f64,
            spike.z as f64 + 0.5,
        ],
        yaw,
        ..Entity::default()
    });
    let crystal = [spike.x, spike.height + 1, spike.z];
    region.set(offset(crystal, [0, -1, 0]), known.bedrock, 3);
    let fire = d
        .rules
        .fire
        .state_at(table, &mut |p| region.get(p), crystal);
    region.set(crystal, fire, 3);
    Ok(())
}

// Decoration and live regeneration visit the same ordered geometry.
fn spike_blocks(
    d: &Decoration,
    spike: Spike,
    min_y: i32,
    mut emit: impl FnMut([i32; 3], u16),
) -> Result<(), String> {
    let known = d.known();
    let table = d.table.as_ref();
    let air = table.default_state("air")?;
    let r = spike.radius;
    // `BlockPos.betweenClosed`: X fastest, then Y, then Z.
    for z in spike.z - r..=spike.z + r {
        for y in min_y..=spike.height + 10 {
            for x in spike.x - r..=spike.x + r {
                let (dx, dz) = ((x - spike.x) as f64, (z - spike.z) as f64);
                if dx * dx + dz * dz <= (r * r + 1) as f64 && y < spike.height {
                    emit([x, y, z], known.obsidian);
                } else if y > 65 {
                    emit([x, y, z], air);
                }
            }
        }
    }
    if spike.guarded {
        for dx in -2..=2 {
            for dz in -2..=2 {
                for dy in 0..=3 {
                    let (x_side, z_side, top) = (dx == -2 || dx == 2, dz == -2 || dz == 2, dy == 3);
                    if !(x_side || z_side || top) {
                        continue;
                    }
                    let x_edge = x_side || top;
                    let z_edge = z_side || top;
                    let mut bars = known.iron_bars;
                    for (property, on) in [
                        ("north", x_edge && dz != -2),
                        ("south", x_edge && dz != 2),
                        ("west", z_edge && dx != -2),
                        ("east", z_edge && dx != 2),
                    ] {
                        bars = table
                            .with(bars, property, if on { "true" } else { "false" })
                            .ok_or("iron bars")?;
                    }
                    emit([spike.x + dx, spike.height + dy, spike.z + dz], bars);
                }
            }
        }
    }
    Ok(())
}

/// A live ritual's bounded blueprint, after its 21-cube was cleared.
/// The caller runs this CPU work outside the simulation owner.
pub fn pillar_plan(d: &Decoration, spike: Spike) -> Result<Vec<([i32; 3], u16)>, String> {
    let mut writes = Vec::new();
    spike_blocks(d, spike, d.dimension.0, |p, block| writes.push((p, block)))?;
    let base = [spike.x, spike.height, spike.z];
    let crystal = offset(base, [0, 1, 0]);
    let bedrock = d.known().bedrock;
    let air = d.table.default_state("air")?;
    writes.push((base, bedrock));
    let fire = d.rules.fire.state_at(
        &d.table,
        &mut |p| {
            if p == base {
                bedrock
            } else {
                air
            }
        },
        crystal,
    );
    writes.push((crystal, fire));
    Ok(writes)
}

/// `EndGatewayFeature`: a gateway in a bedrock frame, its block entity sent
/// to the configured exit.
#[derive(Debug)]
pub struct EndGateway {
    exit: Option<([i32; 3], bool)>,
}

impl EndGateway {
    pub fn parse(json: &Json) -> Result<EndGateway, String> {
        let exact = json.field("exact")?.as_bool()?;
        let exit = match json.get("exit") {
            None => None,
            Some(e) => {
                let e = e.as_array()?;
                Some(([e[0].as_i32()?, e[1].as_i32()?, e[2].as_i32()?], exact))
            }
        };
        Ok(EndGateway { exit })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let known = d.known();
        for z in origin[2] - 1..=origin[2] + 1 {
            for y in origin[1] - 2..=origin[1] + 2 {
                for x in origin[0] - 1..=origin[0] + 1 {
                    let pos = [x, y, z];
                    let (same_x, same_y, same_z) = (x == origin[0], y == origin[1], z == origin[2]);
                    let end = (y - origin[1]).abs() == 2;
                    let state = if same_x && same_y && same_z {
                        region.set(pos, known.end_gateway, 3);
                        if let Some(exit) = self.exit {
                            if let Some(entity) = region.block_entity(pos)? {
                                if entity.kind == "minecraft:end_gateway" {
                                    entity.exit = Some(exit);
                                }
                            }
                        }
                        continue;
                    } else if same_y {
                        region.air
                    } else if (end && same_x && same_z) || ((same_x || same_z) && !end) {
                        known.bedrock
                    } else {
                        region.air
                    };
                    region.set(pos, state, 3);
                }
            }
        }
        Ok(true)
    }
}

/// `EndPlatformFeature.createEndPlatform`: an obsidian floor with air above.
pub fn place_platform(d: &Decoration, region: &mut Region, origin: [i32; 3]) {
    let known = d.known();
    let table = d.table.as_ref();
    for dz in -2..=2 {
        for dx in -2..=2 {
            for dy in -1..3 {
                let pos = offset(origin, [dx, dy, dz]);
                let state = if dy == -1 { known.obsidian } else { region.air };
                if table.block_of(region.get(pos)) != table.block_of(state) {
                    region.set(pos, state, 3);
                }
            }
        }
    }
}

/// Chorus plants and flowers (`ChorusPlantBlock`, `ChorusFlowerBlock`).
#[derive(Debug)]
pub struct Chorus {
    plant_block: u16,
    flower_block: u16,
    plant: u16,
    dead_flower: u16,
    supports_plant: BlockSet,
    supports_flower: BlockSet,
}

/// A pipe block's property toward each direction, in `Direction` order.
const PIPE: [&str; 6] = ["down", "up", "north", "south", "west", "east"];
const STEPS: [[i32; 3]; 6] = [
    [0, -1, 0],
    [0, 1, 0],
    [0, 0, -1],
    [0, 0, 1],
    [-1, 0, 0],
    [1, 0, 0],
];

impl Chorus {
    pub fn new(table: &BlockTable) -> Result<Chorus, String> {
        let flower = table.default_state("chorus_flower")?;
        Ok(Chorus {
            plant_block: table.block("chorus_plant")?,
            flower_block: table.block("chorus_flower")?,
            plant: table.default_state("chorus_plant")?,
            dead_flower: table.with(flower, "age", "5").ok_or("chorus flower age")?,
            supports_plant: table.tag("minecraft:supports_chorus_plant")?.clone(),
            supports_flower: table.tag("minecraft:supports_chorus_flower")?.clone(),
        })
    }

    /// `ChorusPlantBlock.getStateWithConnections`.
    fn connected(
        &self,
        table: &BlockTable,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        pos: [i32; 3],
    ) -> u16 {
        let mut state = self.plant;
        for (d, step) in STEPS.iter().enumerate() {
            let neighbour = read(offset(pos, *step));
            let block = table.block_of(neighbour);
            let on = block == self.plant_block
                || block == self.flower_block
                || (d == 0 && table.in_tag(neighbour, &self.supports_plant));
            state = table
                .with(state, PIPE[d], if on { "true" } else { "false" })
                .unwrap_or(state);
        }
        state
    }

    fn all_neighbours_empty(
        &self,
        region: &mut Region,
        pos: [i32; 3],
        ignore: Option<usize>,
    ) -> bool {
        HORIZONTAL
            .iter()
            .enumerate()
            .all(|(i, step)| ignore == Some(i) || region.is_air_at(offset(pos, *step)))
    }

    fn set_connected(&self, table: &BlockTable, region: &mut Region, pos: [i32; 3]) {
        let state = self.connected(table, &mut |p| region.get(p), pos);
        region.set(pos, state, 2);
    }

    /// `ChorusPlantFeature`: on a chorus-supporting block,
    /// `ChorusFlowerBlock.generatePlant` with a spread of 8.
    pub fn place_plant(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> bool {
        let table = d.table.as_ref();
        if !region.is_air_at(origin)
            || !table.in_tag(region.get(offset(origin, [0, -1, 0])), &self.supports_plant)
        {
            return false;
        }
        self.set_connected(table, region, origin);
        self.grow(table, region, random, origin, origin, 8, 0);
        true
    }

    /// `ChorusFlowerBlock.growTreeRecursive`.
    #[allow(clippy::too_many_arguments)]
    fn grow(
        &self,
        table: &BlockTable,
        region: &mut Region,
        random: &mut Random,
        current: [i32; 3],
        start: [i32; 3],
        spread: i32,
        depth: i32,
    ) {
        let mut height = random.next_int_bounded(4) + 1;
        if depth == 0 {
            height += 1;
        }
        for i in 0..height {
            let target = offset(current, [0, i + 1, 0]);
            if !self.all_neighbours_empty(region, target, None) {
                return;
            }
            self.set_connected(table, region, target);
            self.set_connected(table, region, offset(target, [0, -1, 0]));
        }
        let mut placed_stem = false;
        if depth < 4 {
            let mut stems = random.next_int_bounded(4);
            if depth == 0 {
                stems += 1;
            }
            for _ in 0..stems {
                let dir = random.next_int_bounded(4) as usize;
                let opposite = (dir + 2) % 4;
                let target = offset(offset(current, [0, height, 0]), HORIZONTAL[dir]);
                if (target[0] - start[0]).abs() < spread
                    && (target[2] - start[2]).abs() < spread
                    && region.is_air_at(target)
                    && region.is_air_at(offset(target, [0, -1, 0]))
                    && self.all_neighbours_empty(region, target, Some(opposite))
                {
                    placed_stem = true;
                    self.set_connected(table, region, target);
                    self.set_connected(table, region, offset(target, HORIZONTAL[opposite]));
                    self.grow(table, region, random, target, start, spread, depth + 1);
                }
            }
        }
        if !placed_stem {
            region.set(offset(current, [0, height, 0]), self.dead_flower, 2);
        }
    }

    /// `ChorusPlantBlock.canSurvive`.
    fn plant_survives(
        &self,
        table: &BlockTable,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        pos: [i32; 3],
    ) -> bool {
        let below = read(offset(pos, [0, -1, 0]));
        let above_and_below = !table.is_air(read(offset(pos, [0, 1, 0]))) && !table.is_air(below);
        for step in HORIZONTAL {
            let side = offset(pos, step);
            if table.block_of(read(side)) == self.plant_block {
                if above_and_below {
                    return false;
                }
                let under = read(offset(side, [0, -1, 0]));
                if table.block_of(under) == self.plant_block
                    || table.in_tag(under, &self.supports_plant)
                {
                    return true;
                }
            }
        }
        table.block_of(below) == self.plant_block || table.in_tag(below, &self.supports_plant)
    }

    /// `ChorusFlowerBlock.canSurvive`.
    fn flower_survives(
        &self,
        table: &BlockTable,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        pos: [i32; 3],
    ) -> bool {
        let below = read(offset(pos, [0, -1, 0]));
        if table.block_of(below) == self.plant_block || table.in_tag(below, &self.supports_flower) {
            return true;
        }
        if !table.is_air(below) {
            return false;
        }
        let mut one = false;
        for step in HORIZONTAL {
            let side = read(offset(pos, step));
            if table.block_of(side) == self.plant_block {
                if one {
                    return false;
                }
                one = true;
            } else if !table.is_air(side) {
                return false;
            }
        }
        one
    }

    /// `updateShape` of a chorus plant or flower toward direction `d`: the
    /// new state and whether it schedules a tick of its block (at its own
    /// position); `None` for other states.
    pub fn update_shape(
        &self,
        table: &BlockTable,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        state: u16,
        pos: [i32; 3],
        d: usize,
    ) -> Option<(u16, Option<u16>)> {
        let block = table.block_of(state);
        if block == self.flower_block {
            let tick = d != 1 && !self.flower_survives(table, read, pos);
            return Some((state, tick.then_some(block)));
        }
        if block != self.plant_block {
            return None;
        }
        if !self.plant_survives(table, read, pos) {
            return Some((state, Some(block)));
        }
        let neighbour = read(offset(pos, STEPS[d]));
        let other = table.block_of(neighbour);
        let on = other == self.plant_block
            || other == self.flower_block
            || (d == 0 && table.in_tag(neighbour, &self.supports_plant));
        Some((
            table
                .with(state, PIPE[d], if on { "true" } else { "false" })
                .unwrap_or(state),
            None,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spikes_match_vanilla_for_a_seed() {
        // Vanilla's crystals for seed 20261020 (DecorationOracle end): ten
        // spikes on a circle, the sixth at z -1 from the sine of -π.
        let spikes = spikes_for_seed(20261020);
        let centres: Vec<_> = spikes.iter().map(|s| (s.x, s.z, s.height)).collect();
        assert_eq!(
            centres,
            vec![
                (42, 0, 100),
                (33, 24, 91),
                (12, 39, 97),
                (-13, 39, 94),
                (-34, 24, 85),
                (-42, -1, 103),
                (-34, -25, 88),
                (-13, -40, 79),
                (12, -40, 82),
                (33, -25, 76)
            ]
        );
        let guarded: Vec<_> = spikes
            .iter()
            .filter(|s| s.guarded)
            .map(|s| s.height)
            .collect();
        assert_eq!(guarded, vec![79, 82]);
    }
}
