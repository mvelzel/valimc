//! What cows, pigs and chickens share (`Valimc.Entity.Animals.Variants`): a
//! temperature variant and a sound variant, registry entries the client
//! knows by network id (temperate and classic by default), a child taking
//! either parent's variant, and sounds from its sound variant (a baby's own
//! set where the variant has one). Also `selectVariantToSpawn` and
//! `Registry.getRandom` over the level's random, which other animals use.

use super::age;
use crate::mobs::ai::spawn;
use crate::mobs::ai::turn::Turn;
use crate::mobs::combat::{SoundKind, SoundRef};
use crate::mobs::facts::families::Condition;
use crate::mobs::facts::MobFacts;
use crate::mobs::living::difficulty::moon_brightness;
use crate::mobs::model::{Body, FamilyData};
use crate::mobs::term::{Atom, Value};
use std::collections::HashMap;

/// `Variants.data/0`.
pub fn data() -> Vec<(Atom, Value)> {
    vec![
        (
            Atom::from_static("variant"),
            Value::Binary(b"minecraft:temperate".to_vec()),
        ),
        (
            Atom::from_static("sound_variant"),
            Value::Binary(b"minecraft:classic".to_vec()),
        ),
    ]
}

/// A text field of the data.
pub fn text<'d>(data: &'d FamilyData, key: &str) -> Option<&'d str> {
    data.get(key)
        .and_then(Value::as_binary)
        .and_then(|b| std::str::from_utf8(b).ok())
}

/// A sound variant's sound ids, and a baby's where it has its own.
type SoundSets = (HashMap<String, i32>, Option<HashMap<String, i32>>);

/// A variant animal's tables: its variants' and sound variants' network
/// ids and its sound variants' sound ids (a baby's set where it has one).
#[derive(Debug)]
pub struct Variants {
    pub kind: &'static str,
    variants: HashMap<String, i64>,
    sounds: HashMap<String, i64>,
    sets: HashMap<String, SoundSets>,
}

impl Variants {
    /// Of a `kind` (`cow`, `pig`, `chicken`).
    pub fn new(facts: &MobFacts, kind: &'static str) -> Result<Variants, String> {
        let ids = |registry: &str| -> Result<HashMap<String, i64>, String> {
            let names = facts
                .registries
                .get(registry)
                .ok_or_else(|| format!("no registry {registry}"))?;
            Ok(names
                .names
                .iter()
                .enumerate()
                .map(|(i, n)| (n.clone(), i as i64))
                .collect())
        };
        let resolve = |set: &HashMap<String, String>| -> HashMap<String, i32> {
            set.iter()
                .filter_map(|(k, v)| Some((k.clone(), facts.sounds.id(v)?)))
                .collect()
        };
        let registry = format!("minecraft:{kind}_sound_variant");
        let sets = facts
            .animal
            .sound_variants
            .get(&registry)
            .ok_or_else(|| format!("no sound variants of {kind}"))?
            .iter()
            .map(|(name, v)| {
                (
                    name.clone(),
                    (resolve(&v.adult), v.baby.as_ref().map(resolve)),
                )
            })
            .collect();
        Ok(Variants {
            kind,
            variants: ids(&format!("minecraft:{kind}_variant"))?,
            sounds: ids(&registry)?,
            sets,
        })
    }

    /// `Variants.values/2`.
    pub fn values(&self, data: &FamilyData) -> Vec<(Atom, Value, Value)> {
        let id = |table: &HashMap<String, i64>, name: &str| {
            Value::Int(table.get(name).copied().unwrap_or(0))
        };
        let variant = text(data, "variant").unwrap_or("minecraft:temperate");
        let sound = text(data, "sound_variant").unwrap_or("minecraft:classic");
        vec![
            (
                Atom::new(&format!("{}_variant", self.kind)),
                id(&self.variants, variant),
                id(&self.variants, "minecraft:temperate"),
            ),
            (
                Atom::new(&format!("{}_sound_variant", self.kind)),
                id(&self.sounds, sound),
                id(&self.sounds, "minecraft:classic"),
            ),
        ]
    }

    /// Sound `which` (`ambient`, `hurt`, `death`, `eat`) of its sound
    /// variant, a baby's where it has one (`Animal.sound_set/2`).
    pub fn sound(&self, data: &FamilyData, which: &str) -> Option<i32> {
        let (adult, baby) = self.sets.get(text(data, "sound_variant")?)?;
        let set = match baby {
            Some(baby) if age(data) < 0 => baby,
            _ => adult,
        };
        set.get(which).copied()
    }

    /// `Variants.combat_sound/3`: its hurt or death sound, by id.
    pub fn combat_sound(&self, body: &Body, which: SoundKind) -> Option<SoundRef> {
        let key = match which {
            SoundKind::Hurt => "hurt",
            SoundKind::Death => "death",
        };
        self.sound(&body.data, key).map(SoundRef::Id)
    }
}

/// `Animal.spawn_variant/4` of `registry` at the mob: the variants matching
/// at the highest priority (`BiomeCheck`, `StructureCheck`,
/// `MoonBrightnessCheck`), one picked from the level's random.
pub fn pick_variant(t: &mut Turn, registry: &str) -> Option<String> {
    let facts = t.level.facts;
    let list = facts.animal.variants.get(registry)?;
    let block = t.block();
    let biome = t.level.biome(block);
    let moon = moon_brightness(t.level.day);
    let holds = |c: &Condition| match c {
        Condition::Biomes(tag) => facts.biome_in(Some(biome), tag),
        Condition::Structures(names) => {
            let names: Vec<&str> = names.iter().map(String::as_str).collect();
            t.level.in_structure(block, &names)
        }
        Condition::Moon(min, max) => min.is_none_or(|m| moon >= m) && max.is_none_or(|m| moon <= m),
    };
    let matching: Vec<(i32, &str)> = list
        .iter()
        .flat_map(|v| {
            v.selectors
                .iter()
                .filter(|(_, c)| c.as_ref().is_none_or(holds))
                .map(move |(p, _)| (*p, v.name.as_str()))
        })
        .collect();
    let top = matching.iter().map(|(p, _)| *p).max()?;
    let names: Vec<&str> = matching
        .iter()
        .filter(|(p, _)| *p == top)
        .map(|(_, n)| *n)
        .collect();
    let n = spawn::level_int(t, names.len() as i32);
    names.get(n as usize).map(|s| s.to_string())
}

/// `Animal.pick_random/2`: `Registry.getRandom` of `registry`'s entries in
/// network order, from the level's random.
pub fn pick_random(t: &mut Turn, registry: &str) -> Option<String> {
    let names = &t.level.facts.registries.get(registry)?.names;
    let n = spawn::level_int(t, names.len() as i32);
    names.get(n as usize).cloned()
}

/// `Variants.finalize/2`: the biome's variant, then a random sound variant,
/// both from the level's random.
pub fn finalize(t: &mut Turn, kind: &str) {
    let variant = pick_variant(t, &format!("minecraft:{kind}_variant"));
    let sound = pick_random(t, &format!("minecraft:{kind}_sound_variant"));
    let data = &mut t.mob.body.data;
    if let Some(v) = variant {
        data.set("variant", Value::Binary(v.into_bytes()));
    }
    if let Some(s) = sound {
        data.set("sound_variant", Value::Binary(s.into_bytes()));
    }
}

/// `Variants.offspring/2`: the parent's or the partner's variant.
pub fn offspring(t: &mut Turn, partner: &FamilyData) -> Vec<(Atom, Value)> {
    let mine = t.boolean();
    let variant = if mine {
        t.data().get("variant").cloned()
    } else {
        partner.get("variant").cloned()
    };
    variant
        .map(|v| vec![(Atom::from_static("variant"), v)])
        .unwrap_or_default()
}

/// `properties/1` of a variant animal: `{"minecraft:<kind>/variant", v}`.
pub fn properties(kind: &str, data: &FamilyData) -> Vec<(String, String)> {
    text(data, "variant")
        .map(|v| vec![(format!("minecraft:{kind}/variant"), v.to_string())])
        .unwrap_or_default()
}
