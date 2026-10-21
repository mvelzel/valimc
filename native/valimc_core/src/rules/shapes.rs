//! Vanilla's `updateShape` (VMC-025b), from the generated shape update facts
//! (`ShapeOracle`, `priv/worldgen/shapes.json`): per state and direction a rule over the
//! cells the call reads (the neighbour among them), mapping class
//! combinations to an outcome, the state it becomes and the ticks it
//! schedules. States without a rule keep their state; states whose class
//! overrides `updateShape` without facts fail rather than guess.

use super::support::Partition;
use crate::worldgen::json::Json;

/// A tick an update schedules: offset, block (`false`) or fluid, its id and
/// delay.
#[derive(Clone, Copy, Debug)]
pub struct Tick {
    pub offset: [i32; 3],
    pub fluid: bool,
    pub id: u16,
    pub delay: i32,
}

#[derive(Debug)]
struct Outcome {
    /// The new state, or `None` for unchanged.
    state: Option<u16>,
    ticks: Vec<Tick>,
}

struct Rule {
    offsets: Vec<([i32; 3], usize)>,
    table: Vec<u32>,
}

/// What a state does toward a direction.
#[derive(Clone, Copy, Debug)]
enum Entry {
    Unchanged,
    Rule(u32),
    Unmodelled,
}

pub struct Shapes {
    partitions: Vec<Partition>,
    outcomes: Vec<Outcome>,
    rules: Vec<Rule>,
    /// Per state, per direction.
    entries: Vec<[Entry; 6]>,
}

impl Shapes {
    pub fn parse(json: &Json) -> Result<Shapes, String> {
        let partitions = json
            .field("partitions")?
            .as_array()?
            .iter()
            .map(Partition::parse)
            .collect::<Result<Vec<_>, String>>()?;
        let outcomes = json
            .field("outcomes")?
            .as_array()?
            .iter()
            .map(|o| {
                let o = o.as_array()?;
                let state = o[0].as_i32()?;
                let ticks = o[1]
                    .as_array()?
                    .iter()
                    .map(|t| {
                        let t = t.as_array()?;
                        Ok(Tick {
                            offset: [t[0].as_i32()?, t[1].as_i32()?, t[2].as_i32()?],
                            fluid: t[3].as_i32()? == 1,
                            id: t[4].as_i32()? as u16,
                            delay: t[5].as_i32()?,
                        })
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                Ok(Outcome {
                    state: (state >= 0).then_some(state as u16),
                    ticks,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        let rules = json
            .field("rules")?
            .as_array()?
            .iter()
            .map(|r| {
                let offsets = r
                    .field("offsets")?
                    .as_array()?
                    .iter()
                    .zip(r.field("partitions")?.as_array()?)
                    .map(|(o, p)| {
                        let o = o.as_array()?;
                        Ok((
                            [o[0].as_i32()?, o[1].as_i32()?, o[2].as_i32()?],
                            p.as_i32()? as usize,
                        ))
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                let table = r
                    .field("table")?
                    .as_array()?
                    .iter()
                    .map(|t| t.as_i32().map(|t| t as u32))
                    .collect::<Result<Vec<_>, String>>()?;
                Ok(Rule { offsets, table })
            })
            .collect::<Result<Vec<_>, String>>()?;
        let count = json.field("state_count")?.as_i32()? as usize;
        let mut entries = vec![[Entry::Unchanged; 6]; count];
        for run in json.field("unmodelled")?.as_array()? {
            let run = run.as_array()?;
            for slot in &mut entries[run[0].as_i32()? as usize..=run[1].as_i32()? as usize] {
                *slot = [Entry::Unmodelled; 6];
            }
        }
        for row in json.field("states")?.as_array()? {
            let row = row.as_array()?;
            let state = row[0].as_i32()? as usize;
            for d in 0..6 {
                entries[state][d] = match row[d + 1].as_i32()? {
                    -1 => Entry::Unchanged,
                    -2 => Entry::Unmodelled,
                    rule => Entry::Rule(rule as u32),
                };
            }
        }
        Ok(Shapes {
            partitions,
            outcomes,
            rules,
            entries,
        })
    }

    /// Whether the facts model `state`'s update toward `d`.
    pub fn models(&self, state: u16, d: usize) -> bool {
        !matches!(self.entries[state as usize][d], Entry::Unmodelled)
    }

    /// `state.updateShape` at `pos` toward direction `d`: the new state and
    /// the ticks to schedule (offsets from `pos`), reading cells through
    /// `read`.
    pub fn update(
        &self,
        state: u16,
        d: usize,
        pos: [i32; 3],
        read: &mut dyn FnMut([i32; 3]) -> u16,
    ) -> Result<(u16, &[Tick]), String> {
        let rule = match self.entries[state as usize][d] {
            Entry::Unchanged => return Ok((state, &[])),
            Entry::Unmodelled => {
                return Err(format!(
                    "updateShape of state {state} toward direction {d} is not modelled"
                ))
            }
            Entry::Rule(rule) => &self.rules[rule as usize],
        };
        let mut index = 0usize;
        for (offset, partition) in &rule.offsets {
            let cell = read([pos[0] + offset[0], pos[1] + offset[1], pos[2] + offset[2]]);
            let partition = &self.partitions[*partition];
            index = index * partition.radix + partition.class(cell);
        }
        let outcome = &self.outcomes[rule.table[index] as usize];
        Ok((outcome.state.unwrap_or(state), &outcome.ticks))
    }
}
