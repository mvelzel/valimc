//! The dragon's 24-node arena graph (vanilla's
//! `EnderDragon.findPath`): heights sampled once when the arena starts,
//! closest-node selection and the A* search, its binary heap's tie order and
//! its closest reachable fallback kept. Without an outer ring (no fight, or
//! no crystals left) the search and the selection skip nodes 0 to 11.

use super::facts::DragonFacts;
use crate::mobs::ai::fmath::f;

/// The nodes: each block position and the mask of nodes it links to.
pub type Graph = Vec<([i64; 3], i64)>;

/// `graph/1`: each node at its column's `MOTION_BLOCKING_NO_LEAVES` height
/// plus its offset, at least 73.
pub fn graph(facts: &DragonFacts, height: &dyn Fn(i64, i64) -> i64) -> Graph {
    facts
        .graph
        .iter()
        .map(|n| ([n.x, (height(n.x, n.z) + n.offset).max(73), n.z], n.mask))
        .collect()
}

/// The first node a search may use (`first/1`).
fn first(crystals: Option<i64>) -> usize {
    match crystals {
        None | Some(0) => 12,
        Some(_) => 0,
    }
}

fn at(graph: &Graph, i: usize) -> [i64; 3] {
    graph[i].0
}

/// `squared/2` of block positions: each square rounded to a float, then
/// each sum.
fn squared(a: [i64; 3], b: [i64; 3]) -> f64 {
    let sq = |d: i64| f((d * d) as f64);
    f(f(sq(a[0] - b[0]) + sq(a[1] - b[1])) + sq(a[2] - b[2]))
}

fn distance(a: [i64; 3], b: [i64; 3]) -> f64 {
    f(squared(a, b).sqrt())
}

/// `closest/3`: the node nearest the block holding `p`.
pub fn closest(graph: &Graph, p: [f64; 3], crystals: Option<i64>) -> usize {
    let position = [
        p[0].floor() as i64,
        p[1].floor() as i64,
        p[2].floor() as i64,
    ];
    let mut best = (0, 10_000.0);
    for i in first(crystals)..24 {
        let next = squared(position, at(graph, i));
        if next < best.1 {
            best = (i, next);
        }
    }
    best.0
}

#[derive(Clone, Copy)]
struct Node {
    g: f64,
    f: f64,
    from: Option<usize>,
}

/// `find/5`: the path from `start` to `finish` with its start and `last`
/// after it, or None where it made no progress.
pub fn find(
    graph: &Graph,
    start: usize,
    finish: usize,
    crystals: Option<i64>,
    last: Option<[i64; 3]>,
) -> Option<Vec<[i64; 3]>> {
    let minimum = first(crystals);
    let mut nodes: [Option<Node>; 24] = [None; 24];
    nodes[start] = Some(Node {
        g: 0.0,
        f: distance(at(graph, start), at(graph, finish)),
        from: None,
    });
    let mut open = vec![start];
    let mut closed = [false; 24];
    let mut closest = start;
    let target = at(graph, finish);
    loop {
        if open.is_empty() {
            return (closest != start).then(|| path(graph, &nodes, closest, last));
        }
        let current = pop(&mut open, &nodes);
        if current == finish {
            return Some(path(graph, &nodes, current, last));
        }
        if distance(at(graph, current), target) < distance(at(graph, closest), target) {
            closest = current;
        }
        closed[current] = true;
        let mask = graph[current].1;
        for i in minimum..24 {
            let g = f(
                nodes[current].map_or(0.0, |n| n.g) + distance(at(graph, current), at(graph, i))
            );
            if mask & (1 << i) != 0 && !closed[i] && nodes[i].is_none_or(|n| g < n.g) {
                let cost = f(g + distance(at(graph, i), target));
                let previous = nodes[i];
                nodes[i] = Some(Node {
                    g,
                    f: cost,
                    from: Some(current),
                });
                match previous {
                    Some(p) => {
                        if let Some(index) = open.iter().position(|&o| o == i) {
                            if cost < p.f {
                                up(&mut open, index, &nodes);
                            } else {
                                down(&mut open, index, &nodes);
                            }
                        }
                    }
                    None => {
                        open.push(i);
                        let last = open.len() - 1;
                        up(&mut open, last, &nodes);
                    }
                }
            }
        }
    }
}

fn path(
    graph: &Graph,
    nodes: &[Option<Node>; 24],
    index: usize,
    last: Option<[i64; 3]>,
) -> Vec<[i64; 3]> {
    let mut result = vec![at(graph, index)];
    let mut i = index;
    while let Some(previous) = nodes[i].and_then(|n| n.from) {
        result.push(at(graph, previous));
        i = previous;
    }
    result.reverse();
    result.extend(last);
    result
}

fn cost(open: &[usize], index: usize, nodes: &[Option<Node>; 24]) -> f64 {
    nodes[open[index]].map_or(0.0, |n| n.f)
}

/// The first entry; the last takes its place and sinks.
fn pop(open: &mut Vec<usize>, nodes: &[Option<Node>; 24]) -> usize {
    let first = open[0];
    let last = open.pop().unwrap_or(first);
    if !open.is_empty() {
        open[0] = last;
        down(open, 0, nodes);
    }
    first
}

fn up(open: &mut [usize], mut index: usize, nodes: &[Option<Node>; 24]) {
    while index > 0 {
        let parent = (index - 1) / 2;
        if cost(open, index, nodes) < cost(open, parent, nodes) {
            open.swap(index, parent);
            index = parent;
        } else {
            break;
        }
    }
}

/// Strict comparisons keep insertion ties; the right child wins equal
/// costs, as the native path queue does.
fn down(open: &mut [usize], mut index: usize, nodes: &[Option<Node>; 24]) {
    loop {
        let left = index * 2 + 1;
        let right = left + 1;
        if left >= open.len() {
            return;
        }
        let child = if right < open.len() && cost(open, right, nodes) <= cost(open, left, nodes) {
            right
        } else {
            left
        };
        if cost(open, child, nodes) < cost(open, index, nodes) {
            open.swap(index, child);
            index = child;
        } else {
            return;
        }
    }
}
