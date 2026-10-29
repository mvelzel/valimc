//! The AI facts (`Valimc.AI.Facts`, `ai_facts.json`): per modelled mob its
//! head limits, ambient sound, path malus and the goals vanilla registers;
//! the path types and their default malus; the items whose
//! `mob_visibility` hides their wearer; a shulker's look axes and the swing
//! packet's fields. `Mth.atan2`'s tables are `physics::mob`'s and each
//! state's path type and flags the path crate's (`path_facts_init`).

use super::{float_bits, hex_bytes, int, map, optional_string, string, Context, Slot};
use crate::worldgen::json::Json;
use std::collections::HashMap;

/// `Goal.Flag` bits.
pub const MOVE: u8 = 1;
pub const LOOK: u8 = 2;
pub const JUMP: u8 = 4;
pub const TARGET: u8 = 8;

/// A goal vanilla registers: its priority, class name and flags.
#[derive(Debug, Clone, PartialEq)]
pub struct GoalFact {
    pub priority: i32,
    pub name: String,
    pub flags: u8,
}

/// One modelled mob's AI facts (`Facts.mob/1`).
#[derive(Debug, Clone, PartialEq)]
pub struct AiMob {
    pub max_head_y_rot: f64,
    pub max_head_x_rot: f64,
    pub head_rot_speed: f64,
    pub ambient_sound: Option<String>,
    pub ambient_interval: i32,
    pub volume: f64,
    pub monster: bool,
    /// Per path type ordinal: the type's default malus with the mob's
    /// overrides.
    pub malus: Vec<f64>,
    pub goals: Vec<GoalFact>,
    pub targets: Vec<GoalFact>,
}

/// An item's `mob_visibility` (`Facts.visibility/1`).
#[derive(Debug, Clone, PartialEq)]
pub struct Visibility {
    pub visibility: f64,
    pub slot: Slot,
    /// The entity types it hides its wearer from.
    pub types: Vec<u16>,
}

#[derive(Debug)]
pub struct AiFacts {
    /// Path type names and default malus by ordinal.
    pub path_types: Vec<(String, f64)>,
    /// By entity type id.
    pub mobs: HashMap<u16, AiMob>,
    /// By item id.
    pub visibility: HashMap<i32, Visibility>,
    /// A shulker's `[fx, fy, fz, rx, ry, rz]` per face.
    pub shulker_look: Vec<[f32; 6]>,
    /// The swing packet's fields after the entity id (main hand).
    pub swing_fields: Vec<u8>,
}

fn flag(name: &str) -> Result<u8, String> {
    Ok(match name {
        "move" => MOVE,
        "look" => LOOK,
        "jump" => JUMP,
        "target" => TARGET,
        other => return Err(format!("unknown goal flag {other}")),
    })
}

fn goals(json: &Json) -> Result<Vec<GoalFact>, String> {
    json.as_array()?
        .iter()
        .map(|g| match g.as_array()? {
            [priority, name, flags] => Ok(GoalFact {
                priority: int(priority)?,
                name: string(name)?,
                flags: flags
                    .as_array()?
                    .iter()
                    .map(|f| f.as_str().and_then(flag))
                    .try_fold(0, |acc, f| f.map(|f| acc | f))?,
            }),
            _ => Err("bad goal".into()),
        })
        .collect()
}

impl AiFacts {
    pub(crate) fn parse(ctx: &Context, json: &Json) -> Result<AiFacts, String> {
        let path_types = json
            .field("path_types")?
            .as_array()?
            .iter()
            .map(|t| Ok((string(t.field("name")?)?, t.field("malus")?.as_f64()?)))
            .collect::<Result<Vec<_>, String>>()?;
        let mut mobs = HashMap::new();
        for (name, row) in json.field("mobs")?.entries()? {
            let f = |k: &str| row.field(k).map_err(|e| format!("{name}: {e}"));
            let mut malus: Vec<f64> = path_types.iter().map(|t| t.1).collect();
            for (path_type, v) in f("malus")?.entries()? {
                let i = path_types
                    .iter()
                    .position(|t| t.0 == *path_type)
                    .ok_or_else(|| format!("{name}: unknown path type {path_type}"))?;
                malus[i] = v.as_f64()?;
            }
            let mob = AiMob {
                max_head_y_rot: f("max_head_y_rot")?.as_f64()?,
                max_head_x_rot: f("max_head_x_rot")?.as_f64()?,
                head_rot_speed: f("head_rot_speed")?.as_f64()?,
                ambient_sound: optional_string(row.get("ambient_sound"))?,
                ambient_interval: int(f("ambient_sound_interval")?)?,
                volume: f("sound_volume")?.as_f64()?,
                monster: f("monster")?.as_bool()?,
                malus,
                goals: goals(f("goals")?)?,
                targets: goals(f("targets")?)?,
            };
            mobs.insert(ctx.entity(name)?, mob);
        }
        let visibility = map(json.field("mob_visibility")?, |_, row| {
            Ok(Visibility {
                visibility: row.field("visibility")?.as_f64()?,
                slot: Slot::parse(row.field("slot")?.as_str()?)?,
                types: row
                    .field("types")?
                    .as_array()?
                    .iter()
                    .map(|t| ctx.entity(t.as_str()?))
                    .collect::<Result<_, _>>()?,
            })
        })?
        .into_iter()
        .map(|(item, v)| Ok((ctx.item(&item)?, v)))
        .collect::<Result<HashMap<_, _>, String>>()?;
        let shulker_look = json
            .field("shulker_look")?
            .as_array()?
            .iter()
            .map(|row| {
                let v = row.as_array()?;
                if v.len() != 6 {
                    return Err("bad shulker look row".to_string());
                }
                let mut out = [0.0f32; 6];
                for (o, j) in out.iter_mut().zip(v) {
                    *o = float_bits(j)?;
                }
                Ok(out)
            })
            .collect::<Result<Vec<_>, String>>()?;
        Ok(AiFacts {
            path_types,
            mobs,
            visibility,
            shulker_look,
            swing_fields: hex_bytes(json.field("swing_fields")?)?,
        })
    }

    /// `Facts.mob/1` by entity type id.
    pub fn mob(&self, id: u16) -> Option<&AiMob> {
        self.mobs.get(&id)
    }

    /// The path type's ordinal by name (`PathType`).
    pub fn path_type(&self, name: &str) -> Option<usize> {
        self.path_types.iter().position(|t| t.0 == name)
    }

    /// `Facts.swing_fields/1`: the off hand's swaps the hand's id.
    pub fn swing_fields(&self, off_hand: bool) -> Vec<u8> {
        let mut fields = self.swing_fields.clone();
        if off_hand && !fields.is_empty() {
            fields[0] = 1;
        }
        fields
    }
}
