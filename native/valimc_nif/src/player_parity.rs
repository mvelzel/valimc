//! The player's travel rules one by one for the oracle checks
//! (`scripts/check_*.exs`), built only with the `parity` feature: one NIF
//! that takes an operation and its arguments.

use crate::physics::{aabb, context, facts, t3, v3, view, BoxT, ContextT, Vec3};
use crate::player::{contact, fault, fires, path, path_t, player, source, PathT, PlayerT};
use rustler::{Atom, Encoder, Env, NifMap, NifResult, Term};
use valimc_core::physics::border::Border;
use valimc_core::physics::collide::{self, Extra};
use valimc_core::physics::player::contacts::{self, Body, Toucher};
use valimc_core::physics::player::paths;
use valimc_core::physics::player::pose::{self, Intent};
use valimc_core::physics::player::rules::{
    self, Air, FluidControls, FluidMotion, FoodContact, SneakEdges, Stuck,
};
use valimc_core::physics::player::World;
use valimc_core::physics::Aabb;

mod atoms {
    rustler::atoms! {
        jump, air_step, air, gravity, normalize, fluid_controls, fluid_motion, fluid_finish,
        climb_prepare, climb_finish, climb_contact, look_y, swim_steer, swimming_next,
        player_contact, stuck_prepare, slowing, paths, touched, hazard, pose_geometry,
        pose_select, pose_fit, food_travel, food_jump, kinetic_query, material, sneak_edges,
        moved_wrongly, rejected,
        lava, none, cobweb, berry_bush, powder_snow,
    }
}

#[derive(NifMap)]
struct AirT {
    on_ground: bool,
    friction: f64,
    friction_modifier: f64,
    air_drag_modifier: f64,
    gravity: f64,
    levitation: Option<i32>,
    discard_friction: bool,
    omnidirectional: bool,
}

fn air_facts(a: &AirT) -> Air {
    Air {
        on_ground: a.on_ground,
        friction: a.friction,
        friction_modifier: a.friction_modifier,
        air_drag_modifier: a.air_drag_modifier,
        gravity: a.gravity,
        levitation: a.levitation,
        discard_friction: a.discard_friction,
        omnidirectional: a.omnidirectional,
    }
}

#[derive(NifMap)]
struct ControlsT {
    water: f64,
    lava: f64,
    threshold: f64,
    on_ground: bool,
    jump: bool,
    shift: bool,
    flying: bool,
}

#[derive(NifMap)]
struct FluidMotionT {
    kind: Atom,
    falling: bool,
    on_ground: bool,
    sprint: bool,
    dolphins_grace: bool,
    water_efficiency: f64,
    gravity: f64,
    horizontal_collision: bool,
    climbable: bool,
    shallow: bool,
    old_y: f64,
    new_y: f64,
}

#[derive(NifMap)]
struct IntentT {
    sleeping: bool,
    swimming: bool,
    fall_flying: bool,
    spin_attack: bool,
    shift: bool,
    flying: bool,
    spectator: bool,
    passenger: bool,
}

fn intent(i: &IntentT) -> Intent {
    Intent {
        sleeping: i.sleeping,
        swimming: i.swimming,
        fall_flying: i.fall_flying,
        spin_attack: i.spin_attack,
        shift: i.shift,
        flying: i.flying,
        spectator: i.spectator,
        passenger: i.passenger,
    }
}

#[derive(NifMap)]
struct FoodT {
    passenger: bool,
    swimming: bool,
    underwater: bool,
    water: bool,
    climbing: bool,
    grounded: bool,
    sprinting: bool,
}

#[derive(NifMap)]
struct SneakT {
    flying: bool,
    shift: bool,
    on_ground: bool,
    fall_distance: f64,
    max_step: f64,
    player: bool,
}

/// `{pose, feet, flying, spectator, weaving}`.
type BodyT = (u8, Vec3, bool, bool, bool);

/// `{view, paths, context, body, {grounded, careful, known_movement, support}}`.
type TouchedArgs<'a> = (
    Term<'a>,
    Vec<PathT>,
    ContextT,
    BodyT,
    (bool, bool, Vec3, u16),
);

/// `{view, current, intent, position, context, {entities, border, subject}}`.
type PoseFitArgs<'a> = (
    Term<'a>,
    u8,
    IntentT,
    Vec3,
    ContextT,
    (Vec<BoxT>, Option<(f64, f64, f64, f64)>, (f64, f64)),
);

fn body(b: BodyT) -> Body {
    Body {
        pose: b.0,
        feet: v3(b.1),
        flying: b.2,
        spectator: b.3,
        weaving: b.4,
    }
}

fn stuck(kind: Atom) -> NifResult<Stuck> {
    Ok(if kind == atoms::none() {
        Stuck::None
    } else if kind == atoms::cobweb() {
        Stuck::Cobweb
    } else if kind == atoms::berry_bush() {
        Stuck::BerryBush
    } else if kind == atoms::powder_snow() {
        Stuck::PowderSnow
    } else {
        return Err(rustler::Error::BadArg);
    })
}

fn box_t(b: &Aabb) -> BoxT {
    (b.min[0], b.min[1], b.min[2], b.max[0], b.max[1], b.max[2])
}

/// Run one of the player's rules: `{:ok, result}` or `{:error, reason}`.
#[rustler::nif]
fn physics_player_parity<'a>(env: Env<'a>, op: Atom, args: Term<'a>) -> NifResult<Term<'a>> {
    // Pure rules run without the fact table; the others need it installed.
    let installed = facts().ok();
    let need = || installed.ok_or(rustler::Error::Atom("facts_missing"));
    let ok = |t: Term<'a>| Ok((rustler::types::atom::ok(), t).encode(env));
    macro_rules! reply {
        ($r:expr) => {
            match $r {
                Ok(v) => ok(v.encode(env)),
                Err(f) => Ok(fault(env, f)),
            }
        };
    }
    if op == atoms::jump() {
        let (v, factor, sprint, yaw, amplifier): (Vec3, f64, bool, f64, i32) = args.decode()?;
        reply!(rules::jump(v3(v), factor, sprint, yaw, amplifier).map(t3))
    } else if op == atoms::air_step() {
        let (v, a): (Vec3, AirT) = args.decode()?;
        ok(t3(rules::air_step(v3(v), &air_facts(&a))).encode(env))
    } else if op == atoms::air() {
        let (v, old_y, a, flying): (Vec3, f64, AirT, bool) = args.decode()?;
        ok(t3(rules::air(v3(v), old_y, &air_facts(&a), flying)).encode(env))
    } else if op == atoms::gravity() {
        let (base, vy, slow): (f64, f64, bool) = args.decode()?;
        ok(rules::gravity(base, vy, slow).encode(env))
    } else if op == atoms::normalize() {
        let v: Vec3 = args.decode()?;
        ok(t3(rules::normalize(v3(v))).encode(env))
    } else if op == atoms::fluid_controls() {
        let (v, c): (Vec3, ControlsT) = args.decode()?;
        let f = FluidControls {
            water: c.water,
            lava: c.lava,
            threshold: c.threshold,
            on_ground: c.on_ground,
            jump: c.jump,
            shift: c.shift,
            flying: c.flying,
        };
        reply!(rules::fluid_controls(v3(v), &f).map(|(v, g)| (t3(v), g)))
    } else if op == atoms::fluid_motion() {
        let (v, m): (Vec3, FluidMotionT) = args.decode()?;
        let f = FluidMotion {
            lava: m.kind == atoms::lava(),
            falling: m.falling,
            on_ground: m.on_ground,
            sprint: m.sprint,
            dolphins_grace: m.dolphins_grace,
            water_efficiency: m.water_efficiency,
            gravity: m.gravity,
            horizontal_collision: m.horizontal_collision,
            climbable: m.climbable,
            shallow: m.shallow,
            old_y: m.old_y,
            new_y: m.new_y,
        };
        reply!(rules::fluid_motion(v3(v), &f).map(|(v, e)| (t3(v), e.map(t3))))
    } else if op == atoms::fluid_finish() {
        let (v, escape, free): (Vec3, Option<Vec3>, bool) = args.decode()?;
        ok(t3(rules::fluid_finish(v3(v), escape.map(v3), free)).encode(env))
    } else if op == atoms::climb_prepare() {
        let (v, climbing, shift, scaffolding): (Vec3, bool, bool, bool) = args.decode()?;
        reply!(rules::climb_prepare(v3(v), climbing, shift, scaffolding).map(|(v, r)| (t3(v), r)))
    } else if op == atoms::climb_finish() {
        let (v, climbing, horizontal, jump): (Vec3, bool, bool, bool) = args.decode()?;
        reply!(rules::climb_finish(v3(v), climbing, horizontal, jump).map(t3))
    } else if op == atoms::climb_contact() {
        let facts = need()?;
        let (view_term, p, flying, spectator, gliding): (Term, (i32, i32, i32), bool, bool, bool) =
            args.decode()?;
        let region = Aabb::block(p.0, p.1, p.2);
        let source = view(view_term, facts, &region)?;
        reply!(contacts::climb(
            &source,
            facts,
            [p.0, p.1, p.2],
            flying,
            spectator,
            gliding
        ))
    } else if op == atoms::look_y() {
        let pitch: f64 = args.decode()?;
        reply!(rules::look_y(pitch))
    } else if op == atoms::swim_steer() {
        let (v, look, swimming, jump, above, passenger): (Vec3, f64, bool, bool, bool, bool) =
            args.decode()?;
        reply!(rules::swim_steer(v3(v), look, swimming, jump, above, passenger).map(t3))
    } else if op == atoms::swimming_next() {
        let (a, b, c, d, e, f): (bool, bool, bool, bool, bool, bool) = args.decode()?;
        ok(rules::swimming_next(a, b, c, d, e, f).encode(env))
    } else if op == atoms::player_contact() {
        let (kind, weaving, powder_feet, flying): (Atom, bool, bool, bool) = args.decode()?;
        ok(
            rules::player_contact(stuck(kind)?, weaving, powder_feet, flying)
                .map(t3)
                .encode(env),
        )
    } else if op == atoms::stuck_prepare() {
        let (r, v, m): (Vec3, Vec3, Vec3) = args.decode()?;
        reply!(rules::stuck_prepare(v3(r), v3(v), v3(m)).map(|s| (
            t3(s.requested),
            t3(s.velocity),
            t3(s.multiplier)
        )))
    } else if op == atoms::slowing() {
        let facts = need()?;
        let catalog = &facts.player.poses;
        let (view_term, ps, ctx, b): (Term, Vec<PathT>, ContextT, BodyT) = args.decode()?;
        let ps: Vec<_> = ps.iter().map(path).collect();
        let source = view(view_term, facts, &region_of(&ps))?;
        reply!(
            contacts::slowing(&source, facts, catalog, &ps, &context(ctx), &body(b)).map(|s| {
                (
                    s.multiplier.map(t3),
                    s.last
                        .map(|l| ((l.position[0], l.position[1], l.position[2]), l.state)),
                )
            })
        )
    } else if op == atoms::paths() {
        let (inputs, old, current): (Vec<(Vec3, Vec3, Vec3)>, Vec3, Vec3) = args.decode()?;
        let mut recorded = Vec::new();
        for (from, actual, axis) in inputs {
            paths::record(&mut recorded, v3(from), v3(actual), v3(axis));
        }
        let collected: Vec<PathT> = paths::collect(&recorded, v3(old), v3(current))
            .iter()
            .map(path_t)
            .collect();
        ok((collected, recorded.len()).encode(env))
    } else if op == atoms::touched() {
        let facts = need()?;
        let catalog = &facts.player.poses;
        let (view_term, ps, ctx, b, (grounded, careful, known, support)): TouchedArgs =
            args.decode()?;
        let ps: Vec<_> = ps.iter().map(path).collect();
        let source = view(view_term, facts, &region_of(&ps))?;
        let t = Toucher {
            body: body(b),
            grounded,
            careful,
            known_movement: v3(known),
            support_state: support,
        };
        reply!(
            contacts::touched(&source, facts, catalog, &ps, &context(ctx), &t).map(|t| fires(&t))
        )
    } else if op == atoms::hazard() {
        let facts = need()?;
        let (state, careful, client, known, previous): (u16, bool, bool, Vec3, Vec3) =
            args.decode()?;
        let movement = if client { v3(known) } else { v3(previous) };
        ok(contacts::hazard(facts, state, careful, movement)
            .map(|(s, a)| (source(s), a))
            .encode(env))
    } else if op == atoms::pose_geometry() {
        let facts = need()?;
        let catalog = &facts.player.poses;
        let (pose_id, p): (u8, Vec3) = args.decode()?;
        reply!(pose::geometry(catalog, pose_id, v3(p)).map(|g| (
            box_t(&g.body),
            box_t(&g.fit),
            t3(g.eye)
        )))
    } else if op == atoms::pose_select() {
        let (current, i, fits): (u8, IntentT, Vec<(u8, bool)>) = args.decode()?;
        let lookup = |p: u8| fits.iter().find(|(q, _)| *q == p).map(|(_, f)| *f);
        match pose::select(current, &intent(&i), &lookup) {
            pose::Choice::Selected(p, queries) => ok((p, queries).encode(env)),
            pose::Choice::Needs(p) => ok((rustler::types::atom::nil(), p).encode(env)),
        }
    } else if op == atoms::pose_fit() {
        let facts = need()?;
        let catalog = &facts.player.poses;
        let (view_term, current, i, p, ctx, (entities, border, subject)): PoseFitArgs =
            args.decode()?;
        let standing =
            pose::geometry(catalog, pose::STANDING, v3(p)).map_err(|_| rustler::Error::BadArg)?;
        let source = view(view_term, facts, &standing.body)?;
        let extra = Extra {
            entities: entities.into_iter().map(aabb).collect(),
            border: border.map(|(min_x, min_z, max_x, max_z)| Border {
                min_x,
                min_z,
                max_x,
                max_z,
            }),
            subject: [subject.0, subject.1],
        };
        let ctx = context(ctx);
        reply!(pose::fit(catalog, current, &intent(&i), v3(p), &mut |b| {
            Ok(collide::no_collision(
                &source,
                &facts.shapes,
                b,
                &ctx,
                &extra,
            )?)
        })
        .map(|f| (f.pose, f.fits, f.queries)))
    } else if op == atoms::food_travel() {
        let (m, c): (Vec3, FoodT) = args.decode()?;
        let c = FoodContact {
            passenger: c.passenger,
            swimming: c.swimming,
            underwater: c.underwater,
            water: c.water,
            climbing: c.climbing,
            grounded: c.grounded,
            sprinting: c.sprinting,
        };
        ok(rules::food_travel(v3(m), &c).encode(env))
    } else if op == atoms::food_jump() {
        let sprinting: bool = args.decode()?;
        ok(rules::food_jump(sprinting).encode(env))
    } else if op == atoms::kinetic_query() {
        let facts = need()?;
        let catalog = &facts.player.poses;
        let (p, b, jumping): (PlayerT, BoxT, bool) = args.decode()?;
        let p = player(&p)?;
        reply!(p.query_box(catalog, &aabb(b), jumping).map(|b| box_t(&b)))
    } else if op == atoms::material() {
        let facts = need()?;
        let (view_term, b, position, ctx): (Term, BoxT, Vec3, ContextT) = args.decode()?;
        let b = aabb(b);
        let source = view(view_term, facts, &b.inflate(1.0))?;
        let world = World {
            source: &source,
            facts,
            border: None,
        };
        let tuple = |p: [i32; 3]| (p[0], p[1], p[2]);
        reply!(world.material(&b, v3(position), &context(ctx)).map(|m| {
            (
                m.support.map(|(p, _)| tuple(p)),
                tuple(m.below_position),
                tuple(m.legacy.0),
            )
        }))
    } else if op == atoms::sneak_edges() {
        let (b, requested, s, supports): (BoxT, Vec3, SneakT, Vec<BoxT>) = args.decode()?;
        let supports: Vec<Aabb> = supports.into_iter().map(aabb).collect();
        let mut queries: Vec<BoxT> = Vec::new();
        let f = SneakEdges {
            flying: s.flying,
            shift: s.shift,
            on_ground: s.on_ground,
            fall_distance: s.fall_distance,
            max_step: s.max_step,
            player: s.player,
        };
        let result = rules::sneak_edges(&aabb(b), v3(requested), &f, &mut |q| {
            queries.push(box_t(q));
            Ok(!supports.iter().any(|s| q.intersects(s)))
        });
        reply!(result.map(|(r, _)| (t3(r), queries.clone())))
    } else if op == atoms::moved_wrongly() {
        let (requested, moved, exempt): (Vec3, Vec3, bool) = args.decode()?;
        ok(rules::moved_wrongly(v3(requested), v3(moved), exempt).encode(env))
    } else if op == atoms::rejected() {
        let (no_physics, wrongly, old_clear, new_collision): (bool, bool, bool, bool) =
            args.decode()?;
        ok(rules::rejected(no_physics, wrongly, old_clear, new_collision).encode(env))
    } else {
        let _ = contact;
        Err(rustler::Error::BadArg)
    }
}

/// The cells paths may visit, for decoding a supplied view (supplied views
/// ignore the region).
fn region_of(ps: &[paths::Path]) -> Aabb {
    ps.iter().fold(Aabb::block(0, 0, 0), |a, p| {
        let b = Aabb::new(p.from, p.to);
        Aabb::new(
            std::array::from_fn(|i| a.min[i].min(b.min[i])),
            std::array::from_fn(|i| a.max[i].max(b.max[i])),
        )
    })
}
