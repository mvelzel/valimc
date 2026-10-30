//! Rustler shim over valimc_core, one module per domain: `facts` (the block
//! fact table, installed once), `region` (the Region resource each region
//! owner holds), `rules` (block updates over it, VMC-077m), `light`, `climate`
//! (biome zoom and temperature at a block),
//! `codec` (disk NBT, LZ4 and column images), `sys`,
//! `worldgen`, `loot` and, in dev, test and bench
//! builds, `parity` (oracle and benchmark entry points). Inputs are validated
//! by valimc_core.
//!
//! Scheduling: a NIF on a normal scheduler stays under about 1 ms for any input
//! its caller may pass. Work that can take longer is a `DirtyCpu` NIF called
//! from a bounded pool (`Valimc.Worldgen.Pool`), or a normal/dirty pair that
//! `Valimc.Native.dispatch/3` picks by estimated cost. Live generation jobs run
//! on `background`'s low-priority threads instead and send their results.
//!
//! Results: a value as `{:ok, value}`, none as `:ok`; an expected failure as
//! `{:error, atom}` from its domain's closed set. A broken invariant (a
//! generator or loot table that cannot run what the facts say) raises.

use rustler::{Atom, Binary, Encoder, Env, NewBinary, NifResult, ResourceArc, Term};

mod background;
mod climate;
mod codec;
mod facts;
#[cfg(feature = "parity")]
mod fluid_parity;
#[cfg(feature = "parity")]
mod growth_parity;
mod light;
mod loot;
#[cfg(feature = "parity")]
mod mob_ai_parity;
#[cfg(feature = "parity")]
mod mob_dragon_parity;
mod mob_facts;
mod mob_living;
#[cfg(feature = "parity")]
mod mob_living_parity;
#[cfg(feature = "parity")]
mod mob_parity;
mod mob_section;
mod mob_section_level;
mod mob_term;
#[cfg(feature = "parity")]
mod mob_think_parity;
mod mob_tick;
mod mob_track;
mod mobs;
#[cfg(feature = "parity")]
mod parity;
mod path;
mod physics;
#[cfg(feature = "parity")]
mod physics_checks;
#[cfg(feature = "parity")]
mod piston_parity;
mod player;
#[cfg(feature = "parity")]
mod player_parity;
mod projectile;
#[cfg(feature = "parity")]
mod redstone_parity;
mod region;
mod rules;
mod snapshot;
mod spawn;
mod spawn_world;
mod sys;
mod worldgen;

mod atoms {
    rustler::atoms! {
        ok,
        out_of_region,
        invalid_y,
        invalid_state,
        invalid_positions,
        memory_budget,
        flags_missing,
        flags_mismatch,
        light_facts_missing,
        invalid_layers,
        poisoned,
        not_owner,
        flat,
        too_large,
        old_column_image,
    }
}

/// A copy of `bytes` as a new binary.
fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> Binary<'a> {
    let mut out = NewBinary::new(env, bytes.len());
    out.as_mut_slice().copy_from_slice(bytes);
    out.into()
}

/// Bytes a binary points into, freed with the binary's last reference.
struct Bytes(Vec<u8>);

#[rustler::resource_impl]
impl rustler::Resource for Bytes {}

/// `bytes` as a binary without copying them (small ones are copied onto the
/// process heap, as the VM keeps them). The binary holds the buffer, so spare
/// capacity is given back first.
fn bytes<'a>(env: Env<'a>, mut bytes: Vec<u8>) -> Binary<'a> {
    if bytes.len() <= 64 {
        return binary(env, &bytes);
    }
    bytes.shrink_to_fit();
    ResourceArc::new(Bytes(bytes)).make_binary(env, |b| &b.0)
}

/// Bytes made where no environment is (background jobs, VMC-081c): a binary
/// over them once encoded, as `bytes/2` makes.
pub(crate) struct Bin(ResourceArc<Bytes>);

impl Bin {
    pub(crate) fn new(mut bytes: Vec<u8>) -> Bin {
        bytes.shrink_to_fit();
        Bin(ResourceArc::new(Bytes(bytes)))
    }
}

// Only results carry one (map derives want both directions).
impl<'a> rustler::Decoder<'a> for Bin {
    fn decode(_term: Term<'a>) -> NifResult<Self> {
        Err(rustler::Error::BadArg)
    }
}

impl Encoder for Bin {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        if self.0 .0.len() <= 64 {
            return binary(env, &self.0 .0).encode(env);
        }
        self.0.make_binary(env, |b| &b.0).encode(env)
    }
}

/// `:ok`, or `{:error, reason}`.
fn done(result: Result<(), Atom>) -> NifResult<Atom> {
    result
        .map(|()| atoms::ok())
        .map_err(|reason| rustler::Error::Term(Box::new(reason)))
}

/// `{:ok, value}`; valimc_core's message for a broken invariant raises.
fn reply<T>(result: Result<T, String>) -> NifResult<(Atom, T)> {
    result.map(|value| (atoms::ok(), value)).map_err(raise)
}

fn raise(message: String) -> rustler::Error {
    rustler::Error::RaiseTerm(Box::new(message))
}

rustler::init!("Elixir.Valimc.Native");
