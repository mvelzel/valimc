//! The AI machinery of native mobs (VMC-081d), ported from `Valimc.AI`:
//! the mind's live state (`mind`), the turn context a mob's AI runs in
//! (`turn`, `Valimc.AI.Self`), the effects that leave the mob (`effect`),
//! the goal contract and goal selector (`goal`, `selector`), the look, body
//! rotation and smooth swimming controls (`control`), navigation over the
//! path crate run synchronously in process (`navigation`, `paths`), random
//! walk targets and block shapes (`random_pos`, `shapes`), the goals of
//! `Valimc.AI.Goals` (`goals`) and the hooks families give (`hooks`).
//!
//! Exactness: every draw happens in the Elixir's order on the same stream
//! (the mob's `LegacyRandom`, the section's level random); numbers keep the
//! Elixir representation, an `f64` rounded to a Java float exactly where the
//! Elixir calls `Float32.round` (`fmath::f`), so each computation gives the
//! bits the Elixir gives. Erlang's `min` and `max` answer their first
//! argument on a tie (`fmath::emin`, `emax`), which decides signed zeros.

pub mod consume;
pub mod control;
pub mod effect;
pub mod fmath;
pub mod goal;
pub mod goals;
pub mod hooks;
pub mod leash;
pub mod mind;
pub mod navigation;
pub mod paths;
pub mod pickup;
pub mod pois;
pub mod random_pos;
pub mod selector;
pub mod shapes;
pub mod spawn;
pub mod think;
pub mod turn;

pub use effect::Effect;
pub use goal::Goal;
pub use hooks::{DefaultHooks, Hooks};
pub use mind::MindState;
pub use navigation::Navigation;
pub use selector::{Selector, Which};
pub use turn::{Eyes, Seen, Turn};

use std::any::Any;
use std::fmt::Debug;

/// What sensed mobs carry beyond the common part (`SensedMob<X>`): what
/// families read of each other's own state (`AI.sensed/1`'s `data`: an
/// animal's, whose partner's variant or colour its child takes; `own`: a
/// family's own fields of its mind others read, a fish's school). None
/// where nothing reads it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Extra {
    pub data: Option<crate::mobs::model::FamilyData>,
    pub own: Option<Box<dyn Opaque>>,
    /// A brain mob's memories as the Elixir's term map (`AI.sensed/1`'s
    /// `memories`: a villager's last sleep an iron golem reads); None for a
    /// mob without a brain. The owner gives an Elixir brain mob's.
    pub memories: Option<crate::mobs::term::Value>,
}

/// A value the core holds without interpreting it (a brain's state, a
/// family's own fields, a family goal's state): cloned and compared through
/// its concrete type.
pub trait Opaque: Any + Debug + Send + Sync {
    fn clone_box(&self) -> Box<dyn Opaque>;
    fn eq_box(&self, other: &dyn Opaque) -> bool;
    fn as_any(&self) -> &dyn Any;
    fn as_any_mut(&mut self) -> &mut dyn Any;
}

impl<T: Any + Debug + Clone + PartialEq + Send + Sync> Opaque for T {
    fn clone_box(&self) -> Box<dyn Opaque> {
        Box::new(self.clone())
    }

    fn eq_box(&self, other: &dyn Opaque) -> bool {
        other.as_any().downcast_ref::<T>() == Some(self)
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}

impl Clone for Box<dyn Opaque> {
    fn clone(&self) -> Self {
        (**self).clone_box()
    }
}

impl PartialEq for Box<dyn Opaque> {
    fn eq(&self, other: &Self) -> bool {
        (**self).eq_box(&**other)
    }
}

#[cfg(test)]
mod tests;
