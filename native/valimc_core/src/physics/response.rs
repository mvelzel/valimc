//! Velocity after a collision (vanilla's `Entity.move` restitution and
//! `Block.updateEntityMovementAfterFallOn` bounce).

#[inline]
fn f32r(v: f64) -> f64 {
    v as f32 as f64
}

/// What the collision was and how bouncy the entity and block are.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Response {
    pub x_collision: bool,
    pub z_collision: bool,
    pub vertical_collision: bool,
    pub below: bool,
    pub suppress_bounce: bool,
    pub block_suppresses_bounce: bool,
    pub entity_bounciness: f64,
    pub block_bounciness: f64,
    pub gravity: f64,
    pub air_drag: f64,
}

impl Default for Response {
    fn default() -> Response {
        Response {
            x_collision: false,
            z_collision: false,
            vertical_collision: false,
            below: false,
            suppress_bounce: false,
            block_suppresses_bounce: false,
            entity_bounciness: 0.0,
            block_bounciness: 0.0,
            gravity: 0.08,
            air_drag: 0.98,
        }
    }
}

pub struct Responded {
    pub velocity: [f64; 3],
    pub bounced: bool,
}

/// The velocity after a move that ended `moved_y` vertically.
pub fn respond(velocity: [f64; 3], moved_y: f64, f: &Response) -> Responded {
    let [x, y, z] = velocity;
    let entity = if f.suppress_bounce {
        0.0
    } else {
        f.entity_bounciness
    };
    let next_x = if f.x_collision { -x * entity } else { x };
    let next_z = if f.z_collision { -z * entity } else { z };
    let horizontal_bounce = entity > 0.0 && (f.x_collision || f.z_collision);
    let bounce = if !f.below {
        entity
    } else if -y <= f.gravity || f.suppress_bounce || f.block_suppresses_bounce {
        0.0
    } else {
        entity.max(f32r(f.block_bounciness))
    };
    let bounced = horizontal_bounce || (f.vertical_collision && bounce > 0.0);
    let next_y = if !f.vertical_collision {
        y
    } else if bounce > 0.0 {
        let fraction = moved_y / y;
        let gravity = fraction * f.gravity;
        let drag = 1.0 + fraction * (f32r(f.air_drag) - 1.0);
        (gravity - y) * drag * bounce
    } else {
        (0.0 - y) * 1.0 * bounce
    };
    let next = [next_x, next_y, next_z];
    // setDeltaMovement ignores a nonfinite candidate entirely.
    if next.iter().all(|v| v.is_finite()) {
        Responded {
            velocity: next,
            bounced,
        }
    } else {
        Responded { velocity, bounced }
    }
}
