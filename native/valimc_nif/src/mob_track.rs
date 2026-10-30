//! The trackers of a section's native mobs (VMC-081i): each mob's
//! `valimc_core::tracker::Tracker` lives on its slot, and one call per
//! section tick writes the packets of every tracked mob into one frame
//! (`valimc_core::tracker`'s entries), which observers forward as it is.
//!
//! The owner (`Valimc.Entity.Tracking`) decides each tracker's life: it
//! starts one (`fresh`) where it publishes a new mob's spawn, and names the
//! mobs whose view changed since its last tick (`run`) with the entity
//! events and data changes it encoded for them. A mob ticks when it stands
//! in a simulated chunk (`mask`) or is named; the others cost nothing.

use crate::mob_section::{self as ms, MobSectionRes};
use rustler::{Atom, Binary, Env, NifResult, ResourceArc, Term};
use std::collections::HashMap;
use valimc_core::tracker::{self, PacketIds, Seen, Tracker};

mod atoms {
    rustler::atoms! { all }
}

fn bad() -> rustler::Error {
    rustler::Error::BadArg
}

fn f64_at(b: &[u8], at: usize) -> f64 {
    f64::from_be_bytes(b[at..at + 8].try_into().unwrap())
}

/// One section tick of its native mobs' trackers: `{frame, spawns}`.
///
/// - `mask`: the section's simulated chunks (`NativeMobs.simulated_mask/2`),
///   or `:all`.
/// - `fresh`: trackers to start, `<<id::32, base x, y, z, motion x, y, z ::
///   float-64, ground, yaw, pitch, head>>` each (the angle bytes sent).
/// - `run`: `[{id, events, changes}]`, the mobs whose view changed, with
///   their new entity events and data changes as frame entries.
/// - `ids`: the packet ids (`valimc_core::tracker::PacketIds`, in order).
///
/// `spawns` holds, for each mob whose spawn changed, `<<id::32, started,
/// base x, y, z :: float-64, size::32, add_entity payload>>`; `started` is 1
/// for a slot that had no tracker (its owner did not see it come back) and
/// whose tracker starts here, at the tick's state.
#[rustler::nif]
#[allow(clippy::type_complexity)]
fn mob_section_track<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    mask: Term<'a>,
    fresh: Binary<'a>,
    run: Vec<(i32, Binary<'a>, Binary<'a>)>,
    ids: (u16, u16, u16, u16, u16, u16, u16),
) -> NifResult<(Binary<'a>, Binary<'a>)> {
    let mask: Option<u64> = match mask.decode::<u64>() {
        Ok(m) => Some(m),
        Err(_) if mask.decode::<Atom>().is_ok_and(|a| a == atoms::all()) => None,
        Err(_) => return Err(bad()),
    };
    let ids = PacketIds {
        add_entity: ids.0,
        motion: ids.1,
        position_sync: ids.2,
        move_pos: ids.3,
        move_pos_rot: ids.4,
        move_rot: ids.5,
        rotate_head: ids.6,
    };
    let rules = ms::rules()?;
    let mut inner = ms::owned(env, &res)?;
    let section = &mut inner.section;
    let (sx, sz) = section.section;

    let (entries, rest) = fresh.as_chunks::<56>();
    if !rest.is_empty() {
        return Err(bad());
    }
    for e in entries {
        let id = i32::from_be_bytes(e[0..4].try_into().unwrap());
        let Some(slot) = section.peek_mut(id) else {
            continue;
        };
        let Some(ty) = rules.of(&slot.mob.body.entity_type) else {
            continue;
        };
        slot.tracker = Some(Tracker::new(
            [f64_at(e, 4), f64_at(e, 12), f64_at(e, 20)],
            [f64_at(e, 28), f64_at(e, 36), f64_at(e, 44)],
            e[52] == 1,
            (e[53], e[54]),
            e[55],
            ty.facts.update_interval,
            ty.facts.track_deltas,
        ));
    }

    let named: HashMap<i32, (&[u8], &[u8])> = run
        .iter()
        .map(|(id, events, changes)| (*id, (events.as_slice(), changes.as_slice())))
        .collect();
    let simulated = |chunk: (i32, i32)| match mask {
        None => true,
        Some(mask) => {
            let (lx, lz) = (chunk.0 - sx * 8, chunk.1 - sz * 8);
            (0..8).contains(&lx) && (0..8).contains(&lz) && mask >> (lz * 8 + lx) & 1 == 1
        }
    };

    let mut frame = Vec::new();
    let mut spawns = Vec::new();
    let all: Vec<i32> = section.ids().collect();
    for id in all {
        let slot = section.peek_mut(id).ok_or_else(bad)?;
        let named = named.get(&id).copied();
        if slot.pending || !(named.is_some() || simulated(slot.chunk)) {
            continue;
        }
        let (events, changes) = named.unwrap_or((&[], &[]));
        let Some(ty) = rules.of(&slot.mob.body.entity_type) else {
            continue;
        };
        let b = &slot.mob.body;
        let seen = Seen {
            position: slot.mob.position,
            yaw: b.yaw,
            pitch: b.pitch,
            head_yaw: b.head_yaw,
            velocity: b.velocity,
            on_ground: b.on_ground,
        };
        // A slot that came back whole (a parcel the owner did not see leave)
        // starts a tracker where it is: its owner gives it a new incarnation.
        let started = slot.tracker.is_none();
        let t = slot.tracker.get_or_insert_with(|| {
            Tracker::new(
                seen.position,
                seen.velocity,
                seen.on_ground,
                (tracker::angle(seen.yaw), tracker::angle(seen.pitch)),
                tracker::angle(seen.head_yaw),
                ty.facts.update_interval,
                ty.facts.track_deltas,
            )
        });
        frame.extend_from_slice(events);
        if t.tick(id, &seen, changes, &ids, &mut frame) || started {
            let payload =
                tracker::spawn_payload(id, &slot.mob.uuid, ty.facts.id, t.base, t.movement, &seen);
            spawns.extend_from_slice(&id.to_be_bytes());
            spawns.push(u8::from(started));
            for v in t.base {
                spawns.extend_from_slice(&v.to_be_bytes());
            }
            spawns.extend_from_slice(&(payload.len() as u32).to_be_bytes());
            spawns.extend_from_slice(&payload);
        }
    }
    Ok((crate::bytes(env, frame), crate::bytes(env, spawns)))
}

/// The spawn payload and the tick's packets of one tracker over `states`
/// (`Valimc.Entity.Tracker`'s parity): `{spawn, [frame]}`, one frame per
/// state, each `<<x, y, z, yaw, pitch, head, vx, vy, vz :: float-64,
/// ground>>` with its data changes (frame entries) in `changes`. The
/// tracker starts at the first state.
#[cfg(feature = "parity")]
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn tracker_parity<'a>(
    env: Env<'a>,
    id: i32,
    uuid: Binary<'a>,
    ty: u16,
    interval: i32,
    track_deltas: bool,
    ids: (u16, u16, u16, u16, u16, u16, u16),
    states: Binary<'a>,
    changes: Vec<Binary<'a>>,
) -> NifResult<(Binary<'a>, Vec<Binary<'a>>)> {
    let ids = PacketIds {
        add_entity: ids.0,
        motion: ids.1,
        position_sync: ids.2,
        move_pos: ids.3,
        move_pos_rot: ids.4,
        move_rot: ids.5,
        rotate_head: ids.6,
    };
    let uuid: [u8; 16] = uuid.as_slice().try_into().map_err(|_| bad())?;
    let (packed, rest) = states.as_chunks::<73>();
    if !rest.is_empty() || packed.len() != changes.len() || changes.is_empty() {
        return Err(bad());
    }
    let seen: Vec<Seen> = packed
        .iter()
        .map(|s| Seen {
            position: [f64_at(s, 0), f64_at(s, 8), f64_at(s, 16)],
            yaw: f64_at(s, 24),
            pitch: f64_at(s, 32),
            head_yaw: f64_at(s, 40),
            velocity: [f64_at(s, 48), f64_at(s, 56), f64_at(s, 64)],
            on_ground: s[72] == 1,
        })
        .collect();
    let first = seen[0];
    let mut t = Tracker::new(
        first.position,
        first.velocity,
        first.on_ground,
        (tracker::angle(first.yaw), tracker::angle(first.pitch)),
        tracker::angle(first.head_yaw),
        interval,
        track_deltas,
    );
    let spawn = tracker::spawn_payload(id, &uuid, ty, t.base, t.movement, &first);
    let mut frames = Vec::new();
    for (s, c) in seen.iter().zip(&changes) {
        let mut out = Vec::new();
        t.tick(id, s, c.as_slice(), &ids, &mut out);
        frames.push(crate::bytes(env, out));
    }
    Ok((crate::bytes(env, spawn), frames))
}
