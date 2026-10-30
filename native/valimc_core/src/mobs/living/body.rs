//! `Valimc.Entity.Body`'s rules for a mob body: a fresh body, its timers
//! (the portal cooldown, hurt and death timers, the poof one tick before
//! removal), `/kill`, a push, a name tag, its entity data values (common,
//! living and mob fields, then its family's), dimensions, bounding box and
//! what observers are shown of it.

use super::super::combat::{self, Event, Rules};
use super::super::model::{Body, Equipment, Mob, NativeMob};
use super::super::term::{Atom, Value, NIL};
use super::mob::{self as living_mob, Synced, Type};
use super::{f, mob};

/// `Body.new/1` of a mob type: its family's data and a fresh mob.
pub fn fresh(rules: &Rules, ty: Type) -> Body {
    let family = rules.family(ty);
    Body {
        entity_type: ty.facts.name.clone(),
        yaw: 0.0,
        pitch: 0.0,
        head_yaw: 0.0,
        velocity: [0.0; 3],
        on_ground: false,
        no_gravity: false,
        data: family.data(ty.id),
        mob: mob::fresh(rules.living, rules.facts, ty, family),
        custom_name: None,
        preserved: None,
        portal_cooldown: 0,
    }
}

/// `Body.tick/1` of a mob: the portal cooldown and its mob's timers, the
/// poof (entity event 60) one tick before its removal; true once its death
/// animation ended.
pub fn tick(body: &mut Body, events: &mut Vec<Event>) -> bool {
    if body.portal_cooldown > 0 {
        body.portal_cooldown -= 1;
    }
    let done = living_mob::tick(&mut body.mob);
    let h = &body.mob.living.health;
    if h.value <= 0.0 && h.death_ticks == 19 {
        events.push(Event::Entity(60));
    }
    done
}

/// `Body.kill/1` then `Combat.died(body, %{})` (`Store.kill/2`): it dies as
/// any death does, with the hurt and death events; false for one already
/// dying.
pub fn kill(rules: &Rules, mob: &mut NativeMob, events: &mut Vec<Event>) -> bool {
    let Some(ty) = rules.of(&mob.body.entity_type) else {
        return false;
    };
    if !living_mob::kill(&mut mob.body.mob) {
        return false;
    }
    events.push(Event::Killed);
    events.push(Event::Entity(3));
    let uuid = mob.uuid;
    combat::died(rules, ty, rules.family(ty), &mut mob.body, &uuid, None);
    true
}

/// `Body.push/2` (`Entity.push`).
pub fn push(body: &mut Body, impulse: [f64; 3]) {
    for (v, d) in body.velocity.iter_mut().zip(impulse) {
        *v += d;
    }
}

/// `Body.name/2`: a name tag's name, and persistence.
pub fn name(body: &mut Body, name: Value) {
    body.custom_name = Some(name);
    body.mob.persistent = true;
}

/// `Body.dimensions/1`: `[width, height, eye height]` as floats.
pub fn dimensions(rules: &Rules, ty: Type, body: &Body) -> [f64; 3] {
    match rules.family(ty).dimensions(body) {
        Some(d) => [d[0] as f64, d[1] as f64, d[2] as f64],
        None => [
            f(ty.facts.width),
            f(ty.facts.height),
            f(ty.facts.eye_height),
        ],
    }
}

/// `Body.box/2`: `[x0, y0, z0, x1, y1, z1]` at `position`.
pub fn bounding_box(rules: &Rules, ty: Type, body: &Body, position: [f64; 3]) -> [f64; 6] {
    if let Some(b) = rules.family(ty).bounding_box(body, position) {
        return b;
    }
    let [w, h, _] = dimensions(rules, ty, body);
    let [x, y, z] = position;
    [x - w / 2.0, y, z - w / 2.0, x + w / 2.0, y + h, z + w / 2.0]
}

/// One entity data value: `(field, value, vanilla's default)`.
pub type DataValue = (Atom, Value, Value);

fn flag(data: &super::super::model::FamilyData, key: &str) -> bool {
    data.get(key).is_some_and(|v| v.as_bool() == Some(true))
}

/// `Body.values/1` of a mob: every modelled entity data field in index
/// order.
pub fn values(rules: &Rules, ty: Type, body: &Body) -> Vec<DataValue> {
    let mob = &body.mob;
    let living = &mob.living;
    let fire = if living.fire_ticks > 0 && !ty.facts.fire_immune {
        1
    } else {
        0
    };
    let sprinting = if flag(&body.data, "sprinting") { 8 } else { 0 };
    let invisible = if flag(&body.data, "invisible") { 32 } else { 0 };
    let swimming = if flag(&body.data, "swimming") { 16 } else { 0 };
    let sleeping = body.data.get("sleeping").cloned().unwrap_or(NIL);
    let pose = if living.health.value <= 0.0 {
        "dying"
    } else if flag(&body.data, "crouching") {
        "crouching"
    } else if sleeping.truthy() {
        "sleeping"
    } else {
        "standing"
    };
    let living_flags = match &mob.using {
        Some(u) if u.hand == super::super::model::Hand::OffHand => 3,
        Some(_) => 1,
        None => 0,
    };
    let aggressive = mob.ai.as_ref().is_some_and(|m| rules.mind.aggressive(m));
    let mob_flags =
        mob.no_ai as i64 + if mob.left_handed { 2 } else { 0 } + if aggressive { 4 } else { 0 };
    let atom = Atom::from_static;
    let mut out = vec![
        (
            atom("shared_flags"),
            Value::Int(fire + sprinting + swimming + invisible),
            Value::Int(0),
        ),
        (
            atom("air_supply"),
            Value::Int(living.air_supply as i64),
            Value::Int(300),
        ),
        (
            atom("custom_name"),
            body.custom_name.clone().unwrap_or(NIL),
            NIL,
        ),
        (
            atom("no_gravity"),
            Value::bool(body.no_gravity),
            Value::bool(false),
        ),
        (atom("pose"), Value::atom(pose), Value::atom("standing")),
        (
            atom("frozen_ticks"),
            Value::Int(living.freezing.frozen_ticks as i64),
            Value::Int(0),
        ),
        (
            atom("living_flags"),
            Value::Int(living_flags),
            Value::Int(0),
        ),
        (
            atom("health"),
            Value::Float(living.health.value),
            Value::Float(1.0),
        ),
        (atom("sleeping_pos"), sleeping, NIL),
        (atom("mob_flags"), Value::Int(mob_flags), Value::Int(0)),
    ];
    out.extend(rules.family(ty).values(body));
    out
}

/// Elixir's `==`: numbers compare arithmetically (`0.0 == -0.0`, `1 ==
/// 1.0`), anything else exactly.
pub fn loose_eq(a: &Value, b: &Value) -> bool {
    match (a.as_number(), b.as_number()) {
        (Some(x), Some(y)) => x == y,
        _ => a == b,
    }
}

/// What observers are shown of a mob beyond its motion (`Body.shown/1`):
/// its entity data, attribute overrides, equipment and the holder it is
/// leashed to.
#[derive(Clone, Debug, PartialEq)]
pub struct Shown {
    pub values: Vec<DataValue>,
    pub attributes: super::super::model::Attributes,
    pub equipment: Equipment,
    pub link: Option<i32>,
}

/// `Body.shown/1`.
pub fn shown(rules: &Rules, ty: Type, body: &Body) -> Shown {
    Shown {
        values: values(rules, ty, body),
        attributes: body.mob.attributes.clone(),
        equipment: body.mob.equipment.clone(),
        link: link(&body.mob),
    }
}

/// The holder observers see a mob leashed to.
pub fn link(mob: &Mob) -> Option<i32> {
    mob.leash.as_ref().and_then(|l| l.id)
}

/// `Body.shown_changes/3`'s parts: the data values that changed, the synced
/// attributes that changed and the equipment changes.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Changes {
    pub values: Vec<(Atom, Value)>,
    pub attributes: Vec<Synced>,
    pub equipment: Vec<(i32, Option<Value>)>,
    /// The new link where it changed (`Some(None)`: unleashed).
    pub link: Option<Option<i32>>,
}

/// `Body.changes/3` of a mob from `old` to `new`.
pub fn changes(rules: &Rules, ty: Type, old: &Shown, new: &Shown) -> Changes {
    if old == new {
        return Changes::default();
    }
    let values = new
        .values
        .iter()
        .zip(&old.values)
        .filter(|((_, value, _), (_, before, _))| !loose_eq(value, before))
        .map(|((field, value, _), _)| (field.clone(), value.clone()))
        .collect();
    let before = living_mob::synced(rules.living, rules.facts, ty, &old.attributes);
    let attributes = living_mob::synced(rules.living, rules.facts, ty, &new.attributes)
        .into_iter()
        .filter(|s| !before.contains(s))
        .collect();
    Changes {
        values,
        attributes,
        equipment: living_mob::equipment_changes(&new.equipment, &old.equipment),
        link: (old.link != new.link).then_some(new.link),
    }
}

/// `Body.pairing/2`'s parts for an observer that starts tracking: the
/// non-default data values, the synced attributes and the equipment.
pub fn pairing(rules: &Rules, ty: Type, body: &Body) -> Changes {
    Changes {
        values: values(rules, ty, body)
            .into_iter()
            .filter(|(_, value, default)| !loose_eq(value, default))
            .map(|(field, value, _)| (field, value))
            .collect(),
        attributes: living_mob::synced(rules.living, rules.facts, ty, &body.mob.attributes),
        equipment: living_mob::equipment_changes(&body.mob.equipment, &Equipment::default()),
        link: link(&body.mob).map(Some),
    }
}
