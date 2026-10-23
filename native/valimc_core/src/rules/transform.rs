//! Tools' block transformers (VMC-039a, `BlockTransformer.transformBlock`):
//! a hoe tills, a shovel flattens a path, an axe strips, scrapes and
//! unwaxes. Each transformer is a list of entries tried in order; an entry
//! applies unless the clicked face is one it refuses, and gives the state
//! its provider gives for the clicked state with air (the `air` tag) above or
//! with anything else above (`priv/physics/block_transformers.json`, from
//! GrowthOracle). The new state takes its neighbours' shapes
//! (`Block.updateFromNeighbourShapes`) unless the entry says not, and is set
//! with `UPDATE_ALL_IMMEDIATE`. The item's wear, sound and particles are the
//! caller's.

use std::collections::HashMap;

use super::updater::{Engine, World, ALL, UPDATE_LIMIT, UPDATE_SHAPE_ORDER};
use super::{at, BlockAccess};
use crate::worldgen::blocks::{BlockSet, BlockTable};
use crate::worldgen::json::Json;

/// `Block.UPDATE_IMMEDIATE`.
const IMMEDIATE: i32 = 8;

/// `Direction` names in `STEP` order.
const FACES: [&str; 6] = ["down", "up", "north", "south", "west", "east"];

struct Entry {
    /// Refused faces, a bit per `STEP` index.
    refused: u8,
    update_from_neighbors: bool,
    /// Per clicked state: the state with air above and with anything else
    /// above (`None`: the provider gives none).
    results: HashMap<u16, (Option<u16>, Option<u16>)>,
}

/// The tools' transformers, in the facts' (name) order.
pub struct Transformers {
    tools: Vec<Vec<Entry>>,
    air: BlockSet,
}

impl Transformers {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<Transformers, String> {
        let state = |v: &Json| -> Result<Option<u16>, String> {
            let v = v.as_i32()?;
            Ok((v >= 0).then_some(v as u16))
        };
        let tools = json
            .field("transformers")?
            .entries()?
            .iter()
            .map(|(_, entries)| {
                entries
                    .as_array()?
                    .iter()
                    .map(|e| {
                        let mut refused = 0u8;
                        for face in e.field("disallowed_faces")?.as_array()? {
                            let face = face.as_str()?;
                            let i = FACES
                                .iter()
                                .position(|&f| f == face)
                                .ok_or_else(|| format!("unknown face {face}"))?;
                            refused |= 1 << i;
                        }
                        let results = e
                            .field("results")?
                            .as_array()?
                            .iter()
                            .map(|r| {
                                let r = r.as_array()?;
                                Ok((r[0].as_i32()? as u16, (state(&r[1])?, state(&r[2])?)))
                            })
                            .collect::<Result<HashMap<_, _>, String>>()?;
                        Ok(Entry {
                            refused,
                            update_from_neighbors: e.field("update_from_neighbors")?.as_bool()?,
                            results,
                        })
                    })
                    .collect::<Result<Vec<_>, String>>()
            })
            .collect::<Result<Vec<_>, String>>()?;
        Ok(Transformers {
            tools,
            air: table.tag("minecraft:air")?.clone(),
        })
    }
}

impl<W: World> Engine<'_, W> {
    /// A tool's transformer `tool` used on the block at `pos` from face
    /// `face` (a `STEP` index): 0 when no entry applies (the use passes on),
    /// else the applied entry's index + 1.
    pub fn transform(&mut self, pos: [i32; 3], tool: usize, face: usize) -> i32 {
        let Some(transformers) = self.rules.transformers.as_ref() else {
            return 0;
        };
        if !self.world.owns(pos) || face >= 6 {
            return 0;
        }
        let table = self.rules.table.clone();
        let Some(entries) = transformers.tools.get(tool) else {
            return 0;
        };
        let state = self.world.get(pos);
        let above = self.world.get(at(pos, 1));
        let open = transformers.air.contains(table.block_of(above));
        let found = entries.iter().enumerate().find_map(|(i, e)| {
            let (with_air, without) = *e.results.get(&state)?;
            let new = if open { with_air } else { without };
            (e.refused & (1 << face) == 0)
                .then_some(new)
                .flatten()
                .map(|new| (i, new, e.update_from_neighbors))
        });
        let Some((index, new, update)) = found else {
            return 0;
        };
        let new = if update {
            self.shaped_by_neighbours(new, pos)
        } else {
            new
        };
        self.set_block(pos, new, ALL | IMMEDIATE, UPDATE_LIMIT);
        index as i32 + 1
    }

    /// `Block.updateFromNeighbourShapes`: the state as its neighbours'
    /// shapes leave it, in `UPDATE_SHAPE_ORDER`.
    fn shaped_by_neighbours(&mut self, state: u16, pos: [i32; 3]) -> u16 {
        let mut state = state;
        for d in UPDATE_SHAPE_ORDER {
            let neighbour = at(pos, d);
            let neighbour_state = self.world.get(neighbour);
            let access: &mut dyn BlockAccess = &mut self.world;
            if let Ok(new) = self.rules.live_update_shape(
                access,
                state,
                pos,
                d,
                Some((neighbour, neighbour_state)),
            ) {
                state = new;
            }
        }
        state
    }
}
