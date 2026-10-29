//! What players do with leads to native mobs (VMC-081d), ported from
//! `Valimc.Entity.Leashes`, for the owner of the section's mobs:
//!
//! - on a mob, `Entity.interact`'s lead part before the mob's own
//!   (`interact`): shears snip its lead, its holder unties it (the lead an
//!   item unless the player has infinite materials), a lead in hand leashes
//!   it to the player (from a knot, that lead an item first);
//! - a fence's use (`LeadItem.bindPlayerMobs`) and a fence knot's
//!   (`LeashFenceKnotEntity.interact`): the owner picks the mobs with
//!   `leashed_to` and `attachable` and moves them with `attach`; shears on a
//!   knot `drop` its mobs' leads.
//!
//! The mob's own tick does the rest (`ai::leash`).

use super::interact::{Done, Drop, Hand, InteractEvent, Interaction, Outcome};
use super::Kind;
use crate::mobs::ai::leash::{between, Holder};
use crate::mobs::living::body as living_body;
use crate::mobs::living::items;
use crate::mobs::living::mob::{self as living_mob, Type};
use crate::mobs::model::{Leash, LeashHolder, NativeMob};
use crate::mobs::sensing::Uuid;

/// `leashableInArea`: a 32-block box around the centre.
pub const AREA: f64 = 16.0;

/// The player using an item on a mob, as a holder.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Player {
    pub uuid: Uuid,
    pub holder: Holder,
}

// `isLeashed`: a holder found (a lead still looking for its holder is not).
fn held(mob: &NativeMob) -> Option<&Leash> {
    mob.body.mob.leash.as_ref().filter(|l| !l.restored)
}

/// `canHaveALeashAttachedTo`: a living mob of a family that takes a lead,
/// within 12 blocks of the holder.
pub fn attachable(i: &Interaction, kind: &dyn Kind, mob: &NativeMob, holder: &Holder) -> bool {
    let Some(ty) = Type::of(i.rules.facts, &mob.body.entity_type) else {
        return false;
    };
    let [width, height, _] = living_body::dimensions(i.rules, ty, &mob.body);
    kind.leashable()
        && living_mob::alive(&mob.body.mob)
        && between(
            mob.position,
            width,
            height,
            holder.position,
            holder.width,
            holder.height,
        ) <= 12.0
}

/// `setLeashedTo`: leashed to `holder` (network id `id`), keeping its
/// momentum.
pub fn attach(mob: &mut NativeMob, holder: LeashHolder, id: Option<i32>) {
    let momentum = mob.body.mob.leash.as_ref().map_or(0.0, |l| l.momentum);
    mob.body.mob.leash = Some(Leash {
        holder,
        id,
        momentum,
        restored: false,
    });
}

/// `removeLeash` without an item: the knot it let go, if any.
pub fn remove(mob: &mut NativeMob) -> Option<[i32; 3]> {
    let free = match &mob.body.mob.leash {
        Some(Leash {
            holder: LeashHolder::Knot(pos),
            ..
        }) => Some(*pos),
        _ => None,
    };
    mob.body.mob.leash = None;
    mob.body.mob.home = None;
    free
}

/// `dropLeash`: the lead gone, an item where the mob stands (`lead` is the
/// lead item's id); its home gone. The drops and the knot it let go.
pub fn drop(mob: &mut NativeMob, lead: i32) -> (Vec<Drop>, Option<[i32; 3]>) {
    let free = remove(mob);
    (
        vec![Drop {
            stack: items::new_stack(lead, 1, None),
            offset: [0.0; 3],
            add: None,
        }],
        free,
    )
}

/// Whether mob `mob` (its box `[width, height]` at its position) is held
/// by `holder` within `AREA` of `center` (`leashableInArea`).
pub fn leashed_to(
    mob: &NativeMob,
    size: [f64; 2],
    holder: &LeashHolder,
    [cx, cy, cz]: [f64; 3],
) -> bool {
    use crate::mobs::ai::fmath::f;
    let Some(leash) = held(mob) else {
        return false;
    };
    if &leash.holder != holder {
        return false;
    }
    let [x, y, z] = mob.position;
    let half = f(size[0] / 2.0);
    let (x0, y0, z0, x1, y1, z1) = (
        cx - AREA,
        cy - AREA,
        cz - AREA,
        cx + AREA,
        cy + AREA,
        cz + AREA,
    );
    x - half < x1 && x + half > x0 && y < y1 && y + size[1] > y0 && z - half < z1 && z + half > z0
}

fn sound(i: &Interaction, name: &str, block: bool) -> InteractEvent {
    let sound = i.sound(name);
    if block {
        InteractEvent::SoundBlock {
            sound,
            source: "player",
            volume: 1.0,
            pitch: 1.0,
        }
    } else {
        InteractEvent::Sound {
            sound,
            source: "neutral",
            volume: 1.0,
            pitch: 1.0,
        }
    }
}

/// `Leashes.interact/3`: a player's use on a mob, its lead part (`player`:
/// who uses it, as a holder), before the mob's own (`Kind::interact`).
pub fn interact(i: &mut Interaction, kind: &dyn Kind, player: &Player) -> Outcome {
    let facts = i.rules.facts;
    let (Some(lead), Some(shears)) = (
        facts.items.id("minecraft:lead"),
        facts.items.id("minecraft:shears"),
    ) else {
        return Outcome::Pass;
    };
    if !living_mob::alive(&i.mob.body.mob) {
        return Outcome::Pass;
    }
    let item = i.request.item_id();
    let leashed = held(i.mob).is_some();
    let by_player = held(i.mob).is_some_and(|l| l.holder == LeashHolder::Player(player.uuid));
    if item == Some(shears) && leashed {
        // `shearOffAllLeashConnections`: its snip where it stands.
        let (drops, free) = drop(i.mob, lead);
        Outcome::Done(Done {
            hand: Some(Hand::Wear(1)),
            events: vec![sound(i, "minecraft:item.shears.snip", true)],
            drops,
            free: free.into_iter().collect(),
            ..Done::default()
        })
    } else if by_player {
        let (drops, free) = if i.request.infinite {
            (Vec::new(), remove(i.mob))
        } else {
            drop(i.mob, lead)
        };
        Outcome::Done(Done {
            events: vec![sound(i, "minecraft:item.lead.untied", false)],
            drops,
            free: free.into_iter().collect(),
            ..Done::default()
        })
    } else if item == Some(lead)
        && !held(i.mob).is_some_and(|l| matches!(l.holder, LeashHolder::Player(_)))
        && attachable(i, kind, i.mob, &player.holder)
    {
        let (drops, free) = if leashed {
            drop(i.mob, lead)
        } else {
            (Vec::new(), None)
        };
        attach(i.mob, LeashHolder::Player(player.uuid), player.holder.id);
        Outcome::Done(Done {
            hand: Some(Hand::Use(1)),
            swing: true,
            events: vec![sound(i, "minecraft:item.lead.tied", false)],
            drops,
            free: free.into_iter().collect(),
            ..Done::default()
        })
    } else {
        Outcome::Pass
    }
}
