//! One move packet's validation and one resting tick, each a single pass
//! over the player's chunks (vanilla `ServerGamePacketListenerImpl.
//! handleMovePlayer` and the server half of `Player.tick`).

use super::contacts;
use super::kinetics::{self, Kinetics};
use super::pose::{self, Dimensions, Fitted, Intent};
use super::rules::{self, FoodContact};
use super::{Fault, Mode, Motion, Player, World};
use crate::physics::aabb::Aabb;
use crate::physics::facts::WATER;
use crate::physics::source::AirWhereUnreadable;

fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

/// The most cells a player's query box may scan. The speed check runs first
/// and bounds a vanilla client's move to about ten blocks a packet plus its
/// velocity (a few thousand cells with the halo); this only bounds a forged
/// packet's cost and is never a gameplay rule.
pub const QUERY_CELLS: i64 = 65_536;

/// Whether `b` lies inside the world and its scan (one block of halo) reads
/// at most `QUERY_CELLS` cells.
pub fn bounded(b: &Aabb) -> bool {
    let inside = b.min[0].abs() < 30_000_000.0
        && b.max[0].abs() < 30_000_000.0
        && b.min[2].abs() < 30_000_000.0
        && b.max[2].abs() < 30_000_000.0
        && b.min[1].abs() <= 1_000_000.0
        && b.max[1].abs() <= 1_000_000.0;
    if !inside {
        return false;
    }
    let span = |a: f64, z: f64| (z + 1.0e-7).floor() as i64 - (a - 1.0e-7).floor() as i64 + 3;
    span(b.min[0], b.max[0]) * span(b.min[1], b.max[1]) * span(b.min[2], b.max[2]) <= QUERY_CELLS
}

impl Player {
    fn intent(&self, swimming: bool) -> Intent {
        Intent {
            shift: self.shift,
            flying: self.flying,
            spectator: self.spectator(),
            swimming,
            ..Intent::default()
        }
    }

    /// `Player.updateSwimming` at `position` in `pose`.
    fn swimming(
        &self,
        w: &World,
        catalog: &[Dimensions],
        pose_id: u8,
        position: [f64; 3],
    ) -> Result<bool, Fault> {
        if !self.sprint || self.flying || self.spectator() {
            return Ok(false);
        }
        if self.motion.swimming {
            let g = pose::geometry(catalog, pose_id, position)?;
            let depths = w.depths(&g.body)?;
            return Ok(rules::swimming_next(
                true,
                self.sprint,
                depths.water > 0.0,
                false,
                false,
                false,
            ));
        }
        let feet = position.map(|v| v.floor() as i32);
        if w.facts.fluid(w.state(feet)?).kind != WATER {
            return Ok(false);
        }
        let g = pose::geometry(catalog, pose_id, position)?;
        let (water, _) = w.eyes(&g.body, g.eye)?;
        Ok(rules::swimming_next(
            false,
            self.sprint,
            true,
            water,
            true,
            false,
        ))
    }

    /// The pose at `position`: the fits answered by blocks and the border.
    fn fit(
        &self,
        w: &World,
        catalog: &[Dimensions],
        current: u8,
        swimming: bool,
        position: [f64; 3],
        fall: f64,
    ) -> Result<Fitted, Fault> {
        let ctx = self.context(fall, position[1]);
        let subject = [position[0], position[2]];
        pose::fit(
            catalog,
            current,
            &self.intent(swimming),
            position,
            &mut |b| Ok(!w.colliding(b, &ctx, subject)?),
        )
    }

    /// Eye contact: whether the eye is under water, and the state there (the
    /// owner tells bubble columns apart).
    fn eye(&self, w: &World, g: &pose::Geometry) -> Result<(bool, u16), Fault> {
        let (water, _) = w.eyes(&g.body, g.eye)?;
        let state = w.state(g.eye.map(|v| v.floor() as i32))?;
        Ok((water, state))
    }
}

/// A move packet's outcome.
#[derive(Clone, Debug)]
pub struct Moved {
    pub accepted: bool,
    pub pose: u8,
    pub swimming: bool,
    pub moved: [f64; 3],
    pub powder_snow: bool,
    pub eye_water: bool,
    pub eye_state: u16,
    /// The top of the pose's body (the rain check reads the head there).
    pub top: f64,
    pub exhaustion: (f64, f64),
    pub packet: Kinetics,
    pub tick: Kinetics,
    /// The legacy landing block and the distance landed on it, when the move
    /// lands outside water.
    pub landing: Option<(u16, f64)>,
    /// The landing block's cell (farmland's trampling, VMC-039a).
    pub landing_pos: Option<[i32; 3]>,
    /// The motion after the packet, and after the tick as well.
    pub motion: Motion,
    pub ticked: Motion,
}

/// Validate `player`'s move to `target` with the packet's `flags`.
pub fn validate(
    w: &World,
    catalog: &[Dimensions],
    p: &Player,
    target: [f64; 3],
    flags: u8,
) -> Result<Moved, Fault> {
    let position = p.position;
    let requested = sub(target, position);
    if !rules::bounded(requested, 64.0) {
        return Err(Fault::Limit("movement_query_limit"));
    }
    let fall = p.motion.fall_distance;
    query(catalog, p, Some(target), flags)?;
    let ctx = p.context(fall, position[1]);
    let spectator = p.spectator();
    let air = AirWhereUnreadable(w.source);
    let w = &w.read_by(spectator, &air);
    let swimming_before = p.swimming(w, catalog, p.pose, position)?;
    let before = p.fit(w, catalog, p.pose, swimming_before, position, fall)?;
    let body = before.geometry.body;
    let step = p.prepare_collision(
        w,
        requested,
        p.motion.velocity,
        &body,
        p.motion.on_ground,
        fall,
    )?;
    let actual = w.displacement(&body, step.requested, &ctx, spectator)?;
    let moved = p.physical_position(actual, step.requested);
    let moved_body = body.moved(sub(moved, position));
    // The native translation order, including cancellation at remote coordinates.
    let target_body = moved_body.moved(sub(target, moved));
    let wrongly = rules::moved_wrongly(
        target,
        moved,
        matches!(p.mode, Mode::Creative | Mode::Spectator),
    );
    let old_colliding = w.colliding(&body, &p.context(fall, moved[1]), [moved[0], moved[2]])?;
    let new_collision = w.new_collision(&body, &target_body, &ctx)?;
    let rejected = rules::rejected(spectator, wrongly, !old_colliding, new_collision);
    let mut swimmer = p.clone();
    swimmer.motion.swimming = swimming_before;
    let swimming = swimmer.swimming(w, catalog, before.pose, target)?;
    let after = p.fit(w, catalog, before.pose, swimming, target, fall)?;
    let powder_snow = contacts::powder_snow(w.source, w.facts, &after.geometry.body)?;
    let (eye_water, eye_state) = p.eye(w, &after.geometry)?;
    let packet = p.packet(w, target, actual, flags, &body)?;
    let landed = landing(w, p, target, flags, &body)?;
    let landing = landed.map(|(_, state, distance)| (state, distance));
    let landing_pos = landed.map(|(pos, _, _)| pos);
    let accepted = p.motion.accept(requested, flags, p.flying);
    let motion = kinetics::apply(
        &Motion {
            swimming,
            ..accepted
        },
        &packet,
    );
    let candidate = Player {
        position: target,
        motion: motion.clone(),
        ..p.clone()
    };
    let tick = candidate.tick(w, catalog, after.pose)?;
    let ticked = kinetics::apply(&motion, &tick);
    let exhaustion = food(w, p, &candidate, requested, flags, eye_water, tick.water)?;
    Ok(Moved {
        accepted: !rejected,
        pose: after.pose,
        swimming,
        moved,
        powder_snow,
        eye_water,
        eye_state,
        top: after.geometry.body.max[1],
        exhaustion,
        packet,
        tick,
        landing,
        landing_pos,
        motion,
        ticked,
    })
}

/// `PlayerLanding.sample`: a grounded move that ends a fall outside water
/// lands on the legacy support.
fn landing(
    w: &World,
    p: &Player,
    target: [f64; 3],
    flags: u8,
    body: &Aabb,
) -> Result<Option<([i32; 3], u16, f64)>, Fault> {
    let fall = p.motion.fall_distance;
    if flags & 1 == 0 || p.flying || !(fall > 0.0 || target[1] < p.position[1]) {
        return Ok(None);
    }
    let dy = target[1] - p.position[1];
    let moved = body.moved([target[0] - p.position[0], dy, target[2] - p.position[2]]);
    let depths = w.depths(&moved)?;
    let (_, landed) = rules::fall_step(fall, dy, true, depths.water > 0.0);
    if depths.water != 0.0 {
        return Ok(None);
    }
    let m = w.material(&moved, target, &p.context(fall, target[1]))?;
    Ok(landed.map(|distance| (m.legacy.0, m.legacy.1, distance)))
}

/// Travel and jump exhaustion for a move.
fn food(
    w: &World,
    p: &Player,
    candidate: &Player,
    movement: [f64; 3],
    flags: u8,
    eye_water: bool,
    tick_water: bool,
) -> Result<(f64, f64), Fault> {
    if p.invulnerable {
        return Ok((0.0, 0.0));
    }
    let grounded = flags & 1 != 0;
    let in_fluid = candidate.motion.swimming || eye_water || tick_water;
    let climbing = if p.sprint && grounded && !in_fluid {
        contacts::climb(
            w.source,
            w.facts,
            candidate.position.map(|v| v.floor() as i32),
            candidate.flying,
            candidate.spectator(),
            false,
        )?
        .0
    } else {
        false
    };
    let travel = rules::food_travel(
        movement,
        &FoodContact {
            passenger: false,
            swimming: candidate.motion.swimming,
            underwater: eye_water,
            water: tick_water,
            climbing,
            grounded,
            sprinting: p.sprint,
        },
    );
    let jump = if p.jumping(movement[1], flags) {
        rules::food_jump(p.sprint)
    } else {
        0.0
    };
    Ok((jump, travel))
}

/// A resting player's tick.
#[derive(Clone, Debug)]
pub struct Rested {
    pub pose: u8,
    pub swimming: bool,
    pub powder_snow: bool,
    pub eye_water: bool,
    pub eye_state: u16,
    pub top: f64,
    pub tick: Kinetics,
    /// The motion after the tick (with the sampled swimming flag).
    pub ticked: Motion,
}

/// Sample a resting player where it stands.
pub fn rest(w: &World, catalog: &[Dimensions], p: &Player) -> Result<Rested, Fault> {
    let position = p.position;
    let fall = p.motion.fall_distance;
    let standing = pose::geometry(catalog, pose::STANDING, position)?;
    let query = p.query_box(catalog, &standing.body, false)?;
    if !bounded(&query) {
        return Err(Fault::Limit("pose_query_limit"));
    }
    let air = AirWhereUnreadable(w.source);
    let w = &w.read_by(p.spectator(), &air);
    let swimming = p.swimming(w, catalog, p.pose, position)?;
    let fitted = p.fit(w, catalog, p.pose, swimming, position, fall)?;
    let powder_snow = contacts::powder_snow(w.source, w.facts, &fitted.geometry.body)?;
    let (eye_water, eye_state) = p.eye(w, &fitted.geometry)?;
    let mut candidate = p.clone();
    candidate.motion.swimming = swimming;
    let tick = candidate.tick(w, catalog, fitted.pose)?;
    let ticked = kinetics::apply(&candidate.motion, &tick);
    Ok(Rested {
        pose: fitted.pose,
        swimming,
        powder_snow,
        eye_water,
        eye_state,
        top: fitted.geometry.body.max[1],
        tick,
        ticked,
    })
}

/// The query box a move or rest reads, for the caller to pick the chunk
/// rows: the move's own when given a target, refused past `QUERY_CELLS`.
pub fn query(
    catalog: &[Dimensions],
    p: &Player,
    target: Option<[f64; 3]>,
    flags: u8,
) -> Result<Aabb, Fault> {
    let position = p.position;
    match target {
        None => {
            let standing = pose::geometry(catalog, pose::STANDING, position)?;
            p.query_box(catalog, &standing.body, false)
        }
        Some(target) => {
            let requested = sub(target, position);
            if !rules::bounded(requested, 64.0) {
                return Err(Fault::Limit("movement_query_limit"));
            }
            let step0 = p.prepare_move(requested, p.motion.velocity)?;
            let standing = pose::geometry(catalog, pose::STANDING, position)?;
            let destination = pose::geometry(catalog, pose::STANDING, target)?;
            let kinetic =
                p.query_box(catalog, &destination.body, p.jumping(requested[1], flags))?;
            let b = standing.body.expand_towards(requested);
            let s = standing.body.expand_towards(step0.requested);
            let u = Aabb::new(
                std::array::from_fn(|i| b.min[i].min(s.min[i])),
                std::array::from_fn(|i| b.max[i].max(s.max[i])),
            )
            .expand_towards([0.0, 0.6, 0.0])
            .expand_towards([0.0, -0.001, 0.0]);
            let b = Aabb::new(
                std::array::from_fn(|i| u.min[i].min(kinetic.min[i])),
                std::array::from_fn(|i| u.max[i].max(kinetic.max[i])),
            );
            if bounded(&b) {
                Ok(b)
            } else {
                Err(Fault::Limit("movement_query_limit"))
            }
        }
    }
}
