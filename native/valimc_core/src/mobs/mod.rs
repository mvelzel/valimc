//! Native mobs (VMC-081d): mob state, AI, base tick, vitals, combat, records
//! and tracking, owned per section by its group process. See
//! `docs/tickets/VMC-081d.md`.

pub mod facts;
pub mod level;
pub mod model;
pub mod mth;
pub mod random;
pub mod record;
pub mod sensing;
pub mod term;
pub mod ai;
pub mod combat;
pub mod living;
pub mod vitals;
