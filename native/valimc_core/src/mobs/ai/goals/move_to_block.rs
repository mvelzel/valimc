//! `MoveToBlockGoal` (`Goals.MoveToBlock`): every 100 to 199 updates it
//! looks for a valid block within its search range (vanilla's spiral:
//! nearest layers first), walks to stand on it and stays there; it gives up
//! after 1,200 ticks away or a random stay. Updated every tick.

use crate::mobs::ai::fmath::reduced;
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::hooks::Tag;
use crate::mobs::ai::navigation;
use crate::mobs::ai::random_pos::within_home;
use crate::mobs::ai::turn::Turn;

/// Which blocks it goes to (`valid`).
#[derive(Clone, Debug, PartialEq)]
pub enum BlockTest {
    /// A block of these states with two blocks of air above
    /// (`ZombieAttackTurtleEggGoal`'s eggs).
    States(Vec<u16>),
    Family(Tag),
}

#[derive(Clone, Debug, PartialEq)]
pub struct MoveToBlock {
    pub speed: f64,
    pub range: i32,
    pub vertical: i32,
    pub vertical_start: i32,
    pub recalculate: i64,
    pub valid: BlockTest,
    pub next: i64,
    pub tries: i64,
    pub stay: i64,
    pub cell: [i32; 3],
    pub reached: bool,
    pub guard: Option<Tag>,
    /// `acceptedDistance`.
    pub accepted: f64,
    /// A goal's own fields its block test reads and changes (`own:`).
    pub own: Option<Box<dyn crate::mobs::ai::Opaque>>,
}

/// `MoveToBlock.new/4`'s options.
#[derive(Clone, Debug, PartialEq)]
pub struct BlockOptions {
    pub vertical: i32,
    pub vertical_start: i32,
    pub recalculate: i64,
    pub guard: Option<Tag>,
    pub accepted: f64,
}

impl Default for BlockOptions {
    fn default() -> BlockOptions {
        BlockOptions {
            vertical: 1,
            vertical_start: 0,
            recalculate: 40,
            guard: None,
            accepted: 1.0,
        }
    }
}

// `for (y = start; y <= v; y = y > 0 ? -y : 1 - y)`: 0, 1, -1, 2, -2, ...
fn spiral(from: i32, last: i32) -> impl Iterator<Item = i32> {
    std::iter::successors(Some(from), |&y| Some(if y > 0 { -y } else { 1 - y }))
        .take_while(move |&y| y <= last)
}

impl MoveToBlock {
    pub fn new(speed: f64, range: i32, valid: BlockTest, o: BlockOptions) -> MoveToBlock {
        MoveToBlock {
            speed,
            range,
            vertical: o.vertical,
            vertical_start: o.vertical_start,
            recalculate: o.recalculate,
            valid,
            next: 0,
            tries: 0,
            stay: 0,
            cell: [0; 3],
            reached: false,
            guard: o.guard,
            accepted: o.accepted,
            own: None,
        }
    }

    /// The goal's block test of `cell`.
    pub fn valid(&mut self, t: &mut Turn, cell: [i32; 3]) -> bool {
        match &self.valid {
            BlockTest::States(states) => {
                let [x, y, z] = cell;
                t.level.block(cell).is_some_and(|s| states.contains(&s))
                    && t.level.air([x, y + 1, z])
                    && t.level.air([x, y + 2, z])
            }
            BlockTest::Family(tag) => {
                let (tag, hooks) = (*tag, t.hooks);
                hooks.block(t, tag, cell, self)
            }
        }
    }

    /// `findNearestBlock`.
    pub fn find(&mut self, t: &mut Turn) -> bool {
        let [bx, by, bz] = t.block();
        let r = self.range;
        for y in spiral(self.vertical_start, self.vertical) {
            for ring in 0..r {
                for x in spiral(0, ring) {
                    let from = if x < ring && x > -ring { ring } else { 0 };
                    for z in spiral(from, ring) {
                        let cell = [bx + x, by + y - 1, bz + z];
                        if within_home(t, cell) && self.valid(t, cell) {
                            self.cell = cell;
                            return true;
                        }
                    }
                }
            }
        }
        false
    }

    // `BlockPos.closerToCenterThan(position, distance)`.
    fn close(&self, t: &Turn, [x, y, z]: [i32; 3]) -> bool {
        let d = [
            x as f64 + 0.5 - t.x(),
            y as f64 + 0.5 - t.y(),
            z as f64 + 0.5 - t.z(),
        ];
        d[0] * d[0] + d[1] * d[1] + d[2] * d[2] < self.accepted * self.accepted
    }

    fn above(&self) -> [f64; 3] {
        let [x, y, z] = self.cell;
        [x as f64 + 0.5, y as f64 + 1.0, z as f64 + 0.5]
    }
}

impl Goal for MoveToBlock {
    fn every_tick(&self) -> bool {
        true
    }

    fn can_use(&mut self, t: &mut Turn) -> bool {
        if self.next > 0 {
            self.next -= 1;
            return false;
        }
        let n = t.int(200) as i64;
        self.next = reduced(200 + n);
        // A goal's own conditions after the search.
        let found = self.find(t);
        match (found, self.guard) {
            (true, Some(tag)) => {
                let hooks = t.hooks;
                hooks.test(t, tag)
            }
            (found, _) => found,
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        if self.tries >= -self.stay && self.tries <= 1200 {
            let cell = self.cell;
            self.valid(t, cell)
        } else {
            false
        }
    }

    fn start(&mut self, t: &mut Turn) {
        navigation::move_to(t, self.above(), self.speed);
        let a = t.int(1200);
        let b = t.int(a + 1200);
        self.tries = 0;
        self.stay = b as i64 + 1200;
    }

    fn tick(&mut self, t: &mut Turn) {
        let [x, y, z] = self.cell;
        if self.close(t, [x, y + 1, z]) {
            self.reached = true;
            self.tries -= 1;
        } else {
            let tries = self.tries + 1;
            if tries % self.recalculate == 0 {
                navigation::move_to(t, self.above(), self.speed);
            }
            self.reached = false;
            self.tries = tries;
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.MoveToBlock"
    }
}
