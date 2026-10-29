//! A pig (`Valimc.Entity.Animals.Pig`): its goals (a carrot on a stick
//! tempts it too), its temperature and sound variants (`variants`, a baby's
//! own sounds) and its eating sound. Saddles and riding are VMC-046's.

use super::{variants, Animal, Species};
use crate::mobs::ai::goal::{JUMP, LOOK, MOVE};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::{
    Breed, Float, FollowParent, ItemTest, LookAtPlayer, Panic, RandomLookAround, RandomStroll,
    Tempt,
};
use crate::mobs::ai::turn::Turn;
use crate::mobs::combat::{SoundKind, SoundRef};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Registered, Registration};
use crate::mobs::model::{Body, FamilyData};
use crate::mobs::term::{Atom, Value};

pub struct Pig {
    variants: variants::Variants,
    carrot_on_a_stick: i32,
}

impl Pig {
    pub fn new(facts: &MobFacts) -> Result<Pig, String> {
        Ok(Pig {
            variants: variants::Variants::new(facts, "pig")?,
            carrot_on_a_stick: super::item(facts, "minecraft:carrot_on_a_stick")
                .ok_or("no carrot on a stick")?,
        })
    }
}

impl Species for Pig {
    const TYPE: &'static str = "minecraft:pig";
    const MODULE: &'static str = "Valimc.Entity.Animals.Pig";

    fn goals(&self, a: &Animal<Self>, _facts: &MobFacts) -> Registered {
        Registered {
            goals: vec![
                Registration::new(0, "FloatGoal", JUMP, Float::new()),
                Registration::new(1, "PanicGoal", MOVE, Panic::new(1.25, None)),
                Registration::new(3, "BreedGoal", MOVE | LOOK, Breed::new(1.0, None, None)),
                Registration::new(
                    4,
                    "TemptGoal",
                    MOVE | LOOK,
                    Tempt::new(1.2, ItemTest::One(self.carrot_on_a_stick), false, 2.5),
                ),
                Registration::new(
                    4,
                    "TemptGoal",
                    MOVE | LOOK,
                    Tempt::new(1.2, ItemTest::Food(a.type_id), false, 2.5),
                ),
                Registration::new(5, "FollowParentGoal", 0, FollowParent::new(1.1)),
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
        variants::data()
    }

    fn fields(&self, _a: &Animal<Self>, data: &FamilyData) -> Vec<(Atom, Value, Value)> {
        self.variants.values(data)
    }

    fn offspring(
        &self,
        _a: &Animal<Self>,
        t: &mut Turn,
        partner: &FamilyData,
    ) -> Vec<(Atom, Value)> {
        variants::offspring(t, partner)
    }

    fn spawn_part(&self, _a: &Animal<Self>, t: &mut Turn, _reason: &Atom) {
        variants::finalize(t, "pig");
    }

    fn properties(&self, data: &FamilyData) -> Vec<(String, String)> {
        variants::properties("pig", data)
    }

    fn ambient_sound(&self, _a: &Animal<Self>, t: &mut Turn) -> Option<Option<i32>> {
        Some(self.variants.sound(t.data(), "ambient"))
    }

    fn sound(&self, _a: &Animal<Self>, body: &Body, which: SoundKind) -> Option<SoundRef> {
        self.variants.combat_sound(body, which)
    }

    fn eat_sound(&self, data: &FamilyData) -> Option<i32> {
        self.variants.sound(data, "eat")
    }
}
