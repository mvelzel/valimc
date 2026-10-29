//! `EatBlockGoal` (`Goals.EatBlock`, a sheep grazing): one update in 1,000
//! (50 for a baby) it starts eating when it stands in a block sheep eat or
//! on grass: the eating event, its navigation stops, and 20 updates later
//! (two before the end) it eats: the grass under it turns to dirt or the
//! plant it stands in is destroyed (while mobs may grief), and it `ate`.

use crate::mobs::ai::effect::{Eaten, Effect};
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::navigation;
use crate::mobs::ai::turn::Turn;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct EatBlock {
    pub tick: i64,
}

impl EatBlock {
    pub fn new() -> EatBlock {
        EatBlock::default()
    }
}

fn edible(t: &Turn, cell: [i32; 3]) -> bool {
    let facts = t.level.facts;
    t.level
        .block(cell)
        .and_then(|s| facts.blocks.block_id(s))
        .is_some_and(|b| facts.block_tag(b, "minecraft:edible_for_sheep"))
}

fn grass(t: &Turn, cell: [i32; 3]) -> bool {
    t.level
        .block(cell)
        .is_some_and(|s| t.level.facts.blocks.is(s, "grass_block"))
}

fn eat(t: &mut Turn, cell: [i32; 3], how: Eaten) {
    if t.level.rules.mob_griefing {
        t.effect(Effect::EatBlock { cell, how });
    }
    let hooks = t.hooks;
    hooks.ate(t);
}

impl Goal for EatBlock {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let baby = t.level.facts.animal.animal(t.type_id) && t.data().age().unwrap_or(0) < 0;
        let bound = if baby { 50 } else { 1000 };
        if t.int(self.adjusted(bound) as i32) != 0 {
            return false;
        }
        let [x, y, z] = t.block();
        edible(t, [x, y, z]) || grass(t, [x, y - 1, z])
    }

    fn can_continue(&mut self, _t: &mut Turn) -> bool {
        self.tick > 0
    }

    fn start(&mut self, t: &mut Turn) {
        t.effect(Effect::Event(10));
        navigation::stop(t);
        self.tick = self.adjusted(40);
    }

    fn stop(&mut self, _t: &mut Turn) {
        self.tick = 0;
    }

    fn tick(&mut self, t: &mut Turn) {
        self.tick = (self.tick - 1).max(0);
        if self.tick == self.adjusted(4) {
            let [x, y, z] = t.block();
            if edible(t, [x, y, z]) {
                eat(t, [x, y, z], Eaten::Destroy);
            } else if grass(t, [x, y - 1, z]) {
                eat(t, [x, y - 1, z], Eaten::Dirt);
            }
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.EatBlock"
    }
}
