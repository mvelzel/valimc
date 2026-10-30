//! What leaves a mob in its tick (`Valimc.AI.Self.effects`): the typed
//! form of the effect tuples the owner applies after the section moved
//! (`RegionData.move_mobs`) and of the changes one mob makes to another
//! (`AI.other_change`). Each variant names its tuple; a payload the core
//! does not interpret (an item stack, a hit's extras, a spawn's options) is
//! the Elixir term (`Value`). A change carried as a closure in the Elixir
//! (`{:own, ...}`, `{:remote, ...}`, `{:brain, ...}`) is a family's typed
//! change behind `Opaque`.

use super::Opaque;
use crate::mobs::model::Hand;
use crate::mobs::sensing::{Ref, Uuid};
use crate::mobs::term::Value;

/// How an eaten block goes (`{:eat_block, cell, how}`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Eaten {
    /// Grass under it turns to dirt.
    Dirt,
    /// The plant it stands in is destroyed.
    Destroy,
}

/// An arrow a skeleton looses (`{:shoot, %{...}}`).
#[derive(Clone, Debug, PartialEq)]
pub struct Shot {
    pub target: Ref,
    /// The target's `{x, y, z, height}`.
    pub at: [f64; 4],
    /// The shooter's eye.
    pub from: [f64; 3],
    pub power: f64,
    pub pitch: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// `{:sound, id, source, volume, pitch, seed}`: a sound from the mob.
    Sound {
        id: i32,
        source: i32,
        volume: f64,
        pitch: f64,
        seed: i64,
    },
    /// `{:sound_at, id, source, {x, y, z}, volume, pitch}`.
    SoundAt {
        id: i32,
        source: &'static str,
        at: [f64; 3],
        volume: f64,
        pitch: f64,
    },
    /// `{:sound_block, ...}`: a block's sound (a family's).
    SoundBlock(Value),
    /// `{:swing, hand}`.
    Swing(Hand),
    /// `{:event, id}`: an entity event.
    Event(i32),
    /// `{:level_event, cell, type, data}`.
    LevelEvent {
        cell: [i32; 3],
        kind: i32,
        data: i32,
    },
    /// `{:attack, ref}`: a melee hit (`doHurtTarget`).
    Attack(Ref),
    /// `{:attack_extra, ref, extras}`: what its family adds to a hit.
    AttackExtra(Ref, Value),
    /// `{:hurt, target, type, amount, actions}`: a hurt beyond its melee.
    Hurt {
        target: Ref,
        kind: Value,
        amount: f64,
        actions: Value,
    },
    /// `{:touch, target, amount, sound}`: a cube's touch.
    Touch {
        target: Ref,
        amount: f64,
        sound: Value,
    },
    /// `{:effect, target, actions}`: effects given without a hurt.
    GiveEffect {
        target: Ref,
        actions: Value,
    },
    /// `{:alert, uuid, target}`: another mob's target set at once.
    Alert {
        mob: Uuid,
        target: Ref,
    },
    /// `{:bred, ref}`: a partner bred (its age and love).
    Bred(Ref),
    /// `{:offspring, type, data, at}`: a bred child.
    Offspring {
        type_id: u16,
        data: Value,
        at: [f64; 3],
    },
    /// `{:orb, value, at}`: an experience orb.
    Orb {
        value: i32,
        at: [f64; 3],
    },
    /// `{:own, uuid, change}`: another mob's own state changed.
    Own {
        mob: Uuid,
        change: Box<dyn Opaque>,
    },
    /// `{:remote, uuid, change}`: another mob's mind changed.
    Remote {
        mob: Uuid,
        change: Box<dyn Opaque>,
    },
    /// `{:brain, uuid, change}`: another brain mob's reaction.
    Brain {
        mob: Uuid,
        change: Box<dyn Opaque>,
    },
    /// `{:eat_block, cell, how}`.
    EatBlock {
        cell: [i32; 3],
        how: Eaten,
    },
    /// `{:remove_block, cell}`.
    RemoveBlock([i32; 3]),
    /// `{:take_block, ...}`, `{:place_carried, cell, state}`: an
    /// enderman's block.
    TakeBlock(Value),
    PlaceCarried {
        cell: [i32; 3],
        state: i32,
    },
    /// `{:trample, cell}`.
    Trample([i32; 3]),
    /// `{:crush_egg, cell, odds}`.
    CrushEgg {
        cell: [i32; 3],
        odds: i32,
    },
    /// `{:raid_carrot, cell}`.
    RaidCarrot([i32; 3]),
    /// `{:lay_eggs, cell, ...}`.
    LayEggs(Value),
    /// `{:infest, cell, state}`, `{:wake_infested, cell, state, spawn}`.
    Infest {
        cell: [i32; 3],
        state: i32,
    },
    WakeInfested(Value),
    /// `{:door, pos, open}`, `{:bed, pos, occupied}`.
    Door {
        cell: [i32; 3],
        open: bool,
    },
    Bed {
        cell: [i32; 3],
        occupied: bool,
    },
    /// `{:shoot, shot}`: an arrow.
    Shoot(Shot),
    /// `{:projectile, type, position, power, ...}`, `{:throw_potion, ...}`,
    /// `{:throw_trident, ...}`, `{:throw, ...}`, `{:shoot_bullet, ...}`.
    Projectile(Value),
    ThrowPotion(Value),
    ThrowTrident(Value),
    Throw(Value),
    ShootBullet(Value),
    /// `{:explode, blast}`.
    Explode(Value),
    /// A piglin's barter (`stopHoldingOffHandItem` of a gold ingot): the
    /// bartering table rolled with `seed` (`World.loot_seed`, the Elixir's
    /// `Loot.barter/1`) and each item thrown from `from` at `velocity`
    /// (`{:throw, stack, from, velocity}` per item).
    Barter {
        seed: i64,
        from: [f64; 3],
        velocity: [f64; 3],
    },
    /// `{:pickup, {:item, uuid}, count}`.
    Pickup {
        item: Uuid,
        count: i32,
    },
    /// `{:drop, stack}`.
    Drop(Value),
    /// `{:lay, velocity}`, `{:gift, table, velocity}`: drops of a table.
    Lay([f64; 3]),
    Gift {
        table: String,
        velocity: [f64; 3],
    },
    /// `{:lead, at}`, `{:knot_free, pos}`, `{:make_knot, pos}`.
    Lead([f64; 3]),
    KnotFree([i32; 3]),
    MakeKnot([i32; 3]),
    /// `{:spawn, type, opts}`, `{:spawn_body, body, uuid}`,
    /// `{:spawn_mob, ...}`, `{:jockey, uuid}`.
    Spawn {
        type_id: u16,
        options: Value,
    },
    SpawnBody(Box<crate::mobs::model::NativeMob>),
    SpawnMob(Value),
    Jockey(Uuid),
    /// `{:convert, type}`, `:discard`.
    Convert(u16),
    Discard,
    /// `{:elder_curse, at}`, `{:shulker_push, ...}`.
    ElderCurse([f64; 3]),
    ShulkerPush(Value),
    /// `{:locate, uuid, request, query}`: a structure query.
    Locate(Value),
    /// An event of the living rules the AI made happen to the mob (a
    /// family's air drowning it), as its hurt path returns it.
    Living(crate::mobs::combat::Event),
}
