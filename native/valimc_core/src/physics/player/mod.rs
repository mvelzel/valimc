//! The player's travel rules over the kernel's geometry (VMC-077l2): one
//! call validates a move packet (collision, vanilla's acceptance rules, pose,
//! fluids, landing and the server's own tick) and one samples a resting
//! player's tick. Effects that need the player's living state (burning,
//! landing damage, air, rain) come back as observations.

pub mod contacts;
pub mod frame;
pub mod kinetics;
pub mod paths;
pub mod pose;
pub mod rules;

use crate::physics::aabb::Aabb;
use crate::physics::border::Border;
use crate::physics::collide::{self, Extra};
use crate::physics::facts::Facts;
use crate::physics::source::{AirWhereUnreadable, BlockSource, Unreadable};
use crate::physics::table::Context;
pub use paths::{Path, Paths};

/// Why a player query failed: a cell it could not read (chunks not loaded),
/// or a bound it exceeded (named as the Elixir side names it).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fault {
    Unreadable([i32; 3]),
    Limit(&'static str),
}

/// The game mode, as far as travel cares.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Survival,
    Creative,
    Adventure,
    Spectator,
}

/// The player's accepted movement state (`Valimc.PlayerMotion`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Motion {
    pub fall_distance: f64,
    pub velocity: [f64; 3],
    pub physical_ground: bool,
    pub settled: bool,
    pub swimming: bool,
    pub paths: Paths,
    pub stuck_multiplier: [f64; 3],
    pub known_movement: [f64; 3],
    /// The client's last ground report.
    pub on_ground: bool,
    pub horizontal_collision: bool,
    pub received: bool,
}

impl Motion {
    /// `PlayerMotion.accept`: a packet's movement and its client flags.
    pub fn accept(&self, movement: [f64; 3], flags: u8, flying: bool) -> Motion {
        let ground = flags & 1 != 0;
        let (distance, _) = rules::fall_step(self.fall_distance, movement[1], ground, false);
        Motion {
            fall_distance: if flying || movement[1] > 0.0 {
                0.0
            } else {
                distance
            },
            known_movement: movement,
            on_ground: ground,
            horizontal_collision: flags & 2 != 0,
            received: true,
            ..self.clone()
        }
    }
}

/// A player as one move or tick reads it.
#[derive(Clone, Debug)]
pub struct Player {
    pub position: [f64; 3],
    pub yaw: f64,
    pub pitch: f64,
    pub pose: u8,
    pub motion: Motion,
    /// The shared flags' Shift (sneaking) and sprinting bits.
    pub shift: bool,
    pub sprint: bool,
    /// The input packet's state: loaded, and the jump and Shift buttons.
    pub loaded: bool,
    pub jump_pressed: bool,
    pub shift_pressed: bool,
    pub flying: bool,
    pub mode: Mode,
    pub invulnerable: bool,
    /// Jump Boost's amplifier (-1 for none), Slow Falling, Levitation's
    /// amplifier.
    pub jump_boost: i32,
    pub slow_falling: bool,
    pub levitation: Option<i32>,
    /// Dolphin's Grace: its water drag is 0.96.
    pub dolphins_grace: bool,
}

/// What a player query reads: blocks, solid entity observations and the border.
pub struct World<'a> {
    pub source: &'a dyn BlockSource,
    pub facts: &'a Facts,
    pub border: Option<Border>,
    pub entities: &'a [Aabb],
}

impl<'a> World<'a> {
    /// The world as a mover reads it: a spectator's unreadable cells are air
    /// (`air` wraps this world's source).
    pub fn read_by<'b>(&'b self, spectator: bool, air: &'b AirWhereUnreadable<'a>) -> World<'b> {
        World {
            source: if spectator { air } else { self.source },
            facts: self.facts,
            border: self.border,
            entities: if spectator { &[] } else { self.entities },
        }
    }

    pub fn state(&self, p: [i32; 3]) -> Result<u16, Fault> {
        self.source
            .state(p[0], p[1], p[2])
            .ok_or(Fault::Unreadable(p))
    }

    fn extra(&self, subject: [f64; 2]) -> Extra {
        Extra {
            entities: self.entities.to_vec(),
            border: self.border,
            subject,
        }
    }

    /// Whether `body` meets a block or the border, for a mover at `subject`.
    pub fn colliding(&self, body: &Aabb, ctx: &Context, subject: [f64; 2]) -> Result<bool, Fault> {
        Ok(!collide::no_collision(
            self.source,
            &self.facts.shapes,
            body,
            ctx,
            &self.extra(subject),
        )?)
    }

    /// `isEntityCollidingWithAnythingNew`.
    pub fn new_collision(&self, old: &Aabb, new: &Aabb, ctx: &Context) -> Result<bool, Fault> {
        let extra = self.extra(centre(old));
        Ok(collide::new_collision(
            self.source,
            &self.facts.shapes,
            old,
            new,
            ctx,
            &extra,
        )?)
    }

    /// The player's move against blocks with step-up (0.6) when a 0.001
    /// probe finds ground; a spectator moves freely.
    pub fn displacement(
        &self,
        body: &Aabb,
        requested: [f64; 3],
        ctx: &Context,
        spectator: bool,
    ) -> Result<[f64; 3], Fault> {
        if spectator {
            return Ok(requested);
        }
        let extra = self.extra(centre(body));
        let down = [0.0, -0.001, 0.0];
        let shapes = collide::colliders(
            self.source,
            &self.facts.shapes,
            &body.expand_towards(down),
            ctx,
            &extra,
        )?;
        let grounded = collide::collide_with(body, &shapes, down)[1] != -0.001;
        let moved = collide::collide(
            self.source,
            &self.facts.shapes,
            body,
            requested,
            ctx,
            &extra,
            0.6f32,
            grounded,
        )?;
        Ok(moved.actual)
    }
}

fn centre(b: &Aabb) -> [f64; 2] {
    [(b.min[0] + b.max[0]) / 2.0, (b.min[2] + b.max[2]) / 2.0]
}

impl From<Unreadable> for Fault {
    fn from(u: Unreadable) -> Fault {
        Fault::Unreadable(u.0)
    }
}
