//! One tick of a projectile's flight (VMC-037o), as vanilla's projectiles
//! move: `AbstractArrow.tick` (arrows), `ThrowableProjectile.tick`
//! (snowballs, eggs, ender pearls, potions), `AbstractHurtingProjectile.tick`
//! (fireballs) and `EyeOfEnder.tick`, with the ray and entity hit tests
//! (`ProjectileUtil`) and `Projectile.checkLeftOwner`.
//!
//! The kernel moves the body and finds what it hits; the owner applies the
//! hit (damage, a stuck arrow's sound, an explosion, a teleport). An arrow's
//! block hit is applied here too (`AbstractArrow.onHitBlock`'s motion: it
//! backs off 0.05 and sticks), as the rest of its tick depends on it; an
//! arrow that hits entities stops at the first and returns them all, nearest
//! first, before its drag and gravity, which the owner applies once it knows
//! whether the hit took. Fluids push the body and set its water state for
//! the next tick (`Entity.baseTick`); block effects inside the path, bubble
//! columns and portals are not applied.

use super::aabb::Aabb;
use super::border::Border;
use super::collide::block_colliders;
use super::facts::Facts;
use super::fluid::{current, Depths, Pushed};
use super::item::{context, ItemFault};
use super::mob::atan2;
use super::ray::{clip_box, clip_including_border, BlockHit};
use super::source::BlockSource;

/// How a projectile flies.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    /// `AbstractArrow`: drag 0.99 (0.6 in water), then `gravity`.
    Arrow { gravity: f64 },
    /// `ThrowableProjectile`: `gravity`, then drag 0.99 (0.8 in water).
    Throwable { gravity: f64 },
    /// `AbstractHurtingProjectile`: accelerates by `acceleration` along its
    /// motion, then drag 0.95 (0.8 in water); no gravity.
    Hurting { acceleration: f64 },
    /// `EyeOfEnder`: drifts toward `target` (`signalTo`'s), if any.
    Eye { target: Option<[f64; 3]> },
    /// `ShulkerBullet`: steers toward `home` (its target deltas) or falls by
    /// `gravity`.
    Bullet {
        home: Option<[f64; 3]>,
        gravity: f64,
    },
}

/// A projectile's state between ticks.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Projectile {
    pub position: [f64; 3],
    pub velocity: [f64; 3],
    pub yaw: f32,
    pub pitch: f32,
    /// Ticks lived (`tickCount` before this tick).
    pub age: u32,
    /// `wasTouchingWater` from the last tick.
    pub in_water: bool,
    /// An arrow stuck in a block.
    pub in_ground: bool,
    pub left_owner: bool,
    /// The state an arrow last hit (`lastState`).
    pub last_state: Option<u16>,
}

/// An entity a projectile may hit: its network id, position and box. The
/// owner comes with its flag (it is not hit until the projectile left it).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Target {
    pub id: i32,
    pub position: [f64; 3],
    pub bbox: Aabb,
    pub owner: bool,
}

/// What a tick hit.
#[derive(Clone, Debug, PartialEq)]
pub enum Hit {
    None,
    Block(BlockHit),
    /// A throwable's or hurting projectile's nearest entity: id and point.
    Entity(i32, [f64; 3]),
    /// An arrow's entities along its path, nearest first.
    Entities(Vec<(i32, [f64; 3])>),
}

/// A tick's result: the projectile after it, its hit, the fluid depths of
/// its box (lava sets it on fire), and whether a stuck arrow came loose.
#[derive(Clone, Debug, PartialEq)]
pub struct Stepped {
    pub projectile: Projectile,
    pub hit: Hit,
    pub depths: Depths,
    pub loosened: bool,
}

/// One projectile's input.
#[derive(Clone, Copy, Debug)]
pub struct Input {
    pub projectile: Projectile,
    pub kind: Kind,
    /// `EntityDimensions`: width and height.
    pub size: [f32; 2],
    /// Floats from the projectile's random: a loosened arrow's speed
    /// factors, a border deflection's turn.
    pub random: [f32; 3],
}

const RADIANS_TO_DEGREES: f64 = 57.2957763671875;

fn bbox(p: [f64; 3], size: [f32; 2]) -> Aabb {
    let half = (size[0] / 2.0) as f64;
    Aabb {
        min: [p[0] - half, p[1], p[2] - half],
        max: [p[0] + half, p[1] + size[1] as f64, p[2] + half],
    }
}

fn add(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

fn scale(a: [f64; 3], s: f64) -> [f64; 3] {
    a.map(|v| v * s)
}

fn length_sqr(a: [f64; 3]) -> f64 {
    a[0] * a[0] + a[1] * a[1] + a[2] * a[2]
}

fn horizontal(a: [f64; 3]) -> f64 {
    (a[0] * a[0] + a[2] * a[2]).sqrt()
}

/// `Vec3.normalize`.
fn normalize(a: [f64; 3]) -> [f64; 3] {
    let d = length_sqr(a).sqrt();
    if d < 1.0e-5f32 as f64 {
        [0.0; 3]
    } else {
        a.map(|v| v / d)
    }
}

fn distance_sqr(a: [f64; 3], b: [f64; 3]) -> f64 {
    length_sqr([a[0] - b[0], a[1] - b[1], a[2] - b[2]])
}

/// `Math.signum`: zero keeps its sign.
fn signum(v: f64) -> f64 {
    if v == 0.0 || v.is_nan() {
        v
    } else {
        v.signum()
    }
}

/// `Projectile.lerpRotation`.
pub fn lerp_rotation(mut from: f32, to: f32) -> f32 {
    while to - from < -180.0 {
        from -= 360.0;
    }
    while to - from >= 180.0 {
        from += 360.0;
    }
    from + 0.2 * (to - from)
}

/// `Entity.setXRot`.
fn pitch(v: f32) -> f32 {
    (v % 360.0).clamp(-90.0, 90.0)
}

/// `ProjectileUtil.computeMargin` at tick `tick`.
fn margin(tick: u32) -> f64 {
    ((tick as f32 - 2.0) / 20.0).clamp(0.0, 0.3) as f64
}

fn hittable(t: &Target, p: &Projectile) -> bool {
    !t.owner || p.left_owner
}

/// `isOutsideOwnerCollisionRange`: no owner box meets the body swept by its
/// motion and inflated by 1.
fn outside_owner(targets: &[Target], body: &Aabb, velocity: [f64; 3]) -> bool {
    let area = body.expand_towards(velocity).inflate(1.0);
    !targets.iter().any(|t| t.owner && area.intersects(&t.bbox))
}

/// `ProjectileUtil.getEntityHitResult`: the nearest entity in `area` whose
/// box inflated by `margin` the segment enters.
fn nearest_entity(
    targets: &[Target],
    p: &Projectile,
    area: &Aabb,
    from: [f64; 3],
    to: [f64; 3],
    margin: f64,
) -> Option<(i32, [f64; 3])> {
    let mut best = f64::MAX;
    let mut found = None;
    for t in targets {
        if !hittable(t, p) || !t.bbox.intersects(area) {
            continue;
        }
        if let Some((at, _)) = clip_box(&t.bbox.inflate(margin), from, to) {
            let d = distance_sqr(from, at);
            if d < best {
                best = d;
                found = Some((t.id, at));
            }
        }
    }
    found
}

/// `ProjectileUtil.getHitResultOnMoveVector`: the collider ray along the
/// motion, then the nearest entity before where it stops.
#[allow(clippy::too_many_arguments)]
fn move_hit(
    source: &dyn BlockSource,
    facts: &Facts,
    p: &Projectile,
    body: &Aabb,
    targets: &[Target],
    tick: u32,
    border: Option<&Border>,
) -> Result<Hit, ItemFault> {
    let from = p.position;
    let to = add(from, p.velocity);
    let block = clip_including_border(source, facts, from, to, &context(from[1]), border)?;
    let end = if block.miss { to } else { block.location };
    let area = body.expand_towards(p.velocity).inflate(1.0);
    Ok(
        match nearest_entity(targets, p, &area, from, end, margin(tick)) {
            Some((id, at)) => Hit::Entity(id, at),
            None if block.miss => Hit::None,
            None => Hit::Block(block),
        },
    )
}

fn location(hit: &Hit, otherwise: [f64; 3]) -> [f64; 3] {
    match hit {
        Hit::Block(b) => b.location,
        Hit::Entity(_, at) => *at,
        _ => otherwise,
    }
}

/// `Entity.baseTick`'s fluid update: water and lava push the body, and its
/// water state is what the next tick reads.
fn fluids(
    source: &dyn BlockSource,
    facts: &Facts,
    p: &mut Projectile,
    size: [f32; 2],
    pushed: bool,
    fast_lava: bool,
) -> Result<Depths, ItemFault> {
    let body = bbox(p.position, size);
    let (depths, velocity) = current(
        source,
        facts,
        &body,
        p.velocity,
        pushed,
        fast_lava,
        Pushed::Item,
    )?
    .unwrap_or((Depths::default(), p.velocity));
    p.velocity = velocity;
    p.in_water = depths.water > 0.0;
    Ok(depths)
}

fn throwable(
    source: &dyn BlockSource,
    facts: &Facts,
    input: &Input,
    gravity: f64,
    targets: &[Target],
    border: Option<&Border>,
    fast_lava: bool,
) -> Result<Stepped, ItemFault> {
    let mut p = input.projectile;
    let tick = p.age + 1;
    let (yaw0, pitch0) = (p.yaw, p.pitch);
    if gravity != 0.0 {
        p.velocity[1] -= gravity;
    }
    let inertia = if p.in_water { 0.8f32 } else { 0.99f32 } as f64;
    p.velocity = scale(p.velocity, inertia);
    let body = bbox(p.position, input.size);
    let hit = move_hit(source, facts, &p, &body, targets, tick, border)?;
    p.position = location(&hit, add(p.position, p.velocity));
    // `updateRotation`, from the rotation the tick started with.
    let v = p.velocity;
    p.pitch = pitch(lerp_rotation(
        pitch0,
        (atan2(v[1], horizontal(v)) * RADIANS_TO_DEGREES) as f32,
    ));
    p.yaw = lerp_rotation(yaw0, (atan2(v[0], v[2]) * RADIANS_TO_DEGREES) as f32);
    finish(source, facts, p, input, hit, targets, true, fast_lava)
}

fn hurting(
    source: &dyn BlockSource,
    facts: &Facts,
    input: &Input,
    acceleration: f64,
    targets: &[Target],
    border: Option<&Border>,
    fast_lava: bool,
) -> Result<Stepped, ItemFault> {
    let mut p = input.projectile;
    let tick = p.age + 1;
    let inertia = if p.in_water { 0.8f32 } else { 0.95f32 } as f64;
    p.velocity = scale(
        add(p.velocity, scale(normalize(p.velocity), acceleration)),
        inertia,
    );
    let body = bbox(p.position, input.size);
    let hit = move_hit(source, facts, &p, &body, targets, tick, border)?;
    rotate_towards_movement(&mut p, 0.2);
    p.position = location(&hit, add(p.position, p.velocity));
    finish(source, facts, p, input, hit, targets, true, fast_lava)
}

// `Projectile.tick` after the move: the owner check on the new box, then the
// base tick's fluids.
#[allow(clippy::too_many_arguments)]
fn finish(
    source: &dyn BlockSource,
    facts: &Facts,
    mut p: Projectile,
    input: &Input,
    hit: Hit,
    targets: &[Target],
    pushed: bool,
    fast_lava: bool,
) -> Result<Stepped, ItemFault> {
    if !p.left_owner {
        p.left_owner = outside_owner(targets, &bbox(p.position, input.size), p.velocity);
    }
    let depths = fluids(source, facts, &mut p, input.size, pushed, fast_lava)?;
    p.age += 1;
    Ok(Stepped {
        projectile: p,
        hit,
        depths,
        loosened: false,
    })
}

fn arrow(
    source: &dyn BlockSource,
    facts: &Facts,
    input: &Input,
    gravity: f64,
    targets: &[Target],
    border: Option<&Border>,
    fast_lava: bool,
) -> Result<Stepped, ItemFault> {
    let mut p = input.projectile;
    let tick = p.age + 1;
    let cell = p.position.map(|v| v.floor() as i32);
    let state = source
        .state(cell[0], cell[1], cell[2])
        .ok_or(ItemFault::Unreadable(cell))?;
    let air = facts.flags.get(state as usize).is_some_and(|f| f & 1 != 0);
    if !air {
        let picked = facts
            .shapes
            .shape(state, cell, &super::table::Context::default());
        let inside = picked.shape.cells().iter().any(|b| {
            (0..3).all(|a| {
                let lo = b.min[a] + picked.offset[a] + cell[a] as f64;
                let hi = b.max[a] + picked.offset[a] + cell[a] as f64;
                p.position[a] >= lo && p.position[a] < hi
            })
        });
        if inside {
            p.velocity = [0.0; 3];
            p.in_ground = true;
        }
    }
    if p.in_ground {
        // `shouldFall`: nothing within 0.06 of the point (blocks only).
        let mut loosened = false;
        if p.last_state != Some(state) {
            let probe = Aabb::new(p.position, p.position).inflate(0.06);
            let empty = super::table::Context::default();
            if block_colliders(source, &facts.shapes, &probe, &empty)?.is_empty() {
                p.in_ground = false;
                let r = input.random;
                p.velocity = [
                    p.velocity[0] * (r[0] * 0.2) as f64,
                    p.velocity[1] * (r[1] * 0.2) as f64,
                    p.velocity[2] * (r[2] * 0.2) as f64,
                ];
                loosened = true;
            }
        }
        p.age += 1;
        return Ok(Stepped {
            projectile: p,
            hit: Hit::None,
            depths: Depths::default(),
            loosened,
        });
    }
    // The tick moves by the motion it started with; water's drag applies to
    // what follows (the owner check, the entity search, the next tick).
    let v = p.velocity;
    if p.in_water {
        p.velocity = scale(p.velocity, 0.6f32 as f64);
    }
    let yaw = (atan2(v[0], v[2]) * RADIANS_TO_DEGREES) as f32;
    let pitch_to = (atan2(v[1], horizontal(v)) * RADIANS_TO_DEGREES) as f32;
    p.pitch = pitch(lerp_rotation(p.pitch, pitch_to));
    p.yaw = lerp_rotation(p.yaw, yaw);
    if !p.left_owner {
        p.left_owner = outside_owner(targets, &bbox(p.position, input.size), p.velocity);
    }
    let from = p.position;
    let block =
        clip_including_border(source, facts, from, add(from, v), &context(from[1]), border)?;
    // `findHitEntities` up to where the ray stops, nearest (by position) first.
    let to = block.location;
    let body = bbox(p.position, input.size);
    let area = body.expand_towards(p.velocity).inflate(1.0);
    let m = margin(tick);
    let mut hits: Vec<(f64, i32, [f64; 3])> = Vec::new();
    for t in targets {
        if !hittable(t, &p) || !t.bbox.intersects(&area) {
            continue;
        }
        if let Some((at, _)) = clip_box(&t.bbox, from, to) {
            hits.push((distance_sqr(from, t.position), t.id, at));
        } else if m > 0.0 {
            if let Some((outside, _)) = clip_box(&t.bbox.inflate(m), from, to) {
                let center = std::array::from_fn(|a| (t.bbox.min[a] + t.bbox.max[a]) / 2.0);
                let back = clip_including_border(
                    source,
                    facts,
                    outside,
                    center,
                    &context(from[1]),
                    border,
                )?;
                let toward = if back.miss { center } else { back.location };
                if clip_box(&t.bbox, outside, toward).is_some() {
                    hits.push((distance_sqr(from, t.position), t.id, outside));
                }
            }
        }
    }
    hits.sort_by(|a, b| a.0.total_cmp(&b.0));
    if let Some(&(_, _, at)) = hits.first() {
        p.position = at;
        p.age += 1;
        let entities = hits.into_iter().map(|(_, id, at)| (id, at)).collect();
        return Ok(Stepped {
            projectile: p,
            hit: Hit::Entities(entities),
            depths: Depths::default(),
            loosened: false,
        });
    }
    p.position = block.location;
    let mut hit = Hit::None;
    if !block.miss {
        if block.border {
            // `ProjectileDeflection.REVERSE` at a fifth of the power.
            p.velocity = scale(p.velocity, -0.2 * 0.5);
            p.yaw += 170.0 + input.random[0] * 20.0;
        } else {
            // `onHitBlock`: back off along the motion's signs and stick.
            let back = 0.05f32 as f64;
            p.position = std::array::from_fn(|a| p.position[a] - signum(p.velocity[a]) * back);
            p.velocity = [0.0; 3];
            p.in_ground = true;
            p.last_state = source.state(block.cell[0], block.cell[1], block.cell[2]);
        }
        hit = Hit::Block(block);
    }
    if !p.in_water {
        p.velocity = scale(p.velocity, 0.99f32 as f64);
    }
    if !p.in_ground && gravity != 0.0 {
        p.velocity[1] -= gravity;
    }
    let pushed = !p.in_ground;
    let mut stepped = finish(source, facts, p, input, hit, targets, pushed, fast_lava)?;
    // The check ran before the ray (`checkLeftOwner` once per tick).
    stepped.projectile.left_owner = p.left_owner;
    Ok(stepped)
}

/// `ProjectileUtil.rotateTowardsMovement(speed)`: from the rotation the tick
/// started with toward the motion, by `speed`.
fn rotate_towards_movement(p: &mut Projectile, speed: f32) {
    let v = p.velocity;
    if length_sqr(v) != 0.0 {
        let yaw = (atan2(v[2], v[0]) * RADIANS_TO_DEGREES) as f32 + 90.0;
        let pitch_to = pitch((atan2(horizontal(v), v[1]) * RADIANS_TO_DEGREES) as f32 - 90.0);
        let (mut pitch0, mut yaw0) = (p.pitch, p.yaw);
        while pitch_to - pitch0 < -180.0 {
            pitch0 -= 360.0;
        }
        while pitch_to - pitch0 >= 180.0 {
            pitch0 += 360.0;
        }
        while yaw - yaw0 < -180.0 {
            yaw0 -= 360.0;
        }
        while yaw - yaw0 >= 180.0 {
            yaw0 += 360.0;
        }
        p.pitch = pitch(pitch0 + speed * (pitch_to - pitch0));
        p.yaw = yaw0 + speed * (yaw - yaw0);
    }
}

/// `ShulkerBullet.tick`: toward `home` (the deltas its owner scaled this
/// tick), else falling by `gravity`; it passes through blocks
/// (`noPhysics`), stops at what its motion meets first, and turns half way
/// to its motion.
#[allow(clippy::too_many_arguments)]
fn bullet(
    source: &dyn BlockSource,
    facts: &Facts,
    input: &Input,
    home: Option<[f64; 3]>,
    gravity: f64,
    targets: &[Target],
    border: Option<&Border>,
    fast_lava: bool,
) -> Result<Stepped, ItemFault> {
    let mut p = input.projectile;
    let tick = p.age + 1;
    match home {
        Some(d) => {
            let v = p.velocity;
            p.velocity = [
                v[0] + (d[0] - v[0]) * 0.2,
                v[1] + (d[1] - v[1]) * 0.2,
                v[2] + (d[2] - v[2]) * 0.2,
            ];
        }
        None => p.velocity[1] -= gravity,
    }
    let body = bbox(p.position, input.size);
    let hit = move_hit(source, facts, &p, &body, targets, tick, border)?;
    p.position = add(p.position, p.velocity);
    rotate_towards_movement(&mut p, 0.5);
    finish(source, facts, p, input, hit, targets, true, fast_lava)
}

fn eye(
    source: &dyn BlockSource,
    facts: &Facts,
    input: &Input,
    target: Option<[f64; 3]>,
    fast_lava: bool,
) -> Result<Stepped, ItemFault> {
    let mut p = input.projectile;
    let depths = fluids(source, facts, &mut p, input.size, true, fast_lava)?;
    let next = add(p.position, p.velocity);
    if let Some(t) = target {
        // `updateDeltaMovement`.
        let old = p.velocity;
        let h = [t[0] - next[0], 0.0, t[2] - next[2]];
        let length = length_sqr(h).sqrt();
        let mut wanted = horizontal(old) + 0.0025 * (length - horizontal(old));
        let mut y = old[1];
        if length < 1.0 {
            wanted *= 0.8;
            y *= 0.8;
        }
        let rise = if next[1] - old[1] < t[1] { 1.0 } else { -1.0 };
        p.velocity = add(
            scale(h, wanted / length),
            [0.0, y + (rise - y) * 0.015, 0.0],
        );
    }
    p.position = next;
    p.age += 1;
    Ok(Stepped {
        projectile: p,
        hit: Hit::None,
        depths,
        loosened: false,
    })
}

/// The bound on a projectile's speed per axis (blocks per tick).
const MAX_SPEED: f64 = 16.0;

/// One tick of a projectile.
pub fn step(
    source: &dyn BlockSource,
    facts: &Facts,
    input: &Input,
    targets: &[Target],
    border: Option<&Border>,
    fast_lava: bool,
) -> Result<Stepped, ItemFault> {
    let p = &input.projectile;
    if !p
        .velocity
        .iter()
        .all(|v| v.is_finite() && v.abs() <= MAX_SPEED)
        || !super::item::position_ok(p.position)
    {
        return Err(ItemFault::Limit);
    }
    let stepped = match input.kind {
        Kind::Arrow { gravity } => arrow(source, facts, input, gravity, targets, border, fast_lava),
        Kind::Throwable { gravity } => {
            throwable(source, facts, input, gravity, targets, border, fast_lava)
        }
        Kind::Hurting { acceleration } => hurting(
            source,
            facts,
            input,
            acceleration,
            targets,
            border,
            fast_lava,
        ),
        Kind::Eye { target } => eye(source, facts, input, target, fast_lava),
        Kind::Bullet { home, gravity } => bullet(
            source, facts, input, home, gravity, targets, border, fast_lava,
        ),
    }?;
    if !super::item::position_ok(stepped.projectile.position) {
        return Err(ItemFault::Limit);
    }
    Ok(stepped)
}

/// `Projectile.shoot`'s motion and rotation: `direction` normalized, plus
/// `triangle` noise (three `random.triangle(0, 0.0172275 * uncertainty)`
/// draws, given), times `power`.
pub fn shoot(direction: [f64; 3], power: f32, noise: [f64; 3]) -> ([f64; 3], f32, f32) {
    let v = scale(add(normalize(direction), noise), power as f64);
    let yaw = (atan2(v[0], v[2]) * RADIANS_TO_DEGREES) as f32;
    let pitch = (atan2(v[1], horizontal(v)) * RADIANS_TO_DEGREES) as f32;
    (v, yaw, pitch)
}
