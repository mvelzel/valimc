//! `AvoidEntityGoal` (`Goals.AvoidEntity`): the nearest entity it avoids
//! within its distance (creative and spectator players never), fled to a
//! random target up to sixteen blocks away that is farther from it,
//! walking, and sprinting within seven blocks.

use super::{exempt, EntityTest};
use crate::mobs::ai::fmath::{self, f};
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::navigation;
use crate::mobs::ai::paths::NavPath;
use crate::mobs::ai::random_pos;
use crate::mobs::ai::turn::{Eyes, Kinds, Targeting, Turn};
use crate::mobs::ai::Extra;
use crate::mobs::level::Level;
use crate::mobs::sensing::{inflate, intersects, Entity, Ref};

#[derive(Clone, Debug, PartialEq)]
pub struct AvoidEntity {
    pub select: EntityTest,
    pub distance: f64,
    pub walk: f64,
    pub sprint: f64,
    pub avoid: Option<Ref>,
    pub path: Option<NavPath>,
}

impl AvoidEntity {
    pub fn new(select: EntityTest, distance: f64, walk: f64, sprint: f64) -> AvoidEntity {
        AvoidEntity {
            select,
            distance: f(distance),
            walk,
            sprint,
            avoid: None,
            path: None,
        }
    }
}

impl Goal for AvoidEntity {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let test = &self.select;
        let hooks = t.hooks;
        let select = |level: &Level, _eyes: &Eyes, e: Entity<'_, Extra>| {
            test.test(level, hooks, e) && !(matches!(e, Entity::Player(_)) && exempt(e.mode()))
        };
        let targeting = Targeting::new(true).range(self.distance).select(&select);
        let b = inflate(&t.bbox(), self.distance, 3.0, self.distance);
        let players = |level: &Level, e: Entity<'_, Extra>| {
            test.test(level, hooks, e) && intersects(&e.bounding_box(), &b)
        };
        let pos = t.pos();
        let avoid = t.nearest_living(players, Kinds::Any, &b, &targeting, pos);
        let Some(avoid) = avoid else {
            self.avoid = None;
            return false;
        };
        self.avoid = Some(avoid.reference);
        let Some(target) = random_pos::default_away(t, 16, 7, avoid.position) else {
            return false;
        };
        if fmath::distance_sq(avoid.position, target) < t.distance_sq(avoid.position) {
            return false;
        }
        let path = navigation::path_to(t, target, 0);
        let found = path.is_some();
        self.path = path;
        found
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        !t.mind.navigation.done()
    }

    fn start(&mut self, t: &mut Turn) {
        navigation::follow(t, self.path.clone(), self.walk);
    }

    fn stop(&mut self, _t: &mut Turn) {
        self.avoid = None;
    }

    fn tick(&mut self, t: &mut Turn) {
        if let Some(avoid) = t.entity(self.avoid.as_ref()) {
            let speed = if t.distance_sq(avoid.position) < 49.0 {
                self.sprint
            } else {
                self.walk
            };
            navigation::set_speed(t, speed);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.AvoidEntity"
    }
}
