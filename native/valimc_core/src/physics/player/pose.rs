//! Player poses (vanilla `Player.updatePlayerPose`): default dimensions from
//! the pose catalog, each pose's box, fit box and eye, the ordered choice
//! between the desired pose, crouching and swimming, and the occupancy
//! queries that choice makes.

use super::Fault;
use crate::physics::aabb::Aabb;

pub const STANDING: u8 = 0;
pub const FALL_FLYING: u8 = 1;
pub const SLEEPING: u8 = 2;
pub const SWIMMING: u8 = 3;
pub const SPIN_ATTACK: u8 = 4;
pub const CROUCHING: u8 = 5;

/// A pose's default dimensions: width, height and eye height.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Dimensions {
    pub width: f64,
    pub height: f64,
    pub eye: f64,
}

/// A pose at a position.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Geometry {
    pub body: Aabb,
    /// The body shrunk by 1e-7 for occupancy (`canPlayerFitWithinBlocksAndEntitiesWhen`).
    pub fit: Aabb,
    pub eye: [f64; 3],
}

/// The box, fit box and eye of `pose` at `p` (`EntityDimensions.makeBoundingBox`).
pub fn geometry(catalog: &[Dimensions], pose: u8, p: [f64; 3]) -> Result<Geometry, Fault> {
    let d = catalog
        .get(pose as usize)
        .ok_or(Fault::Limit("unknown_pose"))?;
    if p[0].abs() > 29_999_984.0 || p[2].abs() > 29_999_984.0 || p[1].abs() > 1_000_000.0 {
        return Err(Fault::Limit("invalid_pose_position"));
    }
    let half = d.width / 2.0;
    let body = Aabb::new(
        [p[0] - half, p[1], p[2] - half],
        [p[0] + half, p[1] + d.height, p[2] + half],
    );
    let fit = Aabb::new(
        [
            body.min[0] + 1.0e-7,
            body.min[1] + 1.0e-7,
            body.min[2] + 1.0e-7,
        ],
        [
            body.max[0] - 1.0e-7,
            body.max[1] - 1.0e-7,
            body.max[2] - 1.0e-7,
        ],
    );
    Ok(Geometry {
        body,
        fit,
        eye: [p[0], p[1] + d.eye, p[2]],
    })
}

/// What the player wants its pose to be.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Intent {
    pub sleeping: bool,
    pub swimming: bool,
    pub fall_flying: bool,
    pub spin_attack: bool,
    pub shift: bool,
    pub flying: bool,
    pub spectator: bool,
    pub passenger: bool,
}

impl Intent {
    fn desired(&self) -> u8 {
        if self.sleeping {
            SLEEPING
        } else if self.swimming {
            SWIMMING
        } else if self.fall_flying {
            FALL_FLYING
        } else if self.spin_attack {
            SPIN_ATTACK
        } else if self.shift && !self.flying {
            CROUCHING
        } else {
            STANDING
        }
    }
}

/// The poses whose fit a choice has looked up, in order.
pub type Queries = Vec<u8>;

/// The pose chosen from the fits known so far, or the pose whose fit it
/// needs next.
pub enum Choice {
    Selected(u8, Queries),
    Needs(u8),
}

/// `updatePlayerPose`'s order: swimming must fit, then the desired pose,
/// else crouching, else swimming.
pub fn select(current: u8, intent: &Intent, fits: &dyn Fn(u8) -> Option<bool>) -> Choice {
    match fits(SWIMMING) {
        None => return Choice::Needs(SWIMMING),
        Some(false) => return Choice::Selected(current, vec![SWIMMING]),
        Some(true) => {}
    }
    let desired = intent.desired();
    if intent.spectator || intent.passenger {
        return Choice::Selected(desired, vec![SWIMMING]);
    }
    match fits(desired) {
        None => Choice::Needs(desired),
        Some(true) => Choice::Selected(desired, vec![SWIMMING, desired]),
        Some(false) => match fits(CROUCHING) {
            None => Choice::Needs(CROUCHING),
            Some(true) => Choice::Selected(CROUCHING, vec![SWIMMING, desired, CROUCHING]),
            Some(false) => Choice::Selected(SWIMMING, vec![SWIMMING, desired, CROUCHING]),
        },
    }
}

/// A chosen pose with what it took: the fits looked up in order.
#[derive(Clone, Debug, PartialEq)]
pub struct Fitted {
    pub pose: u8,
    pub geometry: Geometry,
    pub fits: Vec<(u8, bool)>,
    pub queries: Queries,
}

/// Choose the pose at `p`, answering each fit with `clear` (whether the
/// pose's fit box meets nothing).
pub fn fit(
    catalog: &[Dimensions],
    current: u8,
    intent: &Intent,
    p: [f64; 3],
    clear: &mut dyn FnMut(&Aabb) -> Result<bool, Fault>,
) -> Result<Fitted, Fault> {
    geometry(catalog, current, p)?;
    let mut fits: Vec<(u8, bool)> = Vec::with_capacity(3);
    loop {
        let known = fits.clone();
        let lookup = move |pose: u8| known.iter().find(|(p, _)| *p == pose).map(|(_, f)| *f);
        match select(current, intent, &lookup) {
            Choice::Selected(pose, queries) => {
                return Ok(Fitted {
                    pose,
                    geometry: geometry(catalog, pose, p)?,
                    fits,
                    queries,
                })
            }
            Choice::Needs(pose) if fits.len() < 3 => {
                let g = geometry(catalog, pose, p)?;
                fits.push((pose, clear(&g.fit)?));
            }
            Choice::Needs(_) => return Err(Fault::Limit("invalid_pose_observations")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_free_player_stands_and_a_roofed_one_crouches() {
        let catalog: Vec<Dimensions> = (0..6)
            .map(|i| Dimensions {
                width: 0.6,
                height: [1.8, 0.6, 0.2, 0.6, 0.6, 1.5][i],
                eye: 1.0,
            })
            .collect();
        let standing = fit(
            &catalog,
            STANDING,
            &Intent::default(),
            [0.5, 64.0, 0.5],
            &mut |_| Ok(true),
        )
        .unwrap();
        assert_eq!(standing.pose, STANDING);
        let roofed = fit(
            &catalog,
            STANDING,
            &Intent::default(),
            [0.5, 64.0, 0.5],
            &mut |b| Ok(b.max[1] < 65.6),
        )
        .unwrap();
        assert_eq!(roofed.pose, CROUCHING);
    }
}
