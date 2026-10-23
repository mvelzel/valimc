//! Projectile ticks for region owners (VMC-037o, `valimc_core::physics::projectile`).
//!
//! A projectile is `{state, kind, size, random, owner}`:
//!
//! - `state` `{position, velocity, {yaw, pitch}, age, {in_water, in_ground,
//!   left_owner}, last_state}` (`last_state` -1 for none);
//! - `kind` `{:arrow, gravity}`, `{:throwable, gravity}`, `{:hurting,
//!   acceleration}` or `{:eye, target}` (`target` nil or a point);
//! - `size` `{width, height}`, `random` three floats in [0, 1), `owner` the
//!   owner's network id or nil.
//!
//! Targets are `{id, position, box}`. Each result is `{:ok, state, hit,
//! {water, lava}, loosened}`, `{:unreadable, position}` or `:limit`, with
//! `hit` nil, `{:block, location, face, cell, inside, border}`, `{:entity,
//! id, location}` or `{:entities, [{id, location}]}`.

use crate::physics::{aabb, atoms, facts, ok, t3, union, v3, view, BoxT, Vec3};
use rustler::{Atom, Encoder, Env, NifResult, Term};
use valimc_core::physics::border::Border;
use valimc_core::physics::item::ItemFault;
use valimc_core::physics::projectile::{self, Hit, Input, Kind, Projectile, Target};
use valimc_core::physics::Aabb;

mod kinds {
    rustler::atoms! { arrow, throwable, hurting, eye, bullet, block, entity, entities, nil }
}

type StateT = (Vec3, Vec3, (f32, f32), u32, (bool, bool, bool), i32);
type ProjectileT<'a> = (
    StateT,
    (Atom, Term<'a>),
    (f32, f32),
    (f32, f32, f32),
    Option<i32>,
);
type TargetT = (i32, Vec3, BoxT);

fn kind(tag: Atom, arg: Term) -> NifResult<Kind> {
    Ok(if tag == kinds::arrow() {
        Kind::Arrow {
            gravity: arg.decode()?,
        }
    } else if tag == kinds::throwable() {
        Kind::Throwable {
            gravity: arg.decode()?,
        }
    } else if tag == kinds::hurting() {
        Kind::Hurting {
            acceleration: arg.decode()?,
        }
    } else if tag == kinds::eye() {
        let target: Option<Vec3> = arg.decode()?;
        Kind::Eye {
            target: target.map(v3),
        }
    } else if tag == kinds::bullet() {
        let (home, gravity): (Option<Vec3>, f64) = arg.decode()?;
        Kind::Bullet {
            home: home.map(v3),
            gravity,
        }
    } else {
        return Err(rustler::Error::BadArg);
    })
}

fn encode_state<'a>(env: Env<'a>, p: &Projectile) -> Term<'a> {
    (
        t3(p.position),
        t3(p.velocity),
        (p.yaw, p.pitch),
        p.age,
        (p.in_water, p.in_ground, p.left_owner),
        p.last_state.map_or(-1, |s| s as i32),
    )
        .encode(env)
}

fn encode_hit<'a>(env: Env<'a>, hit: &Hit) -> Term<'a> {
    match hit {
        Hit::None => kinds::nil().encode(env),
        Hit::Block(b) => (
            kinds::block(),
            t3(b.location),
            b.face,
            (b.cell[0], b.cell[1], b.cell[2]),
            b.inside,
            b.border,
        )
            .encode(env),
        Hit::Entity(id, at) => (kinds::entity(), *id, t3(*at)).encode(env),
        Hit::Entities(list) => (
            kinds::entities(),
            list.iter()
                .map(|(id, at)| (*id, t3(*at)))
                .collect::<Vec<_>>(),
        )
            .encode(env),
    }
}

/// One tick of each projectile, in order: `{:ok, results}`.
#[rustler::nif]
fn physics_projectiles<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    projectiles: Vec<ProjectileT<'a>>,
    targets: Vec<TargetT>,
    border: Option<(f64, f64, f64, f64)>,
    fast_lava: bool,
) -> NifResult<Term<'a>> {
    run(env, view_term, projectiles, targets, border, fast_lava)
}

/// `physics_projectiles` for batches past the normal scheduler's budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn physics_projectiles_dirty<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    projectiles: Vec<ProjectileT<'a>>,
    targets: Vec<TargetT>,
    border: Option<(f64, f64, f64, f64)>,
    fast_lava: bool,
) -> NifResult<Term<'a>> {
    run(env, view_term, projectiles, targets, border, fast_lava)
}

fn run<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    projectiles: Vec<ProjectileT<'a>>,
    targets: Vec<TargetT>,
    border: Option<(f64, f64, f64, f64)>,
    fast_lava: bool,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let mut inputs = Vec::with_capacity(projectiles.len());
    for (
        (p, v, (yaw, pitch), age, (in_water, in_ground, left_owner), last),
        (tag, arg),
        (w, h),
        r,
        owner,
    ) in projectiles
    {
        let projectile = Projectile {
            position: v3(p),
            velocity: v3(v),
            yaw,
            pitch,
            age,
            in_water,
            in_ground,
            left_owner,
            last_state: u16::try_from(last).ok(),
        };
        let input = Input {
            projectile,
            kind: kind(tag, arg)?,
            size: [w, h],
            random: [r.0, r.1, r.2],
        };
        inputs.push((input, owner));
    }
    let Some(region) = union(
        &inputs
            .iter()
            .map(|(i, _)| {
                let p = i.projectile.position;
                let reach = i.size[0].max(i.size[1]) as f64 + 3.0;
                Aabb::new(
                    [p[0] - reach, p[1] - reach, p[2] - reach],
                    [p[0] + reach, p[1] + reach, p[2] + reach],
                )
                .expand_towards(i.projectile.velocity)
            })
            .collect::<Vec<_>>(),
    ) else {
        return Ok(ok(env, Vec::<Term>::new()));
    };
    let view = view(view_term, facts, &region)?;
    let border = border.map(|(min_x, min_z, max_x, max_z)| Border {
        min_x,
        min_z,
        max_x,
        max_z,
    });
    let all: Vec<(i32, [f64; 3], Aabb)> = targets
        .into_iter()
        .map(|(id, p, b)| (id, v3(p), aabb(b)))
        .collect();
    let results: Vec<Term> = inputs
        .iter()
        .map(|(input, owner)| {
            let mine: Vec<Target> = all
                .iter()
                .map(|&(id, position, bbox)| Target {
                    id,
                    position,
                    bbox,
                    owner: Some(id) == *owner,
                })
                .collect();
            match projectile::step(&view, facts, input, &mine, border.as_ref(), fast_lava) {
                Ok(s) => (
                    atoms::ok(),
                    encode_state(env, &s.projectile),
                    encode_hit(env, &s.hit),
                    (s.depths.water, s.depths.lava),
                    s.loosened,
                )
                    .encode(env),
                Err(ItemFault::Unreadable(p)) => {
                    (atoms::unreadable(), (p[0], p[1], p[2])).encode(env)
                }
                Err(_) => atoms::limit().encode(env),
            }
        })
        .collect();
    Ok(ok(env, results))
}
