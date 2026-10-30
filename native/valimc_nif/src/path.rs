//! The path search (VMC-041b, `valimc_core::path`) for Elixir: its facts,
//! installed once from `ai_facts.json` by `Valimc.AI.Facts.install!/0`, and
//! searches over a physics view (`{:rows, snapshots, outside}` or supplied
//! `{:states, packed}`, see `physics`).
//!
//! A request is a map (`Valimc.AI.Paths`); a result per request is
//! `{path | nil, random, chunks}`, a path `{nodes, target, reached}` with
//! `nodes` packed `<<x::32, y::32, z::32, type::8>>` and `chunks` the
//! `{cx, cz}` the search read.

use crate::physics::{facts, union, view, Vec3};
use rustler::{Atom, Binary, Encoder, Env, NifMap, NifResult, Term};
use std::sync::OnceLock;
use valimc_core::path::{self, Evaluator, Mob, PathFacts, Request};
use valimc_core::physics::border::Border;
use valimc_core::physics::Aabb;

static PATHS: OnceLock<PathFacts> = OnceLock::new();

/// The installed path facts (the native mob AI searches with them).
pub(crate) fn path_facts() -> Option<&'static PathFacts> {
    PATHS.get()
}

mod atoms {
    rustler::atoms! { ok, walk, amphibious, swim, fly, invalid_facts, path_facts_missing, invalid_request }
}

#[derive(NifMap)]
struct MobT<'a> {
    position: Vec3,
    width: f64,
    height: f64,
    on_ground: bool,
    in_water: bool,
    step: f64,
    max_fall: i32,
    fall_distance: f64,
    /// 27 big-endian f32s, by path type.
    malus: Binary<'a>,
    can_pass_doors: bool,
    can_open_doors: bool,
    can_float: bool,
    can_walk_over_fences: bool,
    random: u64,
}

#[derive(NifMap)]
struct RequestT<'a> {
    /// `:walk`, `:fly`, `{:amphibious, shallow}` or `{:swim, breaching}`.
    evaluator: Term<'a>,
    mob: MobT<'a>,
    targets: Vec<(i32, i32, i32)>,
    max_path_length: f64,
    reach: i32,
    max_visited: i32,
    multiplier: f64,
    region: ((i32, i32, i32), (i32, i32, i32)),
    min_y: i32,
    height: i32,
    sea_level: i32,
    /// The stationary border `{min_x, min_z, max_x, max_z}`, or nil.
    border: Option<(f64, f64, f64, f64)>,
}

fn invalid() -> rustler::Error {
    rustler::Error::Term(Box::new(atoms::invalid_request()))
}

fn evaluator(term: Term) -> NifResult<Evaluator> {
    if let Ok(atom) = term.decode::<Atom>() {
        return match atom {
            a if a == atoms::walk() => Ok(Evaluator::Walk),
            a if a == atoms::fly() => Ok(Evaluator::Fly),
            _ => Err(invalid()),
        };
    }
    let (kind, flag): (Atom, bool) = term.decode()?;
    match kind {
        k if k == atoms::amphibious() => Ok(Evaluator::Amphibious { shallow: flag }),
        k if k == atoms::swim() => Ok(Evaluator::Swim { breaching: flag }),
        _ => Err(invalid()),
    }
}

fn request(r: RequestT) -> NifResult<Request> {
    let m = r.mob;
    let bytes = m.malus.as_slice();
    if bytes.len() != 4 * path::types::COUNT || r.targets.len() > 64 {
        return Err(invalid());
    }
    let malus = std::array::from_fn(|i| {
        f32::from_be_bytes([
            bytes[4 * i],
            bytes[4 * i + 1],
            bytes[4 * i + 2],
            bytes[4 * i + 3],
        ])
    });
    let ((x0, y0, z0), (x1, y1, z1)) = r.region;
    // A region past vanilla's (follow ranges reach 128 blocks) is a caller's error.
    if x1 - x0 > 320 || z1 - z0 > 320 || r.max_visited > 4096 {
        return Err(invalid());
    }
    Ok(Request {
        evaluator: evaluator(r.evaluator)?,
        mob: Mob {
            position: [m.position.0, m.position.1, m.position.2],
            width: m.width as f32,
            height: m.height as f32,
            on_ground: m.on_ground,
            in_water: m.in_water,
            step: m.step as f32,
            max_fall: m.max_fall,
            fall_distance: m.fall_distance,
            malus,
            can_pass_doors: m.can_pass_doors,
            can_open_doors: m.can_open_doors,
            can_float: m.can_float,
            can_walk_over_fences: m.can_walk_over_fences,
            random: m.random,
        },
        targets: r.targets.into_iter().map(|(x, y, z)| [x, y, z]).collect(),
        max_path_length: r.max_path_length as f32,
        reach: r.reach,
        max_visited: r.max_visited,
        multiplier: r.multiplier as f32,
        region: ([x0, y0, z0], [x1, y1, z1]),
        min_y: r.min_y,
        height: r.height,
        sea_level: r.sea_level,
        border: r.border.map(|(min_x, min_z, max_x, max_z)| Border {
            min_x,
            min_z,
            max_x,
            max_z,
        }),
    })
}

/// Install the path facts: a path type and a flag byte per state.
#[rustler::nif]
fn path_facts_init(types: Binary, flags: Binary) -> NifResult<Atom> {
    let facts = PathFacts::new(types.as_slice().to_vec(), flags.as_slice().to_vec())
        .ok_or(rustler::Error::Term(Box::new(atoms::invalid_facts())))?;
    let _ = PATHS.set(facts);
    Ok(atoms::ok())
}

/// The searches of `requests` over `view`, in order (`{:ok, results}`).
#[rustler::nif]
fn path_find<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    requests: Vec<RequestT<'a>>,
) -> NifResult<Term<'a>> {
    find(env, view_term, requests)
}

/// `path_find` for batches past the normal scheduler's budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn path_find_dirty<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    requests: Vec<RequestT<'a>>,
) -> NifResult<Term<'a>> {
    find(env, view_term, requests)
}

fn find<'a>(env: Env<'a>, view_term: Term<'a>, requests: Vec<RequestT<'a>>) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let paths = PATHS
        .get()
        .ok_or(rustler::Error::Term(Box::new(atoms::path_facts_missing())))?;
    let requests = requests
        .into_iter()
        .map(request)
        .collect::<NifResult<Vec<_>>>()?;
    let boxes: Vec<Aabb> = requests
        .iter()
        .map(|r| {
            let (lo, hi) = r.region;
            Aabb::new(lo.map(|v| v as f64), hi.map(|v| v as f64 + 1.0))
        })
        .collect();
    let Some(region) = union(&boxes) else {
        return Ok((atoms::ok(), Vec::<Term>::new()).encode(env));
    };
    let view = view(view_term, facts, &region)?;
    let results: Vec<Term> = requests
        .iter()
        .map(|r| {
            let found = path::find(&view, facts, paths, r);
            let path = found.path.map(|p| {
                let mut nodes = Vec::with_capacity(13 * p.nodes.len());
                for n in &p.nodes {
                    for v in n.pos {
                        nodes.extend_from_slice(&v.to_be_bytes());
                    }
                    nodes.push(n.kind);
                }
                (
                    crate::binary(env, &nodes),
                    (p.target[0], p.target[1], p.target[2]),
                    p.reached,
                )
            });
            (path, found.random, found.chunks).encode(env)
        })
        .collect();
    Ok((atoms::ok(), results).encode(env))
}
