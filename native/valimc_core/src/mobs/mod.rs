//! Native mobs (VMC-081d): mob state, AI, base tick, vitals, combat, records
//! and tracking, owned per section by its group process. See
//! `docs/tickets/VMC-081d.md`.

pub mod ai;
pub mod ambient;
pub mod animals;
pub mod boss;
pub mod brains;
pub mod combat;
pub mod facts;
pub mod kinds;
pub mod level;
pub mod living;
pub mod model;
pub mod monsters;
pub mod mth;
pub mod publish;
pub mod random;
pub mod record;
pub mod section;
pub mod sensing;
pub mod term;
pub mod tick;
pub mod village;
pub mod vitals;
pub mod water;
