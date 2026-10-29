//! The controls a mob's AI runs itself: vanilla's `LookControl` and
//! `BodyRotationControl` (`look`, `Valimc.AI.Look`) and the smooth
//! swimmers' move and look controls (`smooth_swimming`). The move and jump
//! controls' settings are the turn's (`Turn::move_to`, `wait`, `strafe`,
//! `jump`); the physics kernel runs them after the AI.

pub mod look;
pub mod smooth_swimming;
