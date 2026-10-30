//! The dragon's generated facts (`registry/dragon_facts.json`): its ambient interval and head turn limit,
//! the arena's 24 path nodes, its eight parts' sizes and each phase's
//! profile.

use crate::worldgen::json::Json;

/// A phase's flight profile (`Facts.phase/1`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PhaseFacts {
    /// Its climb and dive limit (`getFlySpeed`).
    pub speed: f64,
    pub sitting: bool,
    /// The landing phase steers at its own gain.
    pub landing: bool,
}

/// One arena path node before the arena's height is known.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NodeFacts {
    pub x: i64,
    /// Above the column's height.
    pub offset: i64,
    pub z: i64,
    /// The nodes it links to, one bit each.
    pub mask: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DragonFacts {
    pub ambient_interval: i64,
    pub max_head_y_rot: f64,
    pub graph: Vec<NodeFacts>,
    /// Each part's `(width, height)`, in the client's part order.
    pub parts: Vec<(f64, f64)>,
    /// By phase id.
    pub phases: Vec<PhaseFacts>,
}

impl DragonFacts {
    pub fn parse(json: &Json) -> Result<DragonFacts, String> {
        let graph = json
            .field("graph")?
            .as_array()?
            .iter()
            .map(|row| match row.as_array()? {
                [x, offset, z, mask] => Ok(NodeFacts {
                    x: x.as_f64()?.trunc() as i64,
                    offset: offset.as_f64()?.trunc() as i64,
                    z: z.as_f64()?.trunc() as i64,
                    mask: mask.as_f64()?.trunc() as i64,
                }),
                _ => Err("a dragon path node needs four numbers".to_string()),
            })
            .collect::<Result<Vec<_>, String>>()?;
        let parts = json
            .field("parts")?
            .as_array()?
            .iter()
            .map(|p| Ok((p.field("width")?.as_f64()?, p.field("height")?.as_f64()?)))
            .collect::<Result<Vec<_>, String>>()?;
        let mut phases = Vec::new();
        for p in json.field("phases")?.as_array()? {
            let id = p.field("id")?.as_i32()? as usize;
            if phases.len() <= id {
                phases.resize(id + 1, PhaseFacts::default());
            }
            phases[id] = PhaseFacts {
                speed: p.field("speed")?.as_f64()?,
                sitting: p.field("sitting")?.as_bool()?,
                landing: p.field("name")?.as_str()? == "Landing",
            };
        }
        if graph.len() != 24 || parts.len() != 8 || phases.len() != 11 {
            return Err("dragon facts: 24 nodes, 8 parts and 11 phases expected".into());
        }
        Ok(DragonFacts {
            ambient_interval: json.field("ambient_interval")?.as_i32()? as i64,
            max_head_y_rot: json.field("max_head_y_rot")?.as_f64()?,
            graph,
            parts,
            phases,
        })
    }

    /// `Facts.phase/1`.
    pub fn phase(&self, id: i64) -> PhaseFacts {
        usize::try_from(id)
            .ok()
            .and_then(|i| self.phases.get(i))
            .copied()
            .unwrap_or_default()
    }

    /// The head's height (`head_height/0`).
    pub fn head_height(&self) -> f64 {
        self.parts[0].1
    }
}
