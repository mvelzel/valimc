//! Clean-room vanilla world generation (VMC-023 onward), from `javap -c` of the
//! pinned jar and oracle samples of vanilla's own classes.

pub mod blocks;
pub mod carver;
pub mod climate;
pub mod compiler;
pub mod density;
pub mod feature;
pub mod formations;
pub mod interval;
pub mod java;
pub mod javahash;
pub mod json;
pub mod multiface;
pub mod noise;
pub mod placement;
pub mod plants;
pub mod predicate;
pub mod providers;
pub mod random;
pub mod region;
pub mod sampler;
pub mod sculk;
pub mod shapes;
pub mod speleothem;
pub mod state_provider;
pub mod support;
pub mod surface;
pub mod template;
pub mod terrain;
pub mod trace;
pub mod tree;
pub mod volume;
