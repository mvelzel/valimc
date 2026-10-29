//! A player's use of an item on a native mob (`mobInteract`, VMC-081d),
//! ported from `Valimc.Entity.Animals.Interaction`'s contract: the owner
//! asks a mob's family (`Kind::interact`) with the request, the family
//! changes the mob in place and answers what happened, which the owner
//! applies as it applies the Elixir's outcome (`RegionData.interacted`).
//!
//! The answer is `Pass` (nothing: the next part of the chain or the item's
//! own use), `Consume` (the use is taken, nothing happens: shears on a
//! sheep not ready) or `Done(Done)`: `hand` (`:keep`, `{:use, n}`,
//! `{:fill, stack}`, `{:wear, n}`), `swing` (`SUCCESS_SERVER`), `events`
//! (the mob's: sounds to everyone, entity events), `others` (a sound the
//! player made, to the others), `drops` (`{stack, offset, velocity}`),
//! `convert` (the body it becomes, a new entity) and `free` (fence knots a
//! dropped lead was tied to). Draws on the mob's own random use its mind's
//! (one made from its uuid where it has none, `combat::random`).

use crate::mobs::combat::{self, Event, Rules, SoundRef};
use crate::mobs::model::{Body, NativeMob};
use crate::mobs::random::LegacyRandom;
use crate::mobs::sensing::Uuid;
use crate::mobs::term::Value;

/// `%{item: stack | nil, infinite: boolean, player: uuid | nil}`.
#[derive(Clone, Debug, PartialEq)]
pub struct Request {
    /// The `%ItemStack{}` in the hand used.
    pub item: Option<Value>,
    /// The player has infinite materials (creative).
    pub infinite: bool,
    /// The player, where the owner knows it (love's cause).
    pub player: Option<Uuid>,
}

impl Request {
    /// The used stack's item id.
    pub fn item_id(&self) -> Option<i32> {
        self.item.as_ref().and_then(crate::mobs::ai::hooks::item_id)
    }
}

/// What happens to the stack in the player's hand.
#[derive(Clone, Debug, PartialEq)]
pub enum Hand {
    Keep,
    /// `{:use, n}`: n used up.
    Use(i32),
    /// `{:fill, stack}`: one used up and `stack` given (a bucket of milk).
    Fill(Value),
    /// `{:wear, n}`: n durability worn (shears).
    Wear(i32),
}

/// Where a sound the player made plays for the others.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum At {
    /// `:player`.
    Player,
    /// `:animal`.
    Animal,
}

/// A sound for the others (`{id, source, volume, pitch, at}`).
#[derive(Clone, Debug, PartialEq)]
pub struct Other {
    pub sound: i32,
    pub source: &'static str,
    pub volume: f64,
    pub pitch: f64,
    pub at: At,
}

/// A mob's event of an interaction.
#[derive(Clone, Debug, PartialEq)]
pub enum InteractEvent {
    /// `{:sound, id, source, volume, pitch, seed}` from the mob.
    Sound {
        sound: i32,
        source: &'static str,
        volume: f64,
        pitch: f64,
    },
    /// `{:sound_block, ...}`: at its block's centre.
    SoundBlock {
        sound: i32,
        source: &'static str,
        volume: f64,
        pitch: f64,
    },
    /// `{:event, n}`.
    Entity(i32),
}

impl InteractEvent {
    /// The living rules' form of it (a block sound stays its own term).
    pub fn event(&self, rules: &Rules) -> Event {
        let source = |name: &str| rules.facts.sounds.sources.get(name).copied().unwrap_or(0);
        match self {
            InteractEvent::Sound {
                sound,
                source: s,
                volume,
                pitch,
            } => Event::Sound {
                sound: SoundRef::Id(*sound),
                source: source(s),
                volume: *volume,
                pitch: *pitch,
            },
            InteractEvent::SoundBlock { .. } => Event::Other(Value::atom("sound_block")),
            InteractEvent::Entity(n) => Event::Entity(*n),
        }
    }
}

/// An item dropped: `{stack, offset from the mob, velocity}`.
#[derive(Clone, Debug, PartialEq)]
pub struct Drop {
    pub stack: Value,
    pub offset: [f64; 3],
    /// `{:add, v}`: added to the item's own launch; None: its own.
    pub add: Option<[f64; 3]>,
}

/// What an interaction did.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Done {
    pub hand: Option<Hand>,
    pub swing: bool,
    pub events: Vec<InteractEvent>,
    pub others: Option<Other>,
    pub drops: Vec<Drop>,
    /// The body it becomes (a sheared mooshroom's cow), a new entity.
    pub convert: Option<Box<Body>>,
    pub discard: bool,
    pub free: Vec<[i32; 3]>,
}

impl Done {
    pub fn hand(&self) -> &Hand {
        self.hand.as_ref().unwrap_or(&Hand::Keep)
    }
}

/// `:pass`, `:consume` or `{:ok, body, outcome}` (the body changed in place).
#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    Pass,
    Consume,
    Done(Done),
}

/// A loot table's drops for an interaction (shearing): the stacks of table
/// `table` for an entity with `properties`.
pub type Loot<'a> = dyn FnMut(&str, &[(String, String)]) -> Vec<Value> + 'a;

/// One interaction: the rules, the mob, the request and the loot tables.
pub struct Interaction<'a> {
    pub rules: &'a Rules<'a>,
    pub mob: &'a mut NativeMob,
    pub request: &'a Request,
    pub loot: &'a mut Loot<'a>,
}

impl Interaction<'_> {
    /// The mob's own random (`Interaction.draw/2`).
    pub fn random(&mut self) -> &mut LegacyRandom {
        let uuid = self.mob.uuid;
        combat::random(&mut self.mob.body.mob, &uuid)
    }

    /// `Interaction.spread/2`: `(nextFloat() - nextFloat()) * scale`, in
    /// floats.
    pub fn spread(&mut self, scale: f64) -> f64 {
        use crate::mobs::ai::fmath::f;
        let a = self.random().float() as f64;
        let b = self.random().float() as f64;
        f(f(a - b) * f(scale))
    }

    /// A sound id by name (0 for an unknown one).
    pub fn sound(&self, name: &str) -> i32 {
        self.rules.facts.sounds.id(name).unwrap_or(0)
    }
}
