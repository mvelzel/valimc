//! A sheep (`Valimc.Entity.Animals.Sheep`): its goals (grazing,
//! `EatBlockGoal`), its wool's colour and whether it is sheared
//! (`DATA_WOOL_ID`: the colour in the low four bits, sheared bit 4). Eating
//! grass grows its wool back and a lamb older (`ate`). A lamb's colour is
//! its parents' crafted mix, else either's, drawn from the level's random.
//! Shearing and dyeing are its interactions.

use super::{age, age_up, can_age_up, Animal, Species};
use crate::mobs::ai::fmath::f;
use crate::mobs::ai::goal::{JUMP, LOOK, MOVE};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::{
    Breed, EatBlock, Float, FollowParent, ItemTest, LookAtPlayer, Panic, RandomLookAround,
    RandomStroll, Tempt,
};
use crate::mobs::ai::spawn;
use crate::mobs::ai::turn::Turn;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::interact::{
    At, Done, Drop, Hand, InteractEvent, Interaction, Other, Outcome,
};
use crate::mobs::kinds::{Registered, Registration};
use crate::mobs::living::items;
use crate::mobs::model::FamilyData;
use crate::mobs::term::{Atom, Value};
use std::collections::HashMap;

/// The dye colours by id (`DyeColor`).
pub const COLORS: [&str; 16] = [
    "white",
    "orange",
    "magenta",
    "light_blue",
    "yellow",
    "lime",
    "pink",
    "gray",
    "light_gray",
    "cyan",
    "purple",
    "blue",
    "brown",
    "green",
    "red",
    "black",
];

fn color(name: &str) -> i64 {
    COLORS.iter().position(|c| *c == name).unwrap_or(0) as i64
}

/// `SheepColorSpawnRules`: a climate's weighted colours (100 in all) and its
/// common one (a weighted 499 to a pink 1).
const TEMPERATE: ([(&str, i32); 4], &str) = (
    [("black", 5), ("gray", 5), ("light_gray", 5), ("brown", 3)],
    "white",
);
const WARM: ([(&str, i32); 4], &str) = (
    [("gray", 5), ("light_gray", 5), ("white", 5), ("black", 3)],
    "brown",
);
const COLD: ([(&str, i32); 4], &str) = (
    [("light_gray", 5), ("gray", 5), ("white", 5), ("brown", 3)],
    "black",
);

pub struct Sheep {
    shears: Option<i32>,
    /// Dye item id => colour.
    dyes: HashMap<i32, i64>,
    mixes: HashMap<(i32, i32), i32>,
    shear_sound: i32,
    dye_sound: i32,
}

impl Sheep {
    pub fn new(facts: &MobFacts) -> Result<Sheep, String> {
        if facts.animal.sheep_mixes.is_empty() {
            return Err("no sheep colour mixes in the animal facts".into());
        }
        let dyes = COLORS
            .iter()
            .enumerate()
            .filter_map(|(i, c)| {
                Some((super::item(facts, &format!("minecraft:{c}_dye"))?, i as i64))
            })
            .collect();
        Ok(Sheep {
            shears: super::item(facts, "minecraft:shears"),
            dyes,
            mixes: facts.animal.sheep_mixes.clone(),
            shear_sound: facts.sounds.id("minecraft:entity.sheep.shear").unwrap_or(0),
            dye_sound: facts.sounds.id("minecraft:item.dye.use").unwrap_or(0),
        })
    }

    fn color(data: &FamilyData) -> i64 {
        data.get("color").and_then(Value::as_int).unwrap_or(0)
    }

    fn sheared(data: &FamilyData) -> bool {
        data.get("sheared")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    }

    /// `DATA_WOOL_ID`.
    pub fn wool(data: &FamilyData) -> i64 {
        (if Sheep::sheared(data) { 16 } else { 0 }) | Sheep::color(data)
    }

    // The sheep's shearing: one to three of its wool, each launched a
    // little from its random, and the arm swings.
    fn shear(&self, i: &mut Interaction) -> Outcome {
        let props = self.properties(&i.mob.body.data);
        let stacks = (i.loot)("minecraft:shearing/sheep", &props);
        let mut drops = Vec::new();
        for stack in stacks {
            for _ in 0..items::count(&stack) {
                let dx = i.spread(0.1);
                let roll = i.random().float() as f64;
                let dy = f(roll * f(0.05));
                let dz = i.spread(0.1);
                drops.push(Drop {
                    stack: items::with_count(&stack, 1),
                    offset: [0.0, 1.0, 0.0],
                    add: Some([dx, dy, dz]),
                });
            }
        }
        i.mob.body.data.set("sheared", Value::bool(true));
        Outcome::Done(Done {
            hand: Some(Hand::Wear(1)),
            swing: true,
            events: vec![InteractEvent::Sound {
                sound: self.shear_sound,
                source: "player",
                volume: 1.0,
                pitch: 1.0,
            }],
            drops,
            ..Done::default()
        })
    }
}

impl Species for Sheep {
    const TYPE: &'static str = "minecraft:sheep";
    const MODULE: &'static str = "Valimc.Entity.Animals.Sheep";

    fn goals(&self, a: &Animal<Self>, _facts: &MobFacts) -> Registered {
        Registered {
            goals: vec![
                Registration::new(0, "FloatGoal", JUMP, Float::new()),
                Registration::new(1, "PanicGoal", MOVE, Panic::new(1.25, None)),
                Registration::new(2, "BreedGoal", MOVE | LOOK, Breed::new(1.0, None, None)),
                Registration::new(
                    3,
                    "TemptGoal",
                    MOVE | LOOK,
                    Tempt::new(1.1, ItemTest::Food(a.type_id), false, 2.5),
                ),
                Registration::new(4, "FollowParentGoal", 0, FollowParent::new(1.1)),
                Registration::new(5, "EatBlockGoal", MOVE | LOOK | JUMP, EatBlock::new()),
                Registration::new(
                    6,
                    "WaterAvoidingRandomStrollGoal",
                    MOVE,
                    RandomStroll::new(
                        1.0,
                        StrollOptions {
                            water_avoiding: true,
                            ..StrollOptions::default()
                        },
                    ),
                ),
                Registration::new(
                    7,
                    "LookAtPlayerGoal",
                    LOOK,
                    LookAtPlayer::new(6.0, 0.02, false, None),
                ),
                Registration::new(
                    8,
                    "RandomLookAroundGoal",
                    MOVE | LOOK,
                    RandomLookAround::new(),
                ),
            ],
            targets: Vec::new(),
        }
    }

    fn defaults(&self) -> Vec<(Atom, Value)> {
        vec![
            (Atom::from_static("color"), Value::Int(0)),
            (Atom::from_static("sheared"), Value::bool(false)),
        ]
    }

    fn fields(&self, _a: &Animal<Self>, data: &FamilyData) -> Vec<(Atom, Value, Value)> {
        vec![(
            Atom::from_static("sheep_wool"),
            Value::Int(Sheep::wool(data)),
            Value::Int(0),
        )]
    }

    fn properties(&self, data: &FamilyData) -> Vec<(String, String)> {
        let c = Sheep::color(data).clamp(0, 15) as usize;
        vec![
            ("minecraft:sheep/color".into(), COLORS[c].into()),
            ("sheep/sheared".into(), Sheep::sheared(data).to_string()),
        ]
    }

    /// A lamb's colour: its parents' crafted mix, else either's from the
    /// level's random.
    fn offspring(
        &self,
        _a: &Animal<Self>,
        t: &mut Turn,
        partner: &FamilyData,
    ) -> Vec<(Atom, Value)> {
        let (a, b) = (Sheep::color(t.data()), Sheep::color(partner));
        let color = match self.mixes.get(&(a as i32, b as i32)) {
            Some(&mixed) => mixed as i64,
            None => {
                if spawn::level_boolean(t) {
                    a
                } else {
                    b
                }
            }
        };
        vec![(Atom::from_static("color"), Value::Int(color))]
    }

    /// `finalizeSpawn`'s colour (`getRandomSheepColor`): the biome's
    /// climate's weighted colours, from the level's random.
    fn spawn_part(&self, _a: &Animal<Self>, t: &mut Turn, _reason: &Atom) {
        let facts = t.level.facts;
        let biome = Some(t.level.biome(t.block()));
        let (singles, common) =
            if facts.biome_in(biome, "minecraft:spawns_warm_variant_farm_animals") {
                WARM
            } else if facts.biome_in(biome, "minecraft:spawns_cold_variant_farm_animals") {
                COLD
            } else {
                TEMPERATE
            };
        let mut n = spawn::level_int(t, 100);
        let mut picked = None;
        for (c, weight) in singles {
            if n < weight {
                picked = Some(c);
                break;
            }
            n -= weight;
        }
        let name = match picked {
            Some(c) => c,
            None => {
                if spawn::level_int(t, 500) < 499 {
                    common
                } else {
                    "pink"
                }
            }
        };
        t.mob.body.data.set("color", Value::Int(color(name)));
    }

    /// `Sheep.ate`: its wool grows back, a lamb grows a minute older.
    fn ate(&self, _a: &Animal<Self>, t: &mut Turn) {
        let data = &mut t.mob.body.data;
        data.set("sheared", Value::bool(false));
        if can_age_up(data) {
            age_up(data, 60, false, 0);
        }
    }

    /// `Sheep.mobInteract`: shears shear an adult with its wool; on a sheep
    /// not ready they do nothing more.
    fn interact(&self, _a: &Animal<Self>, i: &mut Interaction) -> Outcome {
        if i.request.item_id().is_none() || i.request.item_id() != self.shears {
            return Outcome::Pass;
        }
        let data = &i.mob.body.data;
        if Sheep::sheared(data) || age(data) < 0 {
            Outcome::Consume
        } else {
            self.shear(i)
        }
    }

    /// `DyeItem.interactLivingEntity`: a dye of another colour dyes a sheep
    /// that is not sheared; the others hear it at the sheep.
    fn use_item(&self, _a: &Animal<Self>, i: &mut Interaction) -> Outcome {
        let Some(&dye) = i.request.item_id().and_then(|id| self.dyes.get(&id)) else {
            return Outcome::Pass;
        };
        let data = &i.mob.body.data;
        if dye == Sheep::color(data) || Sheep::sheared(data) {
            return Outcome::Pass;
        }
        i.mob.body.data.set("color", Value::Int(dye));
        Outcome::Done(Done {
            hand: Some(Hand::Use(1)),
            others: Some(Other {
                sound: self.dye_sound,
                source: "player",
                volume: 1.0,
                pitch: 1.0,
                at: At::Animal,
            }),
            ..Done::default()
        })
    }
}
