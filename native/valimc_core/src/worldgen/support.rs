//! Vanilla `canSurvive` as decoration checks it, from the generated worldgen
//! survival facts (`SupportOracle worldgen`, `priv/worldgen/survival.json`):
//! before placement, so the block's own position is read like a neighbour,
//! under unlit chunks' light (sky 15, block 0). A state's rule reads a few
//! cells, maps each to its class in a partition of all states, and looks the
//! class combination up in a table.

use super::json::Json;

struct Partition {
    /// Run starts and their classes.
    starts: Vec<u16>,
    classes: Vec<u8>,
    radix: usize,
}

impl Partition {
    fn class(&self, state: u16) -> usize {
        let run = self.starts.partition_point(|&s| s <= state) - 1;
        self.classes[run] as usize
    }
}

struct Rule {
    offsets: Vec<([i32; 3], usize)>,
    table: Vec<bool>,
}

pub struct Support {
    partitions: Vec<Partition>,
    rules: Vec<Rule>,
    /// Per state: its rule, if it has one.
    rule_of: Vec<Option<u32>>,
}

impl Support {
    pub fn parse(json: &Json) -> Result<Support, String> {
        let partitions = json
            .field("partitions")?
            .as_array()?
            .iter()
            .map(|runs| {
                let runs = runs.as_array()?;
                let mut starts = Vec::with_capacity(runs.len() / 2);
                let mut classes = Vec::with_capacity(runs.len() / 2);
                for pair in runs.chunks(2) {
                    starts.push(pair[0].as_i32()? as u16);
                    classes.push(pair[1].as_i32()? as u8);
                }
                let radix = classes.iter().copied().max().unwrap_or(0) as usize + 1;
                Ok(Partition {
                    starts,
                    classes,
                    radix,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        let bits = |text: &str| text.bytes().map(|b| b == b'1').collect::<Vec<bool>>();
        let rules = json
            .field("rules")?
            .as_array()?
            .iter()
            .map(|rule| {
                let offsets = rule.field("offsets")?.as_array()?;
                let parts = rule.field("partitions")?.as_array()?;
                let offsets = offsets
                    .iter()
                    .zip(parts)
                    .map(|(o, p)| {
                        let o = o.as_array()?;
                        Ok((
                            [o[0].as_i32()?, o[1].as_i32()?, o[2].as_i32()?],
                            p.as_i32()? as usize,
                        ))
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                let table = bits(rule.field("table")?.as_str()?);
                Ok(Rule { offsets, table })
            })
            .collect::<Result<Vec<_>, String>>()?;
        let count = json.field("state_count")?.as_i32()? as usize;
        let mut rule_of = vec![None; count];
        for run in json.field("states")?.as_array()? {
            let run = run.as_array()?;
            let (first, last, rule) = (
                run[0].as_i32()? as usize,
                run[1].as_i32()? as usize,
                run[2].as_i32()? as u32,
            );
            for slot in &mut rule_of[first..=last] {
                *slot = Some(rule);
            }
        }
        Ok(Support {
            partitions,
            rules,
            rule_of,
        })
    }

    /// `state.canSurvive(level, pos)`, reading neighbours through `read`.
    pub fn survives(
        &self,
        state: u16,
        pos: [i32; 3],
        read: &mut dyn FnMut([i32; 3]) -> u16,
    ) -> bool {
        let Some(rule) = self.rule_of[state as usize] else {
            return true;
        };
        let rule = &self.rules[rule as usize];
        let mut index = 0usize;
        for (offset, partition) in &rule.offsets {
            let neighbour = read([pos[0] + offset[0], pos[1] + offset[1], pos[2] + offset[2]]);
            let partition = &self.partitions[*partition];
            index = index * partition.radix + partition.class(neighbour);
        }
        rule.table[index]
    }
}
