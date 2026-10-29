//! A mooshroom (`Valimc.Entity.Animals.Mooshroom`, vanilla's `MushroomCow`):
//! a cow's goals, red or brown (`type`), a brown one's suspicious stew
//! effects (`stew`, from a flower it ate). A child of two of one colour
//! turns the other once in 1,024 births, else takes either parent's.
//! Milking, shearing and feeding flowers are its interactions.

use super::cow::{self, Milk};
use super::{age, Animal, Species};
use crate::mobs::ai::turn::Turn;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::interact::{Done, Drop, Hand, InteractEvent, Interaction, Outcome};
use crate::mobs::kinds::Registered;
use crate::mobs::living::body as living_body;
use crate::mobs::living::items;
use crate::mobs::living::mob::Type;
use crate::mobs::model::FamilyData;
use crate::mobs::term::{Atom, Map, Value, NIL};
use std::collections::HashMap;

pub struct Mooshroom {
    milk: Milk,
    bowl: Option<i32>,
    shears: Option<i32>,
    mushroom_stew: Option<i32>,
    suspicious_stew: Option<i32>,
    /// Flower item id => its stew's effects (`[{effect, duration}]`).
    flowers: HashMap<i32, Value>,
    sounds: [i32; 4],
}

impl Mooshroom {
    pub fn new(facts: &MobFacts) -> Result<Mooshroom, String> {
        let mut flowers = HashMap::new();
        for (name, effects) in &facts.animal.stew_flowers {
            let Some(id) = super::item(facts, name) else {
                continue;
            };
            let list = effects
                .iter()
                .map(|(effect, duration)| {
                    let name = facts.effects.name(*effect as u32).unwrap_or_default();
                    Value::Tuple(vec![
                        Value::Binary(name.as_bytes().to_vec()),
                        Value::Int(*duration as i64),
                    ])
                })
                .collect();
            flowers.insert(id, Value::List(list));
        }
        let sound = |n: &str| facts.sounds.id(n).unwrap_or(0);
        Ok(Mooshroom {
            milk: Milk::new(facts),
            bowl: super::item(facts, "minecraft:bowl"),
            shears: super::item(facts, "minecraft:shears"),
            mushroom_stew: super::item(facts, "minecraft:mushroom_stew"),
            suspicious_stew: super::item(facts, "minecraft:suspicious_stew"),
            flowers,
            sounds: [
                sound("minecraft:entity.mooshroom.milk"),
                sound("minecraft:entity.mooshroom.suspicious_milk"),
                sound("minecraft:entity.mooshroom.eat"),
                sound("minecraft:entity.mooshroom.shear"),
            ],
        })
    }

    fn brown(data: &FamilyData) -> bool {
        data.get("type").and_then(Value::as_binary) == Some(b"brown")
    }

    // `MushroomCow.shear`: the shear sound, a cow in its place, and its
    // shearing table's mushrooms one by one at its top.
    fn shear(&self, i: &mut Interaction) -> Outcome {
        let props = self.properties(&i.mob.body.data);
        let stacks = (i.loot)("minecraft:shearing/mooshroom", &props);
        let Some(ty) = Type::of(i.rules.facts, &i.mob.body.entity_type) else {
            return Outcome::Pass;
        };
        let [_, height, _] = living_body::dimensions(i.rules, ty, &i.mob.body);
        let mut drops = Vec::new();
        for stack in stacks {
            for _ in 0..items::count(&stack) {
                drops.push(Drop {
                    stack: items::with_count(&stack, 1),
                    offset: [0.0, height, 0.0],
                    add: None,
                });
            }
        }
        let convert = Type::of(i.rules.facts, "minecraft:cow").map(|cow| {
            Box::new(super::convert(
                &i.mob.body,
                living_body::fresh(i.rules, cow),
            ))
        });
        Outcome::Done(Done {
            hand: Some(Hand::Wear(1)),
            events: vec![InteractEvent::Sound {
                sound: self.sounds[3],
                source: "player",
                volume: 1.0,
                pitch: 1.0,
            }],
            drops,
            convert,
            ..Done::default()
        })
    }
}

impl Species for Mooshroom {
    const TYPE: &'static str = "minecraft:mooshroom";
    const MODULE: &'static str = "Valimc.Entity.Animals.Mooshroom";

    fn goals(&self, a: &Animal<Self>, _facts: &MobFacts) -> Registered {
        cow::goals(a.type_id)
    }

    fn defaults(&self) -> Vec<(Atom, Value)> {
        vec![
            (Atom::from_static("type"), Value::Binary(b"red".to_vec())),
            (Atom::from_static("stew"), NIL),
        ]
    }

    fn fields(&self, _a: &Animal<Self>, data: &FamilyData) -> Vec<(Atom, Value, Value)> {
        vec![(
            Atom::from_static("mooshroom_type"),
            Value::Int(if Mooshroom::brown(data) { 1 } else { 0 }),
            Value::Int(0),
        )]
    }

    fn properties(&self, data: &FamilyData) -> Vec<(String, String)> {
        let kind = data
            .get("type")
            .and_then(Value::as_binary)
            .map(|b| String::from_utf8_lossy(b).into_owned())
            .unwrap_or_default();
        vec![("minecraft:mooshroom/variant".into(), kind)]
    }

    fn offspring(
        &self,
        _a: &Animal<Self>,
        t: &mut Turn,
        partner: &FamilyData,
    ) -> Vec<(Atom, Value)> {
        let mine = t.data().get("type").cloned().unwrap_or(NIL);
        let theirs = partner.get("type").cloned().unwrap_or(NIL);
        let flip = mine == theirs && t.int(1024) == 0;
        let kind = if flip {
            let brown = mine.as_binary() == Some(b"brown");
            Value::Binary(if brown {
                b"red".to_vec()
            } else {
                b"brown".to_vec()
            })
        } else if t.boolean() {
            mine
        } else {
            theirs
        };
        vec![(Atom::from_static("type"), kind)]
    }

    /// `MushroomCow.mobInteract`: an adult fills a bowl with stew (a brown
    /// one's suspicious stew while it holds a flower's effects), shears turn
    /// it into a cow dropping its mushrooms, a brown adult eats a flower
    /// for its stew's effects (one at a time); else a cow's milking.
    fn interact(&self, _a: &Animal<Self>, i: &mut Interaction) -> Outcome {
        let Some(id) = i.request.item_id() else {
            return Outcome::Pass;
        };
        let adult = age(&i.mob.body.data) >= 0;
        if Some(id) == self.bowl && adult {
            let stew = i.mob.body.data.get("stew").cloned().unwrap_or(NIL);
            let (stack, sound) = if stew.is_nil() {
                (
                    self.mushroom_stew
                        .map(|s| items::new_stack(s, 1, None))
                        .unwrap_or(NIL),
                    self.sounds[0],
                )
            } else {
                let mut components = Map::new();
                components.insert(
                    Value::Binary(b"minecraft:suspicious_stew_effects".to_vec()),
                    stew,
                );
                (
                    self.suspicious_stew
                        .map(|s| items::new_stack(s, 1, Some(Value::Map(components))))
                        .unwrap_or(NIL),
                    self.sounds[1],
                )
            };
            i.mob.body.data.set("stew", NIL);
            Outcome::Done(Done {
                hand: Some(Hand::Fill(stack)),
                events: vec![InteractEvent::Sound {
                    sound,
                    source: "neutral",
                    volume: 1.0,
                    pitch: 1.0,
                }],
                ..Done::default()
            })
        } else if Some(id) == self.shears && adult {
            self.shear(i)
        } else if Mooshroom::brown(&i.mob.body.data) && adult && self.flowers.contains_key(&id) {
            if !i.mob.body.data.get("stew").is_none_or(Value::is_nil) {
                return Outcome::Done(Done::default());
            }
            i.mob.body.data.set("stew", self.flowers[&id].clone());
            Outcome::Done(Done {
                hand: Some(Hand::Use(1)),
                events: vec![InteractEvent::Sound {
                    sound: self.sounds[2],
                    source: "neutral",
                    volume: 2.0,
                    pitch: 1.0,
                }],
                ..Done::default()
            })
        } else {
            self.milk.milk(i)
        }
    }
}
