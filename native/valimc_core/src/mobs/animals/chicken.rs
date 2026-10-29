//! A chicken (`Valimc.Entity.Animals.Chicken`): its goals, its temperature
//! and sound variants (`variants`, a chick's own sounds), its slow fall
//! (falling, it keeps 0.6 of its downward speed each tick), whether it is a
//! jockey's (`IsChickenJockey`) and the ticks before it lays (`EggLayTime`,
//! 6,000 to 11,999).

use super::{age, variants, Animal, Species};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::f;
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

pub struct Chicken {
    variants: variants::Variants,
    egg_sound: Option<i32>,
}

impl Chicken {
    pub fn new(facts: &MobFacts) -> Result<Chicken, String> {
        Ok(Chicken {
            variants: variants::Variants::new(facts, "chicken")?,
            egg_sound: facts.sounds.id("minecraft:entity.chicken.egg"),
        })
    }

    // `Chicken.aiStep` after the move: a falling chicken slows.
    fn slow_fall(t: &mut Turn) {
        let v = &mut t.mob.body.velocity;
        if !t.mob.body.on_ground && v[1] < 0.0 {
            v[1] *= 0.6;
        }
    }

    // `dropFromGiftLootTable(CHICKEN_LAY)` (the owner drops the variant's
    // egg, launched by the level's random), the egg sound and the next
    // egg's time, for a hen that is no jockey's.
    fn lay(&self, t: &mut Turn) {
        let data = t.data();
        let jockey = data.get("jockey").and_then(Value::as_bool).unwrap_or(false);
        if jockey || age(data) < 0 {
            return;
        }
        let egg_time = data.get("egg_time").and_then(Value::as_int).unwrap_or(0);
        if egg_time - 1 <= 0 {
            let a = t.level.random.double();
            let b = t.level.random.double();
            t.effect(Effect::Lay([a * 0.2 - 0.1, 0.2, b * 0.2 - 0.1]));
            let x = t.float();
            let y = t.float();
            let pitch = f(f(f(x - y) * f(0.2)) + 1.0);
            if let Some(id) = self.egg_sound {
                t.sound_id(id, 1.0, pitch);
            }
            let n = t.int(6000) as i64;
            t.mob.body.data.set("egg_time", Value::Int(n + 6000));
        } else {
            t.mob.body.data.set("egg_time", Value::Int(egg_time - 1));
        }
    }
}

impl Species for Chicken {
    const TYPE: &'static str = "minecraft:chicken";
    const MODULE: &'static str = "Valimc.Entity.Animals.Chicken";

    fn goals(&self, a: &Animal<Self>, _facts: &MobFacts) -> Registered {
        Registered {
            goals: vec![
                Registration::new(0, "FloatGoal", JUMP, Float::new()),
                Registration::new(1, "PanicGoal", MOVE, Panic::new(1.4, None)),
                Registration::new(2, "BreedGoal", MOVE | LOOK, Breed::new(1.0, None, None)),
                Registration::new(
                    3,
                    "TemptGoal",
                    MOVE | LOOK,
                    Tempt::new(1.0, ItemTest::Food(a.type_id), false, 2.5),
                ),
                Registration::new(4, "FollowParentGoal", 0, FollowParent::new(1.1)),
                Registration::new(
                    5,
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
                    6,
                    "LookAtPlayerGoal",
                    LOOK,
                    LookAtPlayer::new(6.0, 0.02, false, None),
                ),
                Registration::new(
                    7,
                    "RandomLookAroundGoal",
                    MOVE | LOOK,
                    RandomLookAround::new(),
                ),
            ],
            targets: Vec::new(),
        }
    }

    // The constructor's `random.nextInt(6000) + 6000` comes from a random
    // vanilla never seeds (the Elixir's `:rand`); a fresh native body takes
    // the first value.
    fn defaults(&self) -> Vec<(Atom, Value)> {
        let mut data = variants::data();
        data.push((Atom::from_static("egg_time"), Value::Int(6000)));
        data.push((Atom::from_static("jockey"), Value::bool(false)));
        data
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
        variants::finalize(t, "chicken");
    }

    fn properties(&self, data: &FamilyData) -> Vec<(String, String)> {
        variants::properties("chicken", data)
    }

    fn ambient_sound(&self, _a: &Animal<Self>, t: &mut Turn) -> Option<Option<i32>> {
        Some(self.variants.sound(t.data(), "ambient"))
    }

    fn sound(&self, _a: &Animal<Self>, body: &Body, which: SoundKind) -> Option<SoundRef> {
        self.variants.combat_sound(body, which)
    }

    fn settle(&self, _a: &Animal<Self>, t: &mut Turn) {
        Chicken::slow_fall(t);
        self.lay(t);
    }
}
