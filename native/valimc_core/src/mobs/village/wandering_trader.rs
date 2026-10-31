//! Wandering traders (`Valimc.AI.Mobs.WanderingTrader`, vanilla's
//! `WanderingTrader`): it drinks a potion of invisibility when it is dark
//! and it is not invisible, and milk when it is bright and it is
//! (`UseItemGoal` with their sounds; the drink itself is `ai::consume`'s),
//! flees zombies and illagers, panics when hurt, walks to its wander target
//! and back toward its home, strolls and looks at players and mobs. Its
//! despawn delay counts down and it goes when it runs out. It offers no
//! trades yet (VMC-044), so its trading goals never start.
//!
//! Its own data: the despawn delay, the wander target, whether it shows as
//! invisible (`isInvisible`, which vanilla updates as its data syncs after
//! the tick), its unhappy counter and age. Its home is its mob's.

use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::f;
use crate::mobs::ai::goal::{Goal, JUMP, LOOK, MOVE};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::{
    AvoidEntity, EntityTest, Float, Idle, LookAtPlayer, MobTypes, MoveTowardsRestriction, Panic,
    RandomStroll, UseItem,
};
use crate::mobs::ai::hooks::{Hooks, Tag};
use crate::mobs::ai::navigation;
use crate::mobs::ai::turn::Turn;
use crate::mobs::combat::Family;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, Registered, Registration};
use crate::mobs::living::items;
use crate::mobs::model::{Body, FamilyData};
use crate::mobs::monsters::{entity, fields, flag, int, item, value};
use crate::mobs::term::{Atom, Map, Value, NIL};

pub const WANDERING_TRADER: &str = "minecraft:wandering_trader";

const DARK_SEEN: Tag = 1;
const BRIGHT_UNSEEN: Tag = 2;

/// The wandering trader family.
pub struct WanderingTrader {
    types: [&'static str; 1],
    /// Each fled group's types and distance.
    flees: Vec<(Vec<u16>, f64)>,
    potion: Value,
    milk: Value,
    milk_id: i32,
    invisibility: i32,
    drink_milk: i32,
    drink_potion: i32,
}

impl WanderingTrader {
    pub fn new(facts: &MobFacts) -> Result<WanderingTrader, String> {
        let types = |names: &[&str]| -> Result<Vec<u16>, String> {
            names.iter().map(|n| entity(facts, n)).collect()
        };
        // `Zombie.class` (husks, drowned, zombie villagers and zombified
        // piglins are zombies) and the illagers and zoglins it flees.
        let flees = vec![
            (
                types(&[
                    "minecraft:zombie",
                    "minecraft:husk",
                    "minecraft:drowned",
                    "minecraft:zombie_villager",
                    "minecraft:zombified_piglin",
                ])?,
                8.0,
            ),
            (types(&["minecraft:evoker"])?, 12.0),
            (types(&["minecraft:vindicator"])?, 8.0),
            (types(&["minecraft:vex"])?, 8.0),
            (types(&["minecraft:pillager"])?, 15.0),
            (types(&["minecraft:illusioner"])?, 12.0),
            (types(&["minecraft:zoglin"])?, 10.0),
        ];
        let invisible = facts
            .potion("minecraft:invisibility")
            .ok_or("no invisibility potion")?;
        let contents = Value::Map(Map::from_atoms([
            ("potion", Value::Int(invisible as i64)),
            ("color", NIL),
            ("effects", Value::List(Vec::new())),
            ("name", NIL),
        ]));
        let components = Map::from_pairs(vec![(
            Value::Binary(b"minecraft:potion_contents".to_vec()),
            contents,
        )])
        .ok_or("bad potion components")?;
        let milk_id = item(facts, "minecraft:milk_bucket")?;
        let sound = |name: &str| crate::mobs::monsters::sound(facts, name);
        Ok(WanderingTrader {
            types: [WANDERING_TRADER],
            flees,
            potion: items::new_stack(
                item(facts, "minecraft:potion")?,
                1,
                Some(Value::Map(components)),
            ),
            milk: items::new_stack(milk_id, 1, None),
            milk_id,
            invisibility: crate::mobs::monsters::effect(facts, "minecraft:invisibility")?,
            drink_milk: sound("minecraft:entity.wandering_trader.drink_milk")?,
            drink_potion: sound("minecraft:entity.wandering_trader.drink_potion")?,
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[
            ("despawn_delay", Value::Int(0)),
            ("wander_target", NIL),
            ("invisible", Value::bool(false)),
            ("unhappy", Value::Int(0)),
            ("age", Value::Int(0)),
            // `MerchantOffers`, made when first asked (VMC-044b1).
            ("offers", NIL),
        ])
    }
}

impl Hooks for WanderingTrader {
    /// `isDarkOutside` and not invisible; `isBrightOutside` and invisible.
    fn test(&self, t: &mut Turn, tag: Tag) -> bool {
        let invisible = flag(t.data(), "invisible");
        match tag {
            DARK_SEEN => !t.level.bright && !t.level.fixed_time && !invisible,
            BRIGHT_UNSEEN => t.level.bright && invisible,
            _ => false,
        }
    }
}

impl Family for WanderingTrader {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(WanderingTrader::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let data = &body.data;
        vec![
            value(
                "ageable_baby",
                Value::bool(int(data, "age") < 0),
                Value::bool(false),
            ),
            value(
                "villager_unhappy",
                Value::Int(int(data, "unhappy")),
                Value::Int(0),
            ),
        ]
    }
}

impl Kind for WanderingTrader {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.WanderingTrader"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        let mut goals = vec![
            Registration::new(0, "FloatGoal", JUMP, Float::new()),
            Registration::new(
                0,
                "UseItemGoal",
                0,
                UseItem::new(
                    self.potion.clone(),
                    Some("minecraft:entity.wandering_trader.disappeared"),
                    DARK_SEEN,
                ),
            ),
            Registration::new(
                0,
                "UseItemGoal",
                0,
                UseItem::new(
                    self.milk.clone(),
                    Some("minecraft:entity.wandering_trader.reappeared"),
                    BRIGHT_UNSEEN,
                ),
            ),
            Registration::new(
                1,
                "TradeWithPlayerGoal",
                MOVE | JUMP,
                Idle::new("TradeWithPlayerGoal"),
            ),
        ];
        for (types, distance) in &self.flees {
            goals.push(Registration::new(
                1,
                "AvoidEntityGoal",
                MOVE,
                AvoidEntity::new(EntityTest::Mobs(types.clone()), *distance, 0.5, 0.5),
            ));
        }
        goals.extend([
            Registration::new(1, "PanicGoal", MOVE, Panic::new(0.5, None)),
            Registration::new(
                1,
                "LookAtTradingPlayerGoal",
                LOOK,
                Idle::new("LookAtTradingPlayerGoal"),
            ),
            Registration::new(
                2,
                "WanderToPositionGoal",
                MOVE,
                WanderToPosition {
                    stop: 2.0,
                    speed: 0.35,
                },
            ),
            Registration::new(
                4,
                "MoveTowardsRestrictionGoal",
                MOVE,
                MoveTowardsRestriction::new(0.35),
            ),
            Registration::new(
                8,
                "WaterAvoidingRandomStrollGoal",
                MOVE,
                RandomStroll::new(
                    0.35,
                    StrollOptions {
                        water_avoiding: true,
                        ..StrollOptions::default()
                    },
                ),
            ),
            Registration::new(
                9,
                "InteractGoal",
                MOVE | LOOK,
                LookAtPlayer::new(3.0, f(1.0), false, None),
            ),
            Registration::new(
                10,
                "LookAtPlayerGoal",
                LOOK,
                LookAtPlayer::new(8.0, 0.02, false, Some(MobTypes::Any)),
            ),
        ]);
        Registered {
            goals,
            targets: Vec::new(),
        }
    }

    /// `getConsumeSound`: its own drinking sounds.
    fn consume_sound(&self, item: i32) -> Option<i32> {
        Some(if item == self.milk_id {
            self.drink_milk
        } else {
            self.drink_potion
        })
    }

    /// `WanderingTrader.aiStep` after its super (`maybeDespawn`): its
    /// despawn delay counts down, and it goes as it reaches 0.
    fn after_ai(&self, t: &mut Turn) {
        let delay = int(t.data(), "despawn_delay");
        if delay > 0 {
            t.mob.body.data.set("despawn_delay", Value::Int(delay - 1));
            if delay - 1 == 0 {
                t.effect(Effect::Discard);
            }
        }
    }

    /// `updateInvisibilityStatus` as its data syncs after the tick.
    fn after_tick(&self, t: &mut Turn) {
        let invisible = t
            .mob
            .body
            .mob
            .living
            .effects
            .get(self.invisibility)
            .is_some();
        t.mob.body.data.set("invisible", Value::bool(invisible));
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        WanderingTrader::data_of()
    }
}

/// `WanderingTrader.WanderToPositionGoal` (`WanderingTrader.
/// WanderToPosition`): while its wander target is farther than `stop` from
/// it, each time its navigation is done it walks to it, or ten blocks its
/// way while it is more than ten away; stopping forgets the target.
#[derive(Clone, Debug, PartialEq)]
pub struct WanderToPosition {
    stop: f64,
    speed: f64,
}

fn wander_target(t: &Turn) -> Option<[i32; 3]> {
    let [x, y, z] = t.data().get("wander_target")?.as_ivec3()?;
    Some([x as i32, y as i32, z as i32])
}

// `!pos.closerToCenterThan(position, distance)`.
fn far(t: &Turn, [x, y, z]: [i32; 3], distance: f64) -> bool {
    let d = [
        x as f64 + 0.5 - t.x(),
        y as f64 + 0.5 - t.y(),
        z as f64 + 0.5 - t.z(),
    ];
    d[0] * d[0] + d[1] * d[1] + d[2] * d[2] >= distance * distance
}

impl Goal for WanderToPosition {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        wander_target(t).is_some_and(|target| far(t, target, self.stop))
    }

    fn stop(&mut self, t: &mut Turn) {
        t.mob.body.data.set("wander_target", NIL);
        navigation::stop(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        let Some(target) = wander_target(t) else {
            return;
        };
        if !t.mind.navigation.done() {
            return;
        }
        let [tx, ty, tz] = target.map(f64::from);
        let to = if far(t, target, 10.0) {
            let d = [tx - t.x(), ty - t.y(), tz - t.z()];
            let length = (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).sqrt();
            let d = if length < 1.0e-5 {
                [0.0; 3]
            } else {
                d.map(|v| v / length)
            };
            [
                d[0] * 10.0 + t.x(),
                d[1] * 10.0 + t.y(),
                d[2] * 10.0 + t.z(),
            ]
        } else {
            [tx, ty, tz]
        };
        navigation::move_to(t, to, self.speed);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.WanderingTrader.WanderToPosition"
    }
}
