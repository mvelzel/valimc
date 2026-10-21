//! Vanilla `canSurvive` and the survival half of `updateShape`, from the
//! generated survival facts (`SupportOracle`). Two sets exist (VMC-029c,
//! VMC-077d): decoration's (`priv/worldgen/survival.json`), checked before
//! placement with the block's own cell read like a neighbour and unlit
//! chunks' light; and live play's (`priv/physics/support.json`), checked
//! after placement, where a rule that reads light holds if bright or dark
//! light lets it, and each state also has a reaction per update direction
//! while it cannot survive (break at once, schedule its tick, or nothing) and
//! neighbour overrides (the other half of a door, bed or tall plant). A
//! state's rule reads a few cells, maps each to its class in a partition of
//! all states, and looks the class combination up in a table.

use crate::worldgen::json::Json;

/// A partition of all states into classes, from runs `[first state, class,
/// …]` (shared with the shape update facts).
pub(crate) struct Partition {
    /// Run starts and their classes.
    starts: Vec<u16>,
    classes: Vec<u8>,
    pub(crate) radix: usize,
}

impl Partition {
    pub(crate) fn parse(runs: &Json) -> Result<Partition, String> {
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
    }

    pub(crate) fn class(&self, state: u16) -> usize {
        let run = self.starts.partition_point(|&s| s <= state) - 1;
        self.classes[run] as usize
    }
}

struct Rule {
    offsets: Vec<([i32; 3], usize)>,
    table: Vec<bool>,
}

/// What an override's neighbour class decides.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Code {
    Rule,
    Break,
    Keep,
}

struct Override {
    direction: usize,
    partition: usize,
    codes: Vec<Code>,
}

/// A dependent state's facts: its rule, and for live play its reactions
/// (0 nothing, -1 break, n > 0 a tick n ticks out) and overrides.
struct Profile {
    rule: Option<u32>,
    reactions: [i32; 6],
    overrides: Vec<Override>,
}

/// What an update from one direction does to a dependent state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reaction {
    Keep,
    Break,
    Tick(i32),
}

pub struct Support {
    partitions: Vec<Partition>,
    rules: Vec<Rule>,
    profiles: Vec<Profile>,
    /// Per state: its profile, if it has one.
    profile_of: Vec<Option<u32>>,
}

impl Support {
    /// Either set of facts: live play's carries `profiles`, decoration's
    /// names a rule per state run.
    pub fn parse(json: &Json) -> Result<Support, String> {
        let partitions = json
            .field("partitions")?
            .as_array()?
            .iter()
            .map(Partition::parse)
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
        let profiles = match json.get("profiles") {
            None => (0..rules.len())
                .map(|rule| Profile {
                    rule: Some(rule as u32),
                    reactions: [0; 6],
                    overrides: Vec::new(),
                })
                .collect(),
            Some(profiles) => profiles
                .as_array()?
                .iter()
                .map(|profile| {
                    let rule = match profile.get("rule") {
                        Some(Json::Null) | None => None,
                        Some(rule) => Some(rule.as_i32()? as u32),
                    };
                    let reactions = profile.field("reactions")?.as_array()?;
                    let mut directions = [0; 6];
                    for (d, reaction) in reactions.iter().enumerate().take(6) {
                        directions[d] = reaction.as_i32()?;
                    }
                    let overrides = profile
                        .field("overrides")?
                        .as_array()?
                        .iter()
                        .map(|o| {
                            let o = o.as_array()?;
                            let codes = o[2]
                                .as_array()?
                                .iter()
                                .map(|c| match c.as_i32()? {
                                    0 => Ok(Code::Rule),
                                    1 => Ok(Code::Break),
                                    2 => Ok(Code::Keep),
                                    code => Err(format!("override code {code}")),
                                })
                                .collect::<Result<Vec<_>, String>>()?;
                            Ok(Override {
                                direction: o[0].as_i32()? as usize,
                                partition: o[1].as_i32()? as usize,
                                codes,
                            })
                        })
                        .collect::<Result<Vec<_>, String>>()?;
                    Ok(Profile {
                        rule,
                        reactions: directions,
                        overrides,
                    })
                })
                .collect::<Result<Vec<_>, String>>()?,
        };
        let count = json.field("state_count")?.as_i32()? as usize;
        let mut profile_of = vec![None; count];
        for run in json.field("states")?.as_array()? {
            let run = run.as_array()?;
            let (first, last, profile) = (
                run[0].as_i32()? as usize,
                run[1].as_i32()? as usize,
                run[2].as_i32()? as u32,
            );
            if profile as usize >= profiles.len() {
                return Err("survival state run names no profile".into());
            }
            for slot in &mut profile_of[first..=last] {
                *slot = Some(profile);
            }
        }
        Ok(Support {
            partitions,
            rules,
            profiles,
            profile_of,
        })
    }

    fn profile(&self, state: u16) -> Option<&Profile> {
        self.profile_of[state as usize].map(|p| &self.profiles[p as usize])
    }

    /// Whether the state has survival facts.
    pub fn dependent(&self, state: u16) -> bool {
        self.profile_of[state as usize].is_some()
    }

    fn class(&self, partition: usize, state: u16) -> usize {
        self.partitions[partition].class(state)
    }

    fn rule_survives(
        &self,
        rule: Option<u32>,
        pos: [i32; 3],
        read: &mut dyn FnMut([i32; 3]) -> u16,
    ) -> bool {
        let Some(rule) = rule else {
            return true;
        };
        let rule = &self.rules[rule as usize];
        let mut index = 0usize;
        for (offset, partition) in &rule.offsets {
            let neighbour = read([pos[0] + offset[0], pos[1] + offset[1], pos[2] + offset[2]]);
            index = index * self.partitions[*partition].radix + self.class(*partition, neighbour);
        }
        rule.table[index]
    }

    /// `state.canSurvive(level, pos)`, reading neighbours through `read`.
    pub fn survives(
        &self,
        state: u16,
        pos: [i32; 3],
        read: &mut dyn FnMut([i32; 3]) -> u16,
    ) -> bool {
        self.profile(state)
            .is_none_or(|p| self.rule_survives(p.rule, pos, read))
    }

    fn override_code(
        &self,
        profile: &Profile,
        pos: [i32; 3],
        d: usize,
        read: &mut dyn FnMut([i32; 3]) -> u16,
    ) -> Code {
        match profile.overrides.iter().find(|o| o.direction == d) {
            Some(o) => o.codes[self.class(o.partition, read(super::at(pos, d)))],
            None => Code::Rule,
        }
    }

    /// The survival half of `updateShape` after the neighbour in direction
    /// `d` changed (live play's facts).
    pub fn update(
        &self,
        state: u16,
        pos: [i32; 3],
        d: usize,
        read: &mut dyn FnMut([i32; 3]) -> u16,
    ) -> Reaction {
        let Some(profile) = self.profile(state) else {
            return Reaction::Keep;
        };
        match self.override_code(profile, pos, d, read) {
            Code::Break => Reaction::Break,
            Code::Keep => Reaction::Keep,
            Code::Rule => match profile.reactions[d] {
                0 => Reaction::Keep,
                _ if self.rule_survives(profile.rule, pos, read) => Reaction::Keep,
                -1 => Reaction::Break,
                delay => Reaction::Tick(delay),
            },
        }
    }

    /// At the state's scheduled tick: whether it can no longer survive or a
    /// neighbour override breaks it (live play's facts).
    pub fn breaks(&self, state: u16, pos: [i32; 3], read: &mut dyn FnMut([i32; 3]) -> u16) -> bool {
        let Some(profile) = self.profile(state) else {
            return false;
        };
        !self.rule_survives(profile.rule, pos, read)
            || profile
                .overrides
                .iter()
                .any(|o| self.override_code(profile, pos, o.direction, read) == Code::Break)
    }
}
