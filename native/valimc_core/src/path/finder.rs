//! `PathFinder.findPath` and its `BinaryHeap`, over a search's node arena.

use super::{
    distance, fly, manhattan, swim, walk, Evaluator, Found, Level, Path, PathFacts, PathNode,
    Request, Search,
};
use crate::physics::facts::Facts;
use crate::physics::source::BlockSource;

/// Vanilla's `BinaryHeap` of node indices, ordered by `f`.
struct Heap(Vec<usize>);

impl Heap {
    fn insert(&mut self, s: &mut Search, node: usize) {
        self.0.push(node);
        s.nodes[node].heap = (self.0.len() - 1) as i32;
        self.up(s, self.0.len() - 1);
    }

    fn pop(&mut self, s: &mut Search) -> usize {
        let popped = self.0[0];
        let last = self.0.pop().expect("a non-empty heap");
        if !self.0.is_empty() {
            self.0[0] = last;
            self.down(s, 0);
        }
        s.nodes[popped].heap = -1;
        popped
    }

    fn change_cost(&mut self, s: &mut Search, node: usize, cost: f32) {
        let old = s.nodes[node].f;
        s.nodes[node].f = cost;
        let at = s.nodes[node].heap as usize;
        if cost < old {
            self.up(s, at);
        } else {
            self.down(s, at);
        }
    }

    fn up(&mut self, s: &mut Search, mut idx: usize) {
        let node = self.0[idx];
        let cost = s.nodes[node].f;
        while idx > 0 {
            let parent_idx = (idx - 1) >> 1;
            let parent = self.0[parent_idx];
            // Costs are never NaN: `!(a < b)` is `a >= b`.
            if cost >= s.nodes[parent].f {
                break;
            }
            self.0[idx] = parent;
            s.nodes[parent].heap = idx as i32;
            idx = parent_idx;
        }
        self.0[idx] = node;
        s.nodes[node].heap = idx as i32;
    }

    fn down(&mut self, s: &mut Search, mut idx: usize) {
        let node = self.0[idx];
        let cost = s.nodes[node].f;
        let size = self.0.len();
        loop {
            let left_idx = 1 + (idx << 1);
            let right_idx = left_idx + 1;
            if left_idx >= size {
                break;
            }
            let left = self.0[left_idx];
            let left_cost = s.nodes[left].f;
            let (right, right_cost) = if right_idx >= size {
                (None, f32::INFINITY)
            } else {
                (Some(self.0[right_idx]), s.nodes[self.0[right_idx]].f)
            };
            if left_cost < right_cost {
                if left_cost >= cost {
                    break;
                }
                self.0[idx] = left;
                s.nodes[left].heap = idx as i32;
                idx = left_idx;
            } else {
                if right_cost >= cost {
                    break;
                }
                let right = right.expect("a right child");
                self.0[idx] = right;
                s.nodes[right].heap = idx as i32;
                idx = right_idx;
            }
        }
        self.0[idx] = node;
        s.nodes[node].heap = idx as i32;
    }
}

/// A `Target`: its block, the best node toward it so far.
struct Target {
    pos: [i32; 3],
    block: [i32; 3],
    best_h: f32,
    best: Option<usize>,
}

/// `Node.createHash`, the `Target`'s hash code.
fn node_hash([x, y, z]: [i32; 3]) -> i32 {
    (y & 0xFF)
        | (x & 32767) << 8
        | (z & 32767) << 24
        | if x < 0 { i32::MIN } else { 0 }
        | if z < 0 { 32768 } else { 0 }
}

/// The order a `java.util.HashMap` (or `HashSet`) of `table` buckets, grown
/// as it fills, iterates keys of `hashes` put in order: by bucket, then as
/// they were put.
fn hash_order(hashes: &[i32], mut table: usize) -> Vec<usize> {
    while hashes.len() as f32 > table as f32 * 0.75 {
        table *= 2;
    }
    let mut order: Vec<usize> = (0..hashes.len()).collect();
    let bucket = |h: i32| ((h ^ ((h as u32) >> 16) as i32) as u32 as usize) & (table - 1);
    order.sort_by_key(|&i| bucket(hashes[i]));
    order
}

/// `HashMap`'s table for an initial capacity (`tableSizeFor`).
fn table_for(capacity: usize) -> usize {
    capacity.max(1).next_power_of_two()
}

fn best_h(s: &Search, targets: &mut [Target], node: usize) -> f32 {
    let mut best = f32::MAX;
    let pos = s.nodes[node].pos;
    for t in targets.iter_mut() {
        let h = distance(pos, t.pos);
        if h < t.best_h {
            t.best_h = h;
            t.best = Some(node);
        }
        best = h.min(best);
    }
    best
}

fn reconstruct(s: &Search, closest: usize, target: [i32; 3], reached: bool) -> Path {
    let mut nodes = vec![];
    let mut node = Some(closest);
    while let Some(n) = node {
        let it = &s.nodes[n];
        nodes.push(PathNode {
            pos: it.pos,
            kind: it.kind,
        });
        node = it.came_from;
    }
    nodes.reverse();
    Path {
        nodes,
        target,
        reached,
    }
}

fn dist_to_target(path: &Path) -> f32 {
    path.nodes
        .last()
        .map_or(f32::MAX, |n| manhattan(n.pos, path.target))
}

fn start(s: &mut Search) -> Option<usize> {
    match s.request.evaluator {
        Evaluator::Walk => Some(walk::start(s)),
        Evaluator::Amphibious { .. } => Some(walk::amphibious_start(s)),
        Evaluator::Swim { .. } => Some(swim::start(s)),
        Evaluator::Fly => Some(fly::start(s)),
    }
}

fn neighbors(s: &mut Search, current: usize) -> Vec<usize> {
    match s.request.evaluator {
        Evaluator::Walk => walk::neighbors(s, current),
        Evaluator::Amphibious { shallow } => walk::amphibious_neighbors(s, current, shallow),
        Evaluator::Swim { breaching } => swim::neighbors(s, current, breaching),
        Evaluator::Fly => fly::neighbors(s, current),
    }
}

/// `PathFinder.findPath(region, mob, targets, maxPathLength, reachRange,
/// multiplier)` over `source`.
pub fn find(
    source: &dyn BlockSource,
    facts: &Facts,
    paths: &PathFacts,
    request: &Request,
) -> Found {
    let level = Level::new(source, facts, paths, request);
    let mut s = Search::new(level, request);
    let path = search(&mut s);
    let chunks = s.level.read.borrow().clone();
    Found {
        path,
        random: s.random.legacy_state().unwrap_or(request.mob.random),
        chunks,
    }
}

fn search(s: &mut Search) -> Option<Path> {
    let request = s.request;
    if request.targets.is_empty() {
        return None;
    }
    let from = start(s)?;
    // `Collectors.toMap`: a `HashMap` of targets (each made by `getTarget`).
    let made: Vec<Target> = request
        .targets
        .iter()
        .map(|&block| {
            // `getTargetNodeAt` (the amphibian's `y + 0.5` is the same block).
            let pos = block;
            s.node(pos);
            Target {
                pos,
                block,
                best_h: f32::MAX,
                best: None,
            }
        })
        .collect();
    let hashes: Vec<i32> = made.iter().map(|t| node_hash(t.pos)).collect();
    let mut slots: Vec<Option<Target>> = made.into_iter().map(Some).collect();
    let mut targets: Vec<Target> = hash_order(&hashes, 16)
        .into_iter()
        .filter_map(|i| slots[i].take())
        .collect();

    s.nodes[from].g = 0.0;
    let h = best_h(s, &mut targets, from);
    s.nodes[from].h = h;
    s.nodes[from].f = h;
    let mut open = Heap(Vec::with_capacity(128));
    open.insert(s, from);
    let mut count = 0;
    let mut reached: Vec<usize> = Vec::new();
    let max_visited = (request.max_visited as f32 * request.multiplier) as i32;
    let from_pos = s.nodes[from].pos;

    while !open.0.is_empty() {
        count += 1;
        if count >= max_visited {
            break;
        }
        let current = open.pop(s);
        s.nodes[current].closed = true;
        let pos = s.nodes[current].pos;
        for (i, t) in targets.iter().enumerate() {
            if manhattan(pos, t.pos) <= request.reach as f32 && !reached.contains(&i) {
                reached.push(i);
            }
        }
        if !reached.is_empty() {
            break;
        }
        if distance(pos, from_pos) >= request.max_path_length {
            continue;
        }
        for neighbor in neighbors(s, current) {
            let d = distance(pos, s.nodes[neighbor].pos);
            s.nodes[neighbor].walked = s.nodes[current].walked + d;
            let tentative = s.nodes[current].g + d + s.nodes[neighbor].malus;
            let n = &s.nodes[neighbor];
            if n.walked < request.max_path_length && (n.heap < 0 || tentative < n.g) {
                s.nodes[neighbor].came_from = Some(current);
                s.nodes[neighbor].g = tentative;
                let h = best_h(s, &mut targets, neighbor) * 1.5;
                s.nodes[neighbor].h = h;
                let cost = s.nodes[neighbor].g + h;
                if s.nodes[neighbor].heap >= 0 {
                    open.change_cost(s, neighbor, cost);
                } else {
                    s.nodes[neighbor].f = cost;
                    open.insert(s, neighbor);
                }
            }
        }
    }

    let candidates: Vec<Path> = if !reached.is_empty() {
        // `Sets.newHashSetWithExpectedSize(targets)`, in its own order.
        let n = targets.len();
        let capacity = if n < 3 {
            n + 1
        } else {
            (n as f32 / 0.75 + 1.0) as usize
        };
        let hashes: Vec<i32> = reached.iter().map(|&i| node_hash(targets[i].pos)).collect();
        hash_order(&hashes, table_for(capacity))
            .into_iter()
            .map(|k| {
                let t = &targets[reached[k]];
                reconstruct(s, t.best.expect("a target's best node"), t.block, true)
            })
            .collect()
    } else {
        targets
            .iter()
            .map(|t| reconstruct(s, t.best.expect("a target's best node"), t.block, false))
            .collect()
    };
    let reached_any = !reached.is_empty();
    // `Stream.min`: the first of the least.
    candidates.into_iter().reduce(|best, p| {
        let better = if reached_any {
            p.nodes.len() < best.nodes.len()
        } else {
            let (a, b) = (dist_to_target(&p), dist_to_target(&best));
            a < b || (a == b && p.nodes.len() < best.nodes.len())
        };
        if better {
            p
        } else {
            best
        }
    })
}
