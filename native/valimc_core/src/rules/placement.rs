//! Block placement (VMC-029d): what vanilla's `BlockItem.useOn` writes for
//! a click, from the generated placement facts (`PlacementOracle`,
//! `priv/physics/placement.json`). Per item the root of a decision diagram:
//! a node tests one of the click's inputs (its face and whether it replaces
//! the clicked block, the player's view, the cursor, sneaking, the target's
//! light and redstone power) or the class of a cell around the target, and
//! ends in an outcome: the cells written relative to the target (the block,
//! a door's or bed's other half), a refusal, or alternatives by the level
//! random's draws. A cell's class is its partition's class for its coarse
//! class and its fluid. Connecting blocks and leaves then take their shape
//! updates and leaf distance (`Post`), which the facts leave out.

use std::collections::HashMap;

use crate::worldgen::json::Json;

/// The inputs, in the facts' order: `order` (one of 48 `orderedByNearest`
/// results), `vertical`, `horizontal`, `rotation`, `cursor`, `secondary`,
/// `face`, `replace`, `light` (the target's raw brightness), `sky` (whether
/// the target sees the sky), `signal` and `signal_above` (whether the target
/// and the cell above it receive redstone power), and `inside` (the click's
/// `isInside`, which only scaffolding's walk reads; the facts never test it).
pub const VARS: [&str; 13] = [
    "order",
    "vertical",
    "horizontal",
    "rotation",
    "cursor",
    "secondary",
    "face",
    "replace",
    "light",
    "sky",
    "signal",
    "signal_above",
    "inside",
];

/// What follows the facts' outcome for the placed block.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Post {
    None,
    /// Stairs, fences, bars and panes, walls: their shape updates from all
    /// six neighbours.
    Shape,
    /// Leaves: their distance from logs.
    Leaves,
}

/// What a placement does.
#[derive(Debug, PartialEq, Eq)]
pub enum Placed {
    Refused,
    /// The cells written, the placed block among them.
    Writes(Vec<([i32; 3], u16)>),
    /// Scaffolding clicked on scaffolding: walk along the column to the first
    /// free cell and place there (`ScaffoldingBlockItem.updatePlacementContext`).
    Walk,
    /// A pale moss carpet, placed by the carpet's code.
    MossyCarpet,
}

/// A written state: a state id, or the `k`th state of the item's block
/// (slot 0) or wall block (slot 1), so that items that place alike share
/// their outcomes.
#[derive(Debug, Clone, Copy)]
enum Written {
    State(u16),
    Own(usize, u16),
}

#[derive(Debug)]
enum Outcome {
    Refuse,
    Walk,
    MossyCarpet,
    Writes(Vec<([i32; 3], Written)>),
    /// Alternatives by the draws' values (`nextInt(bound)` each, in order;
    /// the first draw is the most significant).
    Random {
        draws: Vec<i32>,
        outcomes: Vec<u32>,
    },
}

/// A partition of all states: runs of coarse classes, and per coarse class
/// the class by the state's fluid (registry id).
struct Partition {
    starts: Vec<u16>,
    coarse: Vec<u16>,
    fluids: Vec<[u8; 5]>,
}

impl Partition {
    fn class(&self, state: u16, fluid: u8) -> usize {
        let run = self.starts.partition_point(|&s| s <= state) - 1;
        self.fluids[self.coarse[run] as usize][fluid as usize] as usize
    }
}

/// A child: a node's index, or `-1 - id` for an outcome.
enum Node {
    Input {
        var: usize,
        children: Vec<i32>,
    },
    Cell {
        offset: [i32; 3],
        partition: usize,
        children: Vec<i32>,
    },
}

pub struct Placement {
    partitions: Vec<Partition>,
    outcomes: Vec<Outcome>,
    nodes: Vec<Node>,
    /// Per item its root, post step and its own blocks' first states.
    items: HashMap<u16, (i32, Post, [i32; 2])>,
}

impl std::fmt::Debug for Placement {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Placement({} items)", self.items.len())
    }
}

fn ints(json: &Json) -> Result<Vec<i32>, String> {
    json.as_array()?.iter().map(Json::as_i32).collect()
}

impl Placement {
    pub fn parse(json: &Json) -> Result<Placement, String> {
        let partitions = json
            .field("partitions")?
            .as_array()?
            .iter()
            .map(|p| {
                let runs = ints(p.field("runs")?)?;
                let fluids = p
                    .field("fluids")?
                    .as_array()?
                    .iter()
                    .map(|f| {
                        let f = ints(f)?;
                        let mut classes = [0u8; 5];
                        for (c, v) in classes.iter_mut().zip(f) {
                            *c = v as u8;
                        }
                        Ok(classes)
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                Ok(Partition {
                    starts: runs.iter().step_by(2).map(|&s| s as u16).collect(),
                    coarse: runs.iter().skip(1).step_by(2).map(|&c| c as u16).collect(),
                    fluids,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        let outcomes = json
            .field("outcomes")?
            .as_array()?
            .iter()
            .map(|o| match o {
                Json::Null => Ok(Outcome::Refuse),
                Json::String(s) if s == "walk" => Ok(Outcome::Walk),
                Json::String(s) if s == "mossy_carpet" => Ok(Outcome::MossyCarpet),
                Json::Array(writes) => Ok(Outcome::Writes(
                    writes
                        .iter()
                        .map(|w| {
                            let w = ints(w)?;
                            let written = match w.get(4) {
                                Some(&slot) => Written::Own(slot as usize, w[3] as u16),
                                None => Written::State(w[3] as u16),
                            };
                            Ok(([w[0], w[1], w[2]], written))
                        })
                        .collect::<Result<Vec<_>, String>>()?,
                )),
                _ => Ok(Outcome::Random {
                    draws: ints(o.field("draws")?)?,
                    outcomes: ints(o.field("outcomes")?)?
                        .into_iter()
                        .map(|i| i as u32)
                        .collect(),
                }),
            })
            .collect::<Result<Vec<_>, String>>()?;
        let nodes = json
            .field("nodes")?
            .as_array()?
            .iter()
            .map(|n| {
                let n = ints(n)?;
                Ok(match n[0] {
                    0 => Node::Input {
                        var: n[1] as usize,
                        children: n[2..].to_vec(),
                    },
                    _ => Node::Cell {
                        offset: [n[1], n[2], n[3]],
                        partition: n[4] as usize,
                        children: n[5..].to_vec(),
                    },
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        let mut items = HashMap::new();
        for row in json.field("items")?.as_array()? {
            let row = ints(row)?;
            let post = match row[2] {
                0 => Post::None,
                1 => Post::Shape,
                2 => Post::Leaves,
                other => return Err(format!("unknown placement post step {other}")),
            };
            items.insert(row[0] as u16, (row[1], post, [row[3], row[4]]));
        }
        Ok(Placement {
            partitions,
            outcomes,
            nodes,
            items,
        })
    }

    /// Whether the facts place `item`.
    pub fn places(&self, item: u16) -> bool {
        self.items.contains_key(&item)
    }

    /// The post step of `item`'s placed block.
    pub fn post(&self, item: u16) -> Post {
        self.items
            .get(&item)
            .map_or(Post::None, |&(_, post, _)| post)
    }

    /// What placing `item` with the inputs `values` (by `VARS`) writes
    /// around `target`, reading cells through `read` (their fluids through
    /// `fluid`) and drawing with `next_int`.
    pub fn place(
        &self,
        item: u16,
        values: &[u8; 13],
        target: [i32; 3],
        read: &mut dyn FnMut([i32; 3]) -> u16,
        fluid: &dyn Fn(u16) -> u8,
        next_int: &mut dyn FnMut(i32) -> i32,
    ) -> Result<Placed, String> {
        let &(mut child, _, own) = self
            .items
            .get(&item)
            .ok_or_else(|| format!("item {item} has no placement"))?;
        while child >= 0 {
            child = match &self.nodes[child as usize] {
                Node::Input { var, children } => *children
                    .get(values[*var] as usize)
                    .ok_or_else(|| format!("placement input {} out of range", VARS[*var]))?,
                Node::Cell {
                    offset,
                    partition,
                    children,
                } => {
                    let state = read([
                        target[0] + offset[0],
                        target[1] + offset[1],
                        target[2] + offset[2],
                    ]);
                    children[self.partitions[*partition].class(state, fluid(state))]
                }
            };
        }
        let mut outcome = &self.outcomes[(-1 - child) as usize];
        if let Outcome::Random { draws, outcomes } = outcome {
            let mut pick = 0usize;
            for &bound in draws {
                pick = pick * bound as usize + next_int(bound) as usize;
            }
            outcome = &self.outcomes[outcomes[pick] as usize];
        }
        Ok(match outcome {
            Outcome::Refuse => Placed::Refused,
            Outcome::Walk => Placed::Walk,
            Outcome::MossyCarpet => Placed::MossyCarpet,
            Outcome::Writes(writes) => Placed::Writes(
                writes
                    .iter()
                    .map(|&(o, written)| {
                        let state = match written {
                            Written::State(s) => s,
                            Written::Own(slot, k) => (own[slot] + k as i32) as u16,
                        };
                        (
                            [target[0] + o[0], target[1] + o[1], target[2] + o[2]],
                            state,
                        )
                    })
                    .collect(),
            ),
            Outcome::Random { .. } => return Err("nested random placement outcome".into()),
        })
    }
}
