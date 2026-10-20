//! Climate parameters and multi-noise biome lookup (VMC-023d), vanilla's
//! `Climate`: climate values quantised to longs, parameter points with seven
//! dimensions (six climate parameters and an offset), and the R-tree vanilla
//! searches for the closest point.
//!
//! The tree is built exactly as vanilla builds it, because ties between
//! equally close points resolve by search order: a search starts from the
//! previous search's result and keeps it while nothing is strictly closer.
//! Vanilla keeps that previous result per thread, so where several biomes tie,
//! its answer depends on lookup history; callers pass the history explicitly.

use super::json::Json;

pub const DIMENSIONS: usize = 7;

/// `Climate.quantizeCoord`.
pub fn quantize(value: f32) -> i64 {
    (value * 10000.0) as i64
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Parameter {
    pub min: i64,
    pub max: i64,
}

impl Parameter {
    fn distance(&self, target: i64) -> i64 {
        let above = target.wrapping_sub(self.max);
        let below = self.min.wrapping_sub(target);
        if above > 0 {
            above
        } else {
            below.max(0)
        }
    }

    fn span(&self, other: Option<Parameter>) -> Parameter {
        match other {
            None => *self,
            Some(o) => Parameter {
                min: self.min.min(o.min),
                max: self.max.max(o.max),
            },
        }
    }

    fn center(&self) -> i64 {
        self.min.wrapping_add(self.max) / 2
    }
}

type Space = [Parameter; DIMENSIONS];

#[derive(Clone, Debug)]
enum Node {
    Leaf { space: Space, value: u16 },
    SubTree { space: Space, children: Vec<usize> },
}

impl Node {
    fn space(&self) -> &Space {
        match self {
            Node::Leaf { space, .. } | Node::SubTree { space, .. } => space,
        }
    }
}

fn distance(space: &Space, target: &[i64; DIMENSIONS]) -> i64 {
    let mut total = 0i64;
    for (p, &t) in space.iter().zip(target) {
        let d = p.distance(t);
        total = total.wrapping_add(d.wrapping_mul(d));
    }
    total
}

/// A biome source's parameter list with its search tree.
#[derive(Clone, Debug)]
pub struct ParameterList {
    /// Biome names, in order of first appearance.
    pub biomes: Vec<String>,
    nodes: Vec<Node>,
    root: usize,
    leaves: Vec<usize>,
}

const CHILDREN_PER_NODE: usize = 19;

impl ParameterList {
    /// Parses a preset's rows: biome, six (min, max) pairs, offset.
    pub fn parse(rows: &Json) -> Result<ParameterList, String> {
        let mut biomes: Vec<String> = Vec::new();
        let mut points = Vec::new();
        for row in rows.as_array()? {
            let row = row.as_array()?;
            if row.len() != 14 {
                return Err("biome parameter rows have 14 fields".into());
            }
            let name = row[0].as_str()?;
            let index = match biomes.iter().position(|b| b == name) {
                Some(i) => i,
                None => {
                    biomes.push(name.to_string());
                    biomes.len() - 1
                }
            };
            let number = |i: usize| row[i].as_f64().map(|n| n as i64);
            let mut space = [Parameter { min: 0, max: 0 }; DIMENSIONS];
            for (d, p) in space.iter_mut().take(6).enumerate() {
                *p = Parameter {
                    min: number(1 + 2 * d)?,
                    max: number(2 + 2 * d)?,
                };
            }
            let offset = number(13)?;
            space[6] = Parameter {
                min: offset,
                max: offset,
            };
            points.push((space, index as u16));
        }
        ParameterList::new(biomes, points)
    }

    pub fn new(biomes: Vec<String>, points: Vec<(Space, u16)>) -> Result<ParameterList, String> {
        if points.is_empty() {
            return Err("a parameter list needs at least one point".into());
        }
        let mut nodes: Vec<Node> = points
            .into_iter()
            .map(|(space, value)| Node::Leaf { space, value })
            .collect();
        let leaves: Vec<usize> = (0..nodes.len()).collect();
        let root = build(&mut nodes, leaves.clone(), CHILDREN_PER_NODE);
        Ok(ParameterList {
            biomes,
            nodes,
            root,
            leaves,
        })
    }

    /// The biome closest to `target` (vanilla's `findValue`), starting from
    /// the previous result in `last`, which it updates.
    pub fn find(&self, target: &[i64; 6], last: &mut Option<usize>) -> u16 {
        let full = [
            target[0], target[1], target[2], target[3], target[4], target[5], 0,
        ];
        let leaf = self.search(self.root, &full, *last);
        *last = Some(leaf);
        match &self.nodes[leaf] {
            Node::Leaf { value, .. } => *value,
            Node::SubTree { .. } => unreachable!("searches end at leaves"),
        }
    }

    fn search(&self, node: usize, target: &[i64; DIMENSIONS], candidate: Option<usize>) -> usize {
        let children = match &self.nodes[node] {
            Node::Leaf { .. } => return node,
            Node::SubTree { children, .. } => children,
        };
        let mut min = candidate.map_or(i64::MAX, |c| distance(self.nodes[c].space(), target));
        let mut closest = candidate;
        for &child in children {
            let child_distance = distance(self.nodes[child].space(), target);
            if min > child_distance {
                let leaf = self.search(child, target, closest);
                let leaf_distance = if child == leaf {
                    child_distance
                } else {
                    distance(self.nodes[leaf].space(), target)
                };
                if min > leaf_distance {
                    min = leaf_distance;
                    closest = Some(leaf);
                }
            }
        }
        closest.expect("a subtree has children")
    }

    /// Every biome at the minimal distance from `target`: the biomes a lookup
    /// can return, depending on lookup history.
    pub fn closest_biomes(&self, target: &[i64; 6]) -> Vec<u16> {
        let full = [
            target[0], target[1], target[2], target[3], target[4], target[5], 0,
        ];
        let distances: Vec<(i64, u16)> = self
            .leaves
            .iter()
            .map(|&l| match &self.nodes[l] {
                Node::Leaf { space, value } => (distance(space, &full), *value),
                Node::SubTree { .. } => unreachable!(),
            })
            .collect();
        let min = distances.iter().map(|d| d.0).min().unwrap_or(0);
        let mut biomes: Vec<u16> = distances
            .into_iter()
            .filter(|d| d.0 == min)
            .map(|d| d.1)
            .collect();
        biomes.sort_unstable();
        biomes.dedup();
        biomes
    }
}

fn space_of(nodes: &[Node], children: &[usize]) -> Space {
    let mut bounds: [Option<Parameter>; DIMENSIONS] = [None; DIMENSIONS];
    for &c in children {
        let space = nodes[c].space();
        for d in 0..DIMENSIONS {
            bounds[d] = Some(space[d].span(bounds[d]));
        }
    }
    bounds.map(|b| b.expect("subtrees have children"))
}

fn sort_by_dimension(nodes: &[Node], children: &mut [usize], dimension: usize, absolute: bool) {
    let key = |i: usize| -> [i64; DIMENSIONS] {
        let space = nodes[i].space();
        std::array::from_fn(|k| {
            let center = space[(dimension + k) % DIMENSIONS].center();
            if absolute {
                center.wrapping_abs()
            } else {
                center
            }
        })
    };
    children.sort_by_cached_key(|&i| key(i));
}

fn bucketize(children: &[usize], per_node: usize) -> Vec<Vec<usize>> {
    let n = children.len() as f64;
    let expected =
        (per_node as f64).powf(((n - 0.01).ln() / (per_node as f64).ln()).floor()) as usize;
    let mut buckets = Vec::new();
    let mut current = Vec::new();
    for &child in children {
        current.push(child);
        if current.len() >= expected {
            buckets.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        buckets.push(current);
    }
    buckets
}

fn cost(space: &Space) -> i64 {
    space.iter().fold(0i64, |sum, p| {
        sum.wrapping_add(p.max.wrapping_sub(p.min).wrapping_abs())
    })
}

/// `Climate.RTree.build`.
fn build(nodes: &mut Vec<Node>, mut children: Vec<usize>, per_node: usize) -> usize {
    if children.len() == 1 {
        return children[0];
    }
    if children.len() <= per_node {
        children.sort_by_cached_key(|&i| {
            nodes[i]
                .space()
                .iter()
                .fold(0i64, |sum, p| sum.wrapping_add(p.center().wrapping_abs()))
        });
        let space = space_of(nodes, &children);
        nodes.push(Node::SubTree { space, children });
        return nodes.len() - 1;
    }
    let mut min_cost = i64::MAX;
    let mut min_dimension = 0;
    let mut min_buckets = Vec::new();
    for d in 0..DIMENSIONS {
        sort_by_dimension(nodes, &mut children, d, false);
        let buckets = bucketize(&children, per_node);
        let total = buckets
            .iter()
            .fold(0i64, |sum, b| sum.wrapping_add(cost(&space_of(nodes, b))));
        if min_cost > total {
            min_cost = total;
            min_dimension = d;
            min_buckets = buckets;
        }
    }
    // Sort the buckets as vanilla sorts its bucket subtrees, by their bounds.
    let mut bucket_nodes: Vec<(Space, Vec<usize>)> = min_buckets
        .into_iter()
        .map(|b| (space_of(nodes, &b), b))
        .collect();
    let key = |space: &Space| -> [i64; DIMENSIONS] {
        std::array::from_fn(|k| {
            space[(min_dimension + k) % DIMENSIONS]
                .center()
                .wrapping_abs()
        })
    };
    bucket_nodes.sort_by_cached_key(|(space, _)| key(space));
    let built: Vec<usize> = bucket_nodes
        .into_iter()
        .map(|(_, b)| build(nodes, b, per_node))
        .collect();
    let space = space_of(nodes, &built);
    nodes.push(Node::SubTree {
        space,
        children: built,
    });
    nodes.len() - 1
}

#[cfg(test)]
mod tests {
    use super::*;

    fn point(t: (i64, i64), offset: i64) -> Space {
        let mut space = [Parameter { min: 0, max: 0 }; DIMENSIONS];
        space[0] = Parameter { min: t.0, max: t.1 };
        space[6] = Parameter {
            min: offset,
            max: offset,
        };
        space
    }

    #[test]
    fn quantizes_like_java() {
        assert_eq!(quantize(0.5), 5000);
        assert_eq!(quantize(-0.123456), -1234);
        assert_eq!(quantize(f32::NAN), 0);
    }

    #[test]
    fn finds_the_closest_and_keeps_ties_with_the_last_result() {
        let points: Vec<(Space, u16)> = (0..100)
            .map(|i| (point((i * 100, i * 100 + 100), 0), i as u16))
            .collect();
        let list = ParameterList::new((0..100).map(|i| format!("b{i}")).collect(), points).unwrap();
        let mut last = None;
        assert_eq!(list.find(&[250, 0, 0, 0, 0, 0], &mut last), 2);
        assert_eq!(list.find(&[-5000, 0, 0, 0, 0, 0], &mut last), 0);
        // 200 lies in both [100, 200] and [200, 300]; the last result wins.
        let mut from_one = Some(list.leaves[1]);
        assert_eq!(list.find(&[200, 0, 0, 0, 0, 0], &mut from_one), 1);
        let mut from_two = Some(list.leaves[2]);
        assert_eq!(list.find(&[200, 0, 0, 0, 0, 0], &mut from_two), 2);
        assert_eq!(list.closest_biomes(&[200, 0, 0, 0, 0, 0]), vec![1, 2]);
    }

    #[test]
    fn search_agrees_with_brute_force_distance() {
        let mut points = Vec::new();
        let mut seed = 7u64;
        let mut next = || {
            seed = seed
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            ((seed >> 33) % 20001) as i64 - 10000
        };
        for i in 0..2000 {
            let (a, b) = (next(), next());
            points.push((
                point((a.min(b), a.max(b)), (next() + 10000) / 4),
                (i % 50) as u16,
            ));
        }
        let list = ParameterList::new((0..50).map(|i| format!("b{i}")).collect(), points).unwrap();
        let mut last = None;
        for _ in 0..500 {
            let target = [next(), 0, 0, 0, 0, 0];
            let found = list.find(&target, &mut last);
            assert!(list.closest_biomes(&target).contains(&found));
        }
    }
}
