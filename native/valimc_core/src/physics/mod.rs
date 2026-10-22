//! The entity physics kernel (VMC-077l): vanilla's collision geometry, block
//! scans, movement with step-up, swept inside-block visits, fluid sampling and
//! the supporting block, over published chunk rows or a region's own store.
//! Players use it per move packet, region owners per tick for all bodies.

pub mod aabb;
pub mod border;
pub mod collide;
pub mod facts;
pub mod fluid;
pub mod item;
pub mod orb;
pub mod player;
pub mod response;
pub mod shape;
pub mod source;
pub mod support;
pub mod sweep;
pub mod table;

pub use aabb::Aabb;
pub use shape::{Place, VoxelShape, EPSILON};
pub use source::{BlockSource, Unreadable};
pub use table::{Context, ShapeTable};
