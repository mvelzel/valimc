//! `RemoveBlockGoal` as the zombie family's `ZombieAttackTurtleEggGoal`
//! (`Goals.RemoveBlock`): while mobs may grief, every 100 to 199 updates (10
//! after a find) it looks for its block (turtle eggs) with two blocks of air
//! above within 24 blocks around and three up and down, nearest first in
//! vanilla's order, and walks to stand on it (`MoveToBlock`). There, with an
//! egg at or around its feet, it stamps: up a little and down every other
//! tick with the egg crunching every sixth, and after three seconds the eggs
//! are gone with their breaking sound. Stopping, it lands as from a block.

use super::move_to_block::{BlockOptions, BlockTest, MoveToBlock};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{f, reduced};
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::random_pos::within_home;
use crate::mobs::ai::turn::Turn;

#[derive(Clone, Debug, PartialEq)]
pub struct RemoveBlock {
    pub base: MoveToBlock,
    pub states: Vec<u16>,
    pub since: i64,
}

impl RemoveBlock {
    /// `ZombieAttackTurtleEggGoal` over the block's `states`.
    pub fn new(states: Vec<u16>) -> RemoveBlock {
        let base = MoveToBlock::new(
            1.0,
            24,
            BlockTest::States(states.clone()),
            BlockOptions {
                vertical: 3,
                accepted: 1.14,
                ..BlockOptions::default()
            },
        );
        RemoveBlock {
            base,
            states,
            since: 0,
        }
    }

    fn egg(&self, t: &Turn, cell: [i32; 3]) -> bool {
        t.level
            .block(cell)
            .is_some_and(|s| self.states.contains(&s))
    }

    // `findNearestBlock` over the blocks the snapshots hold of its kind: the
    // valid one first in the search's order (layers 0, 1, -1, ... below its
    // feet, then rings outward, then the spiral within a ring).
    fn nearest(&mut self, t: &mut Turn) -> Option<[i32; 3]> {
        let [bx, by, bz] = t.block();
        let (r, v) = (self.base.range, self.base.vertical);
        let min = [bx - (r - 1), by - 1 - v, bz - (r - 1)];
        let max = [bx + r - 1, by - 1 + v, bz + r - 1];
        let hooks = t.hooks;
        let found = hooks.find(t.level, min, max, &self.states);
        let mut best: Option<([i32; 4], [i32; 3])> = None;
        for (cell, _) in found {
            if !(within_home(t, cell) && self.base.valid(t, cell)) {
                continue;
            }
            let key = order([cell[0] - bx, cell[1] - (by - 1), cell[2] - bz]);
            if best.is_none_or(|(k, _)| key < k) {
                best = Some((key, cell));
            }
        }
        best.map(|(_, c)| c)
    }

    // `getPosWithBlock`: its own block, below, west, east, north, south, two
    // below.
    fn at_feet(&self, t: &Turn) -> Option<[i32; 3]> {
        let [x, y, z] = t.block();
        [
            [x, y, z],
            [x, y - 1, z],
            [x - 1, y, z],
            [x + 1, y, z],
            [x, y, z - 1],
            [x, y, z + 1],
            [x, y - 2, z],
        ]
        .into_iter()
        .find(|&c| self.egg(t, c))
    }

    fn stamp(&mut self, t: &mut Turn, cell: [i32; 3]) {
        let since = self.since;
        if since > 0 {
            t.mob.body.velocity[1] = 0.3;
            for _ in 0..3 {
                t.float();
            }
        }
        if since % 2 == 0 {
            t.mob.body.velocity[1] = -0.3;
            if since % 6 == 0 {
                let r = t.float();
                let pitch = f(f(0.9) + f(r * f(0.2)));
                let [bx, by, bz] = self.base.cell;
                sound_at(
                    t,
                    "minecraft:entity.zombie.destroy_egg",
                    "hostile",
                    [bx as f64 + 0.5, by as f64 + 0.5, bz as f64 + 0.5],
                    f(0.5),
                    pitch,
                );
            }
        }
        if since > 60 {
            t.effect(Effect::RemoveBlock(cell));
            for _ in 0..60 {
                t.gaussian();
            }
            // `playBreakSound`: pitched from the level's random.
            let r = t.level.random().float() as f64;
            let pitch = f(f(0.9) + f(r * f(0.2)));
            let [cx, cy, cz] = cell;
            sound_at(
                t,
                "minecraft:entity.turtle.egg_break",
                "block",
                [cx as f64 + 0.5, cy as f64 + 0.5, cz as f64 + 0.5],
                f(0.7),
                pitch,
            );
        }
        self.since = since + 1;
    }
}

fn sound_at(t: &mut Turn, name: &str, source: &'static str, at: [f64; 3], volume: f64, pitch: f64) {
    if let Some(id) = t.level.facts.sounds.id(name) {
        t.effect(Effect::SoundAt {
            id,
            source,
            at,
            volume,
            pitch,
        });
    }
}

// The index in 0, 1, -1, 2, -2, ...
fn spiral(v: i32) -> i32 {
    if v == 0 {
        0
    } else if v > 0 {
        2 * v - 1
    } else {
        -2 * v
    }
}

fn order([dx, dy, dz]: [i32; 3]) -> [i32; 4] {
    let ring = dx.abs().max(dz.abs());
    let z = if dx.abs() < ring {
        if dz == ring {
            0
        } else {
            1
        }
    } else {
        spiral(dz)
    };
    [spiral(dy), ring, spiral(dx), z]
}

impl Goal for RemoveBlock {
    fn every_tick(&self) -> bool {
        true
    }

    fn can_use(&mut self, t: &mut Turn) -> bool {
        if !t.level.rules.mob_griefing {
            return false;
        }
        if self.base.next > 0 {
            self.base.next -= 1;
            return false;
        }
        match self.nearest(t) {
            None => {
                let n = t.int(200) as i64;
                self.base.next = reduced(200 + n);
                false
            }
            Some(cell) => {
                self.base.next = reduced(20);
                self.base.cell = cell;
                true
            }
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        self.base.can_continue(t)
    }

    fn start(&mut self, t: &mut Turn) {
        self.base.start(t);
        self.since = 0;
    }

    fn stop(&mut self, t: &mut Turn) {
        t.mob.body.mob.motion.fall_distance = 1.0;
    }

    fn tick(&mut self, t: &mut Turn) {
        self.base.tick(t);
        if let Some(cell) = self.at_feet(t) {
            if self.base.reached {
                self.stamp(t, cell);
            }
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.RemoveBlock"
    }
}
