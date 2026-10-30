//! The dragon's pure parts; its ticks are checked against the Elixir's in
//! `test/native_mob_dragon_test.exs`.

use super::codec;
use super::facts::DragonFacts;
use super::flight::Flight;
use super::paths;
use super::phases::{PhaseEffect, Phases};
use super::Actor;
use crate::worldgen::json::Json;

const GRAPH: [[i64; 4]; 24] = [
    [60, 5, 0, 6146],
    [51, 5, 30, 8197],
    [29, 5, 51, 8202],
    [0, 5, 60, 16404],
    [-31, 5, 51, 32808],
    [-52, 5, 29, 32848],
    [-60, 5, 0, 65696],
    [-52, 5, -31, 131392],
    [-30, 5, -52, 131712],
    [0, 5, -60, 263424],
    [29, 5, -52, 526848],
    [51, 5, -30, 525313],
    [40, 15, 0, 1581057],
    [28, 15, 28, 3166214],
    [0, 15, 40, 2138120],
    [-29, 15, 28, 6373424],
    [-40, 15, 0, 4358208],
    [-29, 15, -29, 12910976],
    [0, 15, -40, 9044480],
    [28, 15, -29, 9706496],
    [20, 5, 0, 15216640],
    [0, 5, 20, 13688832],
    [-20, 5, 0, 11763712],
    [0, 5, -20, 8257536],
];

fn facts() -> DragonFacts {
    let n = |v: f64| Json::Number(v);
    let object = |pairs: Vec<(&str, Json)>| {
        Json::Object(pairs.into_iter().map(|(k, v)| (k.to_owned(), v)).collect())
    };
    let graph = GRAPH
        .iter()
        .map(|r| Json::Array(r.iter().map(|&v| n(v as f64)).collect()))
        .collect();
    let parts = [
        (1.0, 1.0),
        (3.0, 3.0),
        (5.0, 3.0),
        (2.0, 2.0),
        (2.0, 2.0),
        (2.0, 2.0),
        (4.0, 2.0),
        (4.0, 2.0),
    ]
    .iter()
    .map(|&(w, h)| object(vec![("width", n(w)), ("height", n(h))]))
    .collect();
    let phases = (0..11)
        .map(|id| {
            object(vec![
                ("id", n(id as f64)),
                (
                    "name",
                    Json::String(if id == 3 { "Landing" } else { "Other" }.into()),
                ),
                ("speed", n(0.6000000238418579)),
                ("sitting", Json::Bool(matches!(id, 5 | 6 | 7 | 10))),
            ])
        })
        .collect();
    DragonFacts::parse(&object(vec![
        ("ambient_interval", n(80.0)),
        ("max_head_y_rot", n(75.0)),
        ("graph", Json::Array(graph)),
        ("parts", Json::Array(parts)),
        ("phases", Json::Array(phases)),
    ]))
    .unwrap()
}

#[test]
fn nodes_rise_at_least_to_73() {
    let graph = paths::graph(&facts(), &|x, _| if x > 0 { 80 } else { 50 });
    assert_eq!(graph[0].0, [60, 85, 0]);
    assert_eq!(graph[6].0, [-60, 73, 0]);
    assert_eq!(graph[12].1, 1581057);
}

#[test]
fn paths_follow_links_and_skip_the_outer_ring_without_crystals() {
    let graph = paths::graph(&facts(), &|_, _| 60);
    let path = paths::find(&graph, 0, 6, Some(10), Some([0, 64, 0])).unwrap();
    assert_eq!(path.first(), Some(&graph[0].0));
    assert_eq!(path.last(), Some(&[0, 64, 0]));
    let index = |p: &[i64; 3]| graph.iter().position(|(at, _)| at == p).unwrap();
    for w in path[..path.len() - 1].windows(2) {
        assert_ne!(graph[index(&w[0])].1 & (1 << index(&w[1])), 0);
    }
    assert_eq!(path[path.len() - 2], graph[6].0);
    // Without crystals no outer node is a start or goal candidate.
    assert!(paths::closest(&graph, [60.0, 65.0, 0.0], None) >= 12);
    assert_eq!(paths::closest(&graph, [60.0, 65.0, 0.0], Some(3)), 0);
}

#[test]
fn the_brain_term_round_trips() {
    let mut flight = Flight {
        position: [1.5, 80.0, -2.25],
        yaw: 33.0,
        ..Flight::default()
    };
    flight.begin_tick(false);
    flight.advance(&facts(), Some([20.0, 90.0, 5.0]), 0, false);
    let actor = Actor {
        phases: Phases {
            phase: 1,
            flight,
            target: Some([1.0, 2.0, 3.0]),
            leaving: Some((0, None)),
            path: Some(vec![[1, 2, 3]]),
            effects: vec![
                PhaseEffect::ScanCrystals,
                PhaseEffect::Flame([1.0, 64.0, 2.0]),
                PhaseEffect::EndFlame,
            ],
            ..Phases::default()
        },
        tick: 7,
        ambient: -80,
        body_yaw: 1.0,
        stable_head: 2.0,
        stable_time: 3,
        wall: true,
        crystal: Some(vec![1; 16]),
        flame: None,
        graph: Some(paths::graph(&facts(), &|_, _| 60)),
        world_tick: Some(40),
    };
    let value = codec::actor_value(&actor);
    assert_eq!(codec::actor(&value), Some(actor));
}
