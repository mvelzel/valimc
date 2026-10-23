//! Natural spawning (VMC-042a): vanilla's `NaturalSpawner` over a group's
//! sections or an oracle's scene. `facts` holds what it reads, `level` the
//! world access, `rules` the spawn rules and `spawner` the attempts, packs
//! and caps; `block_spawner` the spawner blocks' ticks and `structures` the
//! structures' spawn overrides (VMC-042b).

pub mod block_spawner;
pub mod facts;
pub mod level;
pub mod rules;
pub mod spawner;
pub mod structures;
