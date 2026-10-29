//! `PanicGoal` (`Goals.Panic`): hurt in the last 40 ticks by damage of the
//! `panic_causes` tag, it runs to a random target five blocks around until
//! it gets there; with `water` (a turtle's 7) it first runs to the nearest
//! water within that many blocks around and one up or down.

use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::navigation;
use crate::mobs::ai::random_pos;
use crate::mobs::ai::turn::Turn;
use crate::mobs::level::{manhattan, FluidKind};

#[derive(Clone, Debug, PartialEq)]
pub struct Panic {
    pub speed: f64,
    pub pos: Option<[f64; 3]>,
    pub running: bool,
    pub water: Option<i32>,
}

impl Panic {
    pub fn new(speed: f64, water: Option<i32>) -> Panic {
        Panic {
            speed,
            pos: None,
            running: false,
            water,
        }
    }

    // `lookForWater`: none from inside a block that collides, else the
    // first water by manhattan distance.
    fn water(&self, t: &Turn) -> Option<[f64; 3]> {
        let radius = self.water?;
        let at = t.block();
        if t.level.collides(at) {
            return None;
        }
        manhattan(at, radius, 1, radius)
            .into_iter()
            .find(|&p| t.level.fluid(p) == FluidKind::Water)
            .map(|[x, y, z]| [x as f64, y as f64, z as f64])
    }
}

/// `getLastDamageSource` (40 ticks) of a panicking type.
pub fn panics(t: &Turn) -> bool {
    match t.mind.damage {
        Some(d) => {
            t.mind.tick - d.tick <= 40
                && t.level.facts.damage_tag(d.source, "minecraft:panic_causes")
        }
        None => false,
    }
}

impl Goal for Panic {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if !panics(t) {
            return false;
        }
        let pos = match self.water(t) {
            Some(p) => Some(p),
            None => random_pos::default(t, 5, 4),
        };
        match pos {
            Some(p) => {
                self.pos = Some(p);
                true
            }
            None => false,
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        !t.mind.navigation.done()
    }

    fn start(&mut self, t: &mut Turn) {
        if let Some(p) = self.pos {
            navigation::move_to(t, p, self.speed);
        }
        self.running = true;
    }

    fn stop(&mut self, _t: &mut Turn) {
        self.running = false;
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.Panic"
    }
}
