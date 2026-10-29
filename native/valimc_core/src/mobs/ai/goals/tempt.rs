//! `TemptGoal` (`Goals.Tempt`): the nearest player within its tempt range
//! holding an item it wants in either hand, followed and looked at until
//! within the stop distance; a mob that can be scared stops when the player
//! moves or turns close by. After it stops it calms down for 100 ticks.

use super::{held, ItemTest};
use crate::mobs::ai::fmath::reduced;
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::navigation;
use crate::mobs::ai::turn::{Eyes, Targeting, Turn};
use crate::mobs::ai::Extra;
use crate::mobs::facts::Slot;
use crate::mobs::level::Level;
use crate::mobs::sensing::{Entity, Ref};

#[derive(Clone, Debug, PartialEq)]
pub struct Tempt {
    pub speed: f64,
    pub items: ItemTest,
    pub scare: bool,
    pub stop: f64,
    pub player: Option<Ref>,
    pub at: [f64; 3],
    /// `{pitch, yaw}`.
    pub rotation: (f64, f64),
    pub calm: i64,
    pub running: bool,
}

impl Tempt {
    pub fn new(speed: f64, items: ItemTest, scare: bool, stop: f64) -> Tempt {
        Tempt {
            speed,
            items,
            scare,
            stop,
            player: None,
            at: [0.0; 3],
            rotation: (0.0, 0.0),
            calm: 0,
            running: false,
        }
    }

    fn usable(&mut self, t: &mut Turn) -> bool {
        if self.calm > 0 {
            self.calm -= 1;
            return false;
        }
        let range = t.attribute("minecraft:tempt_range");
        let items = &self.items;
        let select = |level: &Level, eyes: &Eyes, e: Entity<'_, Extra>| {
            items.test(level, eyes.hooks, held(e, Slot::MainHand))
                || items.test(level, eyes.hooks, held(e, Slot::OffHand))
        };
        let targeting = Targeting::new(false)
            .range(range)
            .sight(false)
            .select(&select);
        let pos = t.pos();
        let player = t.nearest_player(&targeting, pos);
        self.player = player.map(|p| p.reference);
        player.is_some()
    }
}

impl Goal for Tempt {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        self.usable(t)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        if !self.scare {
            return self.usable(t);
        }
        let Some(player) = t.entity(self.player.as_ref()) else {
            return self.usable(t);
        };
        let [ax, ay, az] = self.at;
        let (rx, ry) = self.rotation;
        if t.distance_sq(player.position) < 36.0 {
            let (dx, dy, dz) = (player.x() - ax, player.y() - ay, player.z() - az);
            if dx * dx + dy * dy + dz * dz > 0.010000000000000002
                || (player.pitch - rx).abs() > 5.0
                || (player.yaw - ry).abs() > 5.0
            {
                false
            } else {
                self.rotation = (player.pitch, player.yaw);
                self.usable(t)
            }
        } else {
            self.at = player.position;
            self.rotation = (player.pitch, player.yaw);
            self.usable(t)
        }
    }

    fn start(&mut self, t: &mut Turn) {
        if let Some(p) = t.entity(self.player.as_ref()) {
            self.at = p.position;
        }
        self.running = true;
    }

    fn stop(&mut self, t: &mut Turn) {
        self.player = None;
        self.calm = reduced(100);
        self.running = false;
        navigation::stop(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        let Some(player) = t.entity(self.player.as_ref()) else {
            return;
        };
        let (y_max, x_max) = (t.facts.max_head_y_rot + 20.0, t.facts.max_head_x_rot);
        t.look_at([player.x(), player.eye_y(), player.z()], y_max, x_max);
        if t.distance_sq(player.position) < self.stop * self.stop {
            navigation::stop(t);
        } else {
            navigation::move_to_entity(t, &player, self.speed, 1);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.Tempt"
    }
}
