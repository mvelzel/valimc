//! Rustler shim over valimc_core, one module per domain: `region` (the Region
//! resource each region owner holds), `light`, `codec` (disk NBT, LZ4 and
//! column images), `sys`, `worldgen`, `loot` and `parity` (oracle and bench
//! entry points). Inputs are validated by valimc_core.

use rustler::{Binary, Encoder, Env, NewBinary, Term};

mod codec;
mod light;
mod loot;
mod parity;
mod region;
mod sys;
mod worldgen;

mod atoms {
    rustler::atoms! {
        ok,
        out_of_region,
        invalid_y,
        invalid_state,
        memory_budget,
        flags_missing,
        flags_mismatch,
        invalid_layers,
        poisoned,
        flat,
        dense,
    }
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut out = NewBinary::new(env, bytes.len());
    out.as_mut_slice().copy_from_slice(bytes);
    Binary::from(out).encode(env)
}

rustler::init!("Elixir.Valimc.Native");
