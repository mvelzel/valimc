//! What a native mob's owner is given of it (VMC-081d): the store keeps a
//! routing entry and a row of what its readers read (`NativeBody`), and the
//! tick hands back only what changed. A mob's state splits into its
//! physical part (`Physical`: position, rotations, motion and ground, which
//! the owner mirrors into the entry and its view whenever it changes), its
//! row's other fields (`RowKey`, which the owner is given again only when
//! one of them changes), what observers are shown (`Shown`, kept on the
//! slot) and its record (the section's cut).

use super::combat::Rules;
use super::living::body as living_body;
use super::living::mob::{self as living_mob, Type};
use super::model::{FamilyData, LeashHolder, NativeMob};
use super::sensing::Ref;
use super::term::Value;

/// A mob's physical state: what the owner's entry and view mirror.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Physical {
    pub position: [f64; 3],
    pub yaw: f64,
    pub pitch: f64,
    pub head_yaw: f64,
    pub velocity: [f64; 3],
    pub on_ground: bool,
}

impl Physical {
    pub fn of(mob: &NativeMob) -> Physical {
        let b = &mob.body;
        Physical {
            position: mob.position,
            yaw: b.yaw,
            pitch: b.pitch,
            head_yaw: b.head_yaw,
            velocity: b.velocity,
            on_ground: b.on_ground,
        }
    }

    /// Equal as Elixir's `==` compares the floats the owner holds (`0.0 ==
    /// -0.0`), so a turn that changed nothing reports nothing.
    pub fn same(&self, other: &Physical) -> bool {
        let eq = |a: f64, b: f64| a == b;
        self.position
            .iter()
            .zip(other.position)
            .all(|(&a, b)| eq(a, b))
            && eq(self.yaw, other.yaw)
            && eq(self.pitch, other.pitch)
            && eq(self.head_yaw, other.head_yaw)
            && self
                .velocity
                .iter()
                .zip(other.velocity)
                .all(|(&a, b)| eq(a, b))
            && self.on_ground == other.on_ground
    }
}

/// The attributes a row carries: knockback resistance, step height,
/// gravity (their values) and explosion knockback resistance (its base).
pub const ROW_ATTRIBUTES: [&str; 3] = [
    "minecraft:knockback_resistance",
    "minecraft:step_height",
    "minecraft:gravity",
];

/// A row's fields beside the physical ones, what is shown and the idle
/// time (which its owner reads from the section when it needs it).
#[derive(Clone, Debug, PartialEq)]
pub struct RowKey {
    pub alive: bool,
    pub dimensions: [f64; 3],
    pub custom_name: Option<Value>,
    pub portal_cooldown: i32,
    pub persistent: bool,
    pub from_bucket: bool,
    pub in_water: bool,
    pub killed_by: Option<[u8; 16]>,
    pub recent: bool,
    pub data: FamilyData,
    pub target: Option<Ref>,
    /// `ROW_ATTRIBUTES`' values, then the explosion knockback resistance.
    pub attributes: [f64; 4],
    pub death: bool,
    pub no_ai: bool,
    pub leash: Option<(LeashHolder, Option<i32>, bool)>,
}

/// Whether a mob's mind was hurt in the last two ticks (or is new): what
/// the row's `recent` says.
pub fn recent(mob: &NativeMob) -> bool {
    let mind = mob.body.mob.ai.as_ref();
    match (mind, mind.and_then(|m| m.state.as_ref())) {
        (None, _) => false,
        (Some(_), None) => true,
        (Some(_), Some(s)) => match s.hurt_by {
            Some((_, at)) => at >= s.tick - 2,
            None => s.tick <= 2,
        },
    }
}

fn target(mob: &NativeMob) -> Option<Ref> {
    mob.body
        .mob
        .ai
        .as_ref()
        .and_then(|m| m.state.as_ref())
        .and_then(|s| s.target)
}

fn from_bucket(data: &FamilyData) -> bool {
    data.get("from_bucket").and_then(Value::as_bool) == Some(true)
}

fn attributes(rules: &Rules, ty: Type, mob: &NativeMob) -> [f64; 4] {
    let value = |name: &str| {
        rules.facts.attributes.id(name).map_or(0.0, |id| {
            living_mob::value(rules.living, rules.facts, ty, &mob.body.mob, id)
        })
    };
    [
        value(ROW_ATTRIBUTES[0]),
        value(ROW_ATTRIBUTES[1]),
        value(ROW_ATTRIBUTES[2]),
        rules
            .facts
            .attributes
            .id("minecraft:explosion_knockback_resistance")
            .map_or(0.0, |id| {
                living_mob::base(rules.living, rules.facts, ty, &mob.body.mob.attributes, id)
            }),
    ]
}

fn leash(mob: &NativeMob) -> Option<(LeashHolder, Option<i32>, bool)> {
    mob.body
        .mob
        .leash
        .as_ref()
        .map(|l| (l.holder.clone(), l.id, l.restored))
}

impl RowKey {
    pub fn of(rules: &Rules, ty: Type, mob: &NativeMob) -> RowKey {
        let body = &mob.body;
        let m = &body.mob;
        RowKey {
            alive: living_mob::alive(m),
            dimensions: living_body::dimensions(rules, ty, body),
            custom_name: body.custom_name.clone(),
            portal_cooldown: body.portal_cooldown,
            persistent: m.persistent,
            from_bucket: from_bucket(&body.data),
            in_water: m.motion.water > 0.0,
            killed_by: m.hurt_by_player,
            recent: recent(mob),
            data: body.data.clone(),
            target: target(mob),
            attributes: attributes(rules, ty, mob),
            death: m.death.is_some(),
            no_ai: m.no_ai,
            leash: leash(mob),
        }
    }

    /// Whether `mob`'s row is still this one (without building it).
    pub fn matches(&self, rules: &Rules, ty: Type, mob: &NativeMob) -> bool {
        let body = &mob.body;
        let m = &body.mob;
        self.alive == living_mob::alive(m)
            && self.portal_cooldown == body.portal_cooldown
            && self.persistent == m.persistent
            && self.in_water == (m.motion.water > 0.0)
            && self.killed_by == m.hurt_by_player
            && self.death == m.death.is_some()
            && self.no_ai == m.no_ai
            && self.recent == recent(mob)
            && self.target == target(mob)
            && self.custom_name == body.custom_name
            && self.data == body.data
            && self.from_bucket == from_bucket(&body.data)
            && self.leash.as_ref().map(|(h, i, r)| (h, *i, *r))
                == m.leash.as_ref().map(|l| (&l.holder, l.id, l.restored))
            && self.dimensions == living_body::dimensions(rules, ty, body)
            && self.attributes == attributes(rules, ty, mob)
    }
}

/// Whether observers were last shown `shown` of the mob (`Body.shown/1`
/// unchanged), without cloning its equipment.
pub fn shows(rules: &Rules, ty: Type, mob: &NativeMob, shown: &living_body::Shown) -> bool {
    let body = &mob.body;
    shown.link == living_body::link(&body.mob)
        && shown.attributes == body.mob.attributes
        && shown.equipment == body.mob.equipment
        && shown.values == living_body::values(rules, ty, body)
}
