//! The player's server-side velocity (vanilla `Player.travel` from the
//! server's view): an accepted move packet's jump, collision and restitution,
//! and the server's own tick — currents, fluid controls, swimming steering,
//! climbing, sneaking at edges, collision, restitution, dry or fluid travel —
//! with the contacts the moves passed. It never moves the accepted position.

use super::contacts::{self, Body, Slowing, Touched, Toucher};
use super::paths::{self, Paths};
use super::pose;
use super::rules::{self, Air, FluidControls, FluidMotion, SneakEdges, Step, EPSILON};
use super::{Fault, Motion, Player, World};
use crate::physics::aabb::Aabb;
use crate::physics::facts::EMPTY;
use crate::physics::fluid::{self, Depths, Pushed};
use crate::physics::response::{self, Response};
use crate::physics::support;

/// `getOnPos(0.500001F)`'s offset below the feet.
const BELOW: f32 = 0.500001;

fn add(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn union(a: Aabb, b: Aabb) -> Aabb {
    Aabb::new(
        std::array::from_fn(|i| a.min[i].min(b.min[i])),
        std::array::from_fn(|i| a.max[i].max(b.max[i])),
    )
}

/// What a body stands on: the movement facts below and at the feet, the
/// supporting block, and the legacy landing block.
pub struct Material {
    pub below: crate::physics::facts::Motion,
    pub feet: crate::physics::facts::Motion,
    pub support: Option<([i32; 3], u16)>,
    pub below_position: [i32; 3],
    pub legacy: ([i32; 3], u16),
}

impl World<'_> {
    /// The footing of `body` at `position` (the kernel's supporting block
    /// and `getOnPos` lookups) with its movement facts.
    pub fn material(
        &self,
        body: &Aabb,
        position: [f64; 3],
        ctx: &crate::physics::Context,
    ) -> Result<Material, Fault> {
        let support = support::supporting(self.source, self.facts, body, position, [0.0; 3], ctx)?;
        let below = support::on_pos(self.source, self.facts, support, position, BELOW)?;
        let legacy = support::on_pos(self.source, self.facts, support, position, 0.2)?;
        let feet = position.map(|v| v.floor() as i32);
        let cell = |p: [i32; 3]| -> Result<([i32; 3], u16), Fault> { Ok((p, self.state(p)?)) };
        let below_cell = cell(below)?;
        let feet_cell = cell(feet)?;
        Ok(Material {
            below: *self.facts.motion(below_cell.1),
            feet: *self.facts.motion(feet_cell.1),
            support: support.map(cell).transpose()?,
            below_position: below,
            legacy: cell(legacy)?,
        })
    }

    /// The water and lava depths over a body (at most 512 cells).
    pub fn depths(&self, body: &Aabb) -> Result<Depths, Fault> {
        self.fluid_bounded(body)?;
        let found = fluid::contacts(self.source, self.facts, body)?
            .ok_or(Fault::Limit("invalid_fluid_box"))?;
        Ok(fluid::depths(&found))
    }

    /// Whether the eye is under water and lava.
    pub fn eyes(&self, body: &Aabb, eye: [f64; 3]) -> Result<(bool, bool), Fault> {
        self.fluid_bounded(body)?;
        fluid::eyes(self.source, self.facts, body, eye)?.ok_or(Fault::Limit("invalid_fluid_box"))
    }

    fn any_liquid(&self, body: &Aabb) -> Result<bool, Fault> {
        self.fluid_bounded(body)?;
        fluid::any_liquid(self.source, self.facts, body)?.ok_or(Fault::Limit("invalid_fluid_box"))
    }

    pub(crate) fn fluid_bounded(&self, b: &Aabb) -> Result<(), Fault> {
        const INSET: f64 = 0.001;
        if !(b.max[0] - b.min[0] > 2.0 * INSET
            && b.max[1] - b.min[1] > 2.0 * INSET
            && b.max[2] - b.min[2] > 2.0 * INSET)
        {
            return Err(Fault::Limit("invalid_fluid_box"));
        }
        let cells: i64 = (0..3)
            .map(|i| ((b.max[i] - INSET).ceil() as i64 - 1) - (b.min[i] + INSET).floor() as i64 + 1)
            .product();
        if cells > 512 {
            return Err(Fault::Limit("fluid_scan_limit"));
        }
        Ok(())
    }

    /// The player's push by currents and its depths (`FluidCurrents.sample`).
    fn currents(
        &self,
        body: &Aabb,
        velocity: [f64; 3],
        pushed: bool,
    ) -> Result<(Depths, [f64; 3]), Fault> {
        if !rules::bounded(velocity, 64.0) {
            return Err(Fault::Limit("invalid_fluid_current"));
        }
        self.fluid_bounded(body)?;
        let (d, v) = fluid::current(
            self.source,
            self.facts,
            body,
            velocity,
            pushed,
            false,
            Pushed::Player,
        )?
        .ok_or(Fault::Limit("invalid_fluid_box"))?;
        if !rules::bounded(v, 64.0) {
            return Err(Fault::Limit("fluid_velocity_limit"));
        }
        Ok((d, v))
    }

    /// Whether `body` (offset by an escape) is free of colliders and fluid.
    pub(crate) fn free(
        &self,
        body: &Aabb,
        ctx: &crate::physics::Context,
        subject: [f64; 3],
    ) -> Result<bool, Fault> {
        Ok(!self.colliding(body, ctx, [subject[0], subject[2]])? && !self.any_liquid(body)?)
    }
}

/// A packet's or tick's effect on the player's velocity and state.
#[derive(Clone, Debug, PartialEq)]
pub struct Kinetics {
    pub velocity: [f64; 3],
    pub physical_ground: bool,
    pub settled: bool,
    pub bounced: bool,
    pub water: bool,
    pub lava: bool,
    pub reset_fall: bool,
    pub stuck_multiplier: [f64; 3],
    pub paths: Paths,
    /// The tick's fire, fluid and hazard contacts (none for a packet).
    pub touched: Touched,
}

/// `PlayerKinetics.apply_result`: the motion after a packet's or tick's
/// kinetics.
pub fn apply(motion: &Motion, k: &Kinetics) -> Motion {
    let mut m = motion.clone();
    m.velocity = k.velocity;
    m.physical_ground = k.physical_ground;
    m.settled = k.settled;
    m.paths = k.paths.clone();
    m.stuck_multiplier = k.stuck_multiplier;
    if k.water || k.reset_fall {
        m.fall_distance = 0.0;
    } else if k.lava {
        m.fall_distance *= 0.5;
    }
    m
}

impl Player {
    /// The player's collision context at `bottom` with fall distance `fall`.
    pub fn context(&self, fall: f64, bottom: f64) -> crate::physics::Context {
        crate::physics::Context {
            entity: true,
            bottom,
            descending: self.shift,
            placement: false,
            entity_present: true,
            fall_distance: fall,
            falling_block: false,
            powder_snow_walkable: false,
        }
    }

    pub fn spectator(&self) -> bool {
        self.mode == super::Mode::Spectator
    }

    fn jump_held(&self) -> bool {
        self.loaded && self.jump_pressed
    }

    fn swimming_candidate(&self) -> bool {
        self.motion.swimming || self.sprint
    }

    /// Whether a packet's move is a jump (on the ground, now in the air,
    /// rising).
    pub fn jumping(&self, dy: f64, flags: u8) -> bool {
        self.motion.on_ground && flags & 1 == 0 && dy > 0.0
    }

    /// Consume the slowing multiplier before collision (`makeStuckInBlock`).
    pub fn prepare_move(&self, requested: [f64; 3], velocity: [f64; 3]) -> Result<Step, Fault> {
        if self.spectator() {
            return Ok(Step {
                requested,
                velocity,
                multiplier: self.motion.stuck_multiplier,
            });
        }
        let step = rules::stuck_prepare(requested, velocity, self.motion.stuck_multiplier)?;
        if !rules::bounded(step.requested, 64.0) {
            return Err(Fault::Limit("kinetic_query_limit"));
        }
        Ok(step)
    }

    /// Where a move leaves the player: blocked tiny moves do not move it.
    pub fn physical_position(&self, actual: [f64; 3], requested: [f64; 3]) -> [f64; 3] {
        if self.spectator() || paths::records(actual, requested) {
            add(self.position, actual)
        } else {
            self.position
        }
    }

    /// The box a packet's or tick's collision work may read: the moves with
    /// and without a jump, an escape, a margin and the retained paths.
    pub fn query_box(
        &self,
        catalog: &[pose::Dimensions],
        body: &Aabb,
        jumping: bool,
    ) -> Result<Aabb, Fault> {
        let limit = Fault::Limit("kinetic_query_limit");
        let v = self.motion.velocity;
        if !rules::bounded(v, 64.0) {
            return Err(limit);
        }
        let jump_v = if jumping {
            rules::jump(v, 1.0, self.sprint, self.yaw, self.jump_boost).map_err(|_| limit)?
        } else {
            v
        };
        if !rules::bounded(jump_v, 64.0) {
            return Err(limit);
        }
        let scaled = self.prepare_move(v, v).map_err(|_| limit)?;
        let scaled_jump = self.prepare_move(jump_v, jump_v).map_err(|_| limit)?;
        let escape = [2.0 * v[0], v[1] + 0.6000000238418579, 2.0 * v[2]];
        if !rules::bounded(escape, 64.0) {
            return Err(limit);
        }
        let margin = if self.swimming_candidate() {
            0.25
        } else {
            0.125
        };
        let b = union(
            union(
                union(body.expand_towards(v), body.expand_towards(jump_v)),
                body.expand_towards(scaled.requested),
            ),
            body.expand_towards(scaled_jump.requested),
        )
        .expand_towards([0.0, 0.6, 0.0])
        .expand_towards([0.0, -(BELOW as f64), 0.0]);
        let b = union(b, body.expand_towards(escape)).inflate(margin);
        paths::enclose(catalog, &self.motion.paths, b)
    }

    /// The move after slowing and sneaking at an edge.
    pub fn prepare_collision(
        &self,
        w: &World,
        requested: [f64; 3],
        velocity: [f64; 3],
        body: &Aabb,
        on_ground: bool,
        fall: f64,
    ) -> Result<Step, Fault> {
        let step = self.prepare_move(requested, velocity)?;
        let ctx = self.context(fall, self.position[1]);
        let subject = [self.position[0], self.position[2]];
        let (edge, _) = rules::sneak_edges(
            body,
            step.requested,
            &SneakEdges {
                flying: self.flying || self.spectator(),
                shift: self.shift,
                on_ground,
                fall_distance: fall,
                ..SneakEdges::default()
            },
            &mut |q| Ok(!w.colliding(q, &ctx, subject)?),
        )?;
        Ok(Step {
            requested: edge,
            ..step
        })
    }

    fn record_path(&self, from: [f64; 3], actual: [f64; 3], requested: [f64; 3]) -> Paths {
        let mut p = self.motion.paths.clone();
        if !self.spectator() {
            paths::record(&mut p, from, actual, requested);
        }
        p
    }

    fn response(
        &self,
        velocity: [f64; 3],
        requested: [f64; 3],
        actual: [f64; 3],
        m: &Material,
    ) -> Result<([f64; 3], bool), Fault> {
        if !rules::bounded(velocity, 64.0) {
            return Err(Fault::Limit("invalid_collision_response"));
        }
        let vertical = requested[1] != actual[1];
        let r = response::respond(
            velocity,
            actual[1],
            &Response {
                x_collision: (requested[0] - actual[0]).abs() >= EPSILON,
                z_collision: (requested[2] - actual[2]).abs() >= EPSILON,
                vertical_collision: vertical,
                below: vertical && requested[1] < 0.0,
                suppress_bounce: self.shift,
                block_suppresses_bounce: m.below.suppresses_bounce,
                block_bounciness: m.below.bounciness as f64,
                ..Response::default()
            },
        );
        let factor = if m.feet.speed_factor == 1.0 {
            m.below.speed_factor
        } else {
            m.feet.speed_factor
        } as f64;
        let [x, y, z] = r.velocity;
        Ok(([x * factor, y, z * factor], r.bounced))
    }

    /// An accepted move packet's jump, collision and restitution.
    pub fn packet(
        &self,
        w: &World,
        destination: [f64; 3],
        actual: [f64; 3],
        flags: u8,
        body: &Aabb,
    ) -> Result<Kinetics, Fault> {
        let fall = self.motion.fall_distance;
        let requested = sub(destination, self.position);
        let before = w.material(body, self.position, &self.context(fall, self.position[1]))?;
        let depths = w.depths(body)?;
        let velocity = if self.jumping(requested[1], flags) {
            let factor = if before.feet.jump_factor == 1.0 {
                before.below.jump_factor
            } else {
                before.feet.jump_factor
            } as f64;
            let (_, ground_jump) = rules::fluid_controls(
                self.motion.velocity,
                &FluidControls {
                    water: depths.water,
                    lava: depths.lava,
                    on_ground: true,
                    jump: true,
                    flying: self.flying,
                    ..FluidControls::default()
                },
            )?;
            if ground_jump {
                rules::jump(
                    self.motion.velocity,
                    factor,
                    self.sprint,
                    self.yaw,
                    self.jump_boost,
                )?
            } else {
                self.motion.velocity
            }
        } else {
            self.motion.velocity
        };
        let step =
            self.prepare_collision(w, requested, velocity, body, self.motion.on_ground, fall)?;
        let moved = self.physical_position(actual, step.requested);
        let moved_body = body.moved(sub(moved, self.position));
        let after = w.material(&moved_body, moved, &self.context(fall, moved[1]))?;
        let after_fluid = w.depths(&moved_body)?;
        let (velocity, bounced) = self.response(step.velocity, step.requested, actual, &after)?;
        Ok(Kinetics {
            velocity,
            physical_ground: after.support.is_some(),
            settled: false,
            bounced,
            water: after_fluid.water > 0.0,
            lava: false,
            reset_fall: false,
            stuck_multiplier: step.multiplier,
            paths: self.record_path(self.position, actual, step.requested),
            touched: Touched::default(),
        })
    }

    fn climb_contact(&self, w: &World, p: [f64; 3]) -> Result<(bool, bool), Fault> {
        contacts::climb(
            w.source,
            w.facts,
            p.map(|v| v.floor() as i32),
            self.flying,
            self.spectator(),
            false,
        )
    }

    /// One server tick of the player's velocity in `pose`.
    pub fn tick(
        &self,
        w: &World,
        catalog: &[pose::Dimensions],
        pose_id: u8,
    ) -> Result<Kinetics, Fault> {
        let motion = &self.motion;
        let reset_fall = self.slow_falling || self.levitation.is_some();
        // aiStep resets the fall distance before travel observations.
        let mut fall = if reset_fall {
            0.0
        } else {
            motion.fall_distance
        };
        let position = self.position;
        let geometry = pose::geometry(catalog, pose_id, position)?;
        let body = geometry.body;
        let before = w.material(&body, position, &self.context(fall, position[1]))?;
        let touched = contacts::touched(
            w.source,
            w.facts,
            catalog,
            &paths::collect(&motion.paths, position, position),
            &self.context(fall, position[1]),
            &Toucher {
                body: Body {
                    pose: pose_id,
                    feet: position,
                    flying: self.flying,
                    spectator: self.spectator(),
                    weaving: false,
                },
                grounded: motion.physical_ground,
                careful: self.shift,
                known_movement: motion.known_movement,
                support_state: before.legacy.1,
            },
        )?;
        let (depths, current) = w.currents(&body, motion.velocity, !self.flying)?;
        let in_fluid = !self.flying && (depths.water > 0.0 || depths.lava > 0.0);
        let controlled = if in_fluid {
            rules::fluid_controls(
                current,
                &FluidControls {
                    water: depths.water,
                    lava: depths.lava,
                    on_ground: motion.physical_ground,
                    jump: self.jump_held(),
                    shift: self.loaded && self.shift_pressed,
                    ..FluidControls::default()
                },
            )?
            .0
        } else {
            rules::normalize(current)
        };
        let steered = if motion.swimming && !self.flying && !self.spectator() {
            let jump = self.jump_held();
            let look = rules::look_y(self.pitch)?;
            let above = if look <= 0.0 || jump {
                false
            } else {
                let p = [
                    position[0].floor() as i32,
                    (position[1] + 1.0 - 0.1).floor() as i32,
                    position[2].floor() as i32,
                ];
                w.facts.fluid(w.state(p)?).kind != EMPTY
            };
            rules::swim_steer(controlled, look, true, jump, above, false)?
        } else {
            controlled
        };
        let (velocity, climb_reset) = if in_fluid {
            (steered, false)
        } else {
            let (climbing, scaffolding) = self.climb_contact(w, position)?;
            rules::climb_prepare(steered, climbing, self.shift, scaffolding)?
        };
        // Dry climbing clears the fall distance before collision contexts.
        if climb_reset {
            fall = 0.0;
        }
        let spectator = self.spectator();
        let step =
            self.prepare_collision(w, velocity, velocity, &body, motion.physical_ground, fall)?;
        let actual = w.displacement(
            &body,
            step.requested,
            &self.context(fall, position[1]),
            spectator,
        )?;
        let moved = self.physical_position(actual, step.requested);
        let after = w.material(
            &body.moved(sub(moved, position)),
            moved,
            &self.context(fall, moved[1]),
        )?;
        let (resolved, bounced) = self.response(step.velocity, step.requested, actual, &after)?;
        let horizontal = (step.requested[0] - actual[0]).abs() >= EPSILON
            || (step.requested[2] - actual[2]).abs() >= EPSILON;
        let next = if in_fluid {
            let gravity = rules::gravity(0.08, velocity[1], self.slow_falling);
            let climbing = if horizontal && depths.water > 0.0 {
                self.climb_contact(w, moved)?.0
            } else {
                false
            };
            let (v, escape) = rules::fluid_motion(
                resolved,
                &FluidMotion {
                    lava: depths.water <= 0.0,
                    gravity,
                    falling: velocity[1] <= 0.0,
                    on_ground: motion.physical_ground,
                    sprint: self.sprint,
                    horizontal_collision: horizontal,
                    climbable: climbing,
                    shallow: depths.lava <= 0.4,
                    old_y: position[1],
                    new_y: moved[1],
                    ..FluidMotion::default()
                },
            )?;
            let free = match escape {
                None => false,
                Some(offset) => w.free(
                    &body.moved(sub(moved, position)).moved(offset),
                    &self.context(fall, moved[1]),
                    position,
                )?,
            };
            rules::fluid_finish(v, escape, free)
        } else {
            let gravity = rules::gravity(0.08, resolved[1], self.slow_falling);
            let jump = self.jump_held();
            let climbing = if horizontal || jump {
                self.climb_contact(w, moved)?.0
            } else {
                false
            };
            let finished = rules::climb_finish(resolved, climbing, horizontal, jump)?;
            rules::air(
                finished,
                velocity[1],
                &Air {
                    on_ground: motion.physical_ground,
                    friction: after_friction(&before),
                    gravity,
                    levitation: self.levitation,
                    ..Air::default()
                },
                self.flying,
            )
        };
        if !rules::bounded(next, 64.0) {
            return Err(Fault::Limit("kinetic_velocity_limit"));
        }
        let recorded = self.record_path(position, actual, step.requested);
        let Slowing {
            multiplier, last, ..
        } = contacts::slowing(
            w.source,
            w.facts,
            catalog,
            &paths::collect(&recorded, position, moved),
            &self.context(fall, moved[1]),
            &Body {
                pose: pose_id,
                feet: moved,
                flying: self.flying,
                spectator,
                weaving: false,
            },
        )?;
        let grounded = actual[1] != step.requested[1] && step.requested[1] < 0.0;
        Ok(Kinetics {
            velocity: next,
            physical_ground: grounded,
            settled: !in_fluid
                && last.is_none()
                && next == motion.velocity
                && (grounded || self.flying),
            bounced,
            water: depths.water > 0.0,
            lava: depths.lava > 0.0,
            reset_fall: reset_fall || climb_reset || last.is_some(),
            stuck_multiplier: multiplier.unwrap_or(step.multiplier),
            paths: Vec::new(),
            touched,
        })
    }
}

/// Dry travel's floor friction: the block below the feet before the move.
fn after_friction(before: &Material) -> f64 {
    before.below.friction as f64
}
