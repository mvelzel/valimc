//! Disk formats: NBT, LZ4 region chunks and column images.

use crate::facts::FLAGS;
use crate::{atoms, binary, bytes};
use rustler::{Atom, Binary, Encoder, Env, NewBinary, Term};
use valimc_core::column::HEIGHT;
use valimc_core::{nbt, Storage};

// ---- Disk NBT (VMC-020) ----

pub(crate) mod nbt_atoms {
    rustler::atoms! {
        end_ = "end", byte, short, int, long, float, double, byte_array, string, list, compound,
        int_array, long_array,
        nbt_byte_limit, nbt_node_limit, nbt_depth_limit, truncated_nbt, unknown_nbt_tag,
        invalid_nbt_list, invalid_nbt_array_length, invalid_nbt_utf, nbt_root_not_compound,
        trailing_nbt_bytes,
    }
}

fn nbt_type(id: u8) -> Atom {
    use nbt_atoms::*;
    match id {
        1 => byte(),
        2 => short(),
        3 => int(),
        4 => long(),
        5 => float(),
        6 => double(),
        7 => byte_array(),
        8 => string(),
        9 => list(),
        10 => compound(),
        11 => int_array(),
        12 => long_array(),
        _ => end_(),
    }
}

fn nbt_error(e: nbt::NbtError) -> Atom {
    use nbt::NbtError::*;
    use nbt_atoms::*;
    match e {
        ByteLimit => nbt_byte_limit(),
        NodeLimit => nbt_node_limit(),
        DepthLimit => nbt_depth_limit(),
        Truncated => truncated_nbt(),
        UnknownTag => unknown_nbt_tag(),
        InvalidList => invalid_nbt_list(),
        InvalidArrayLength => invalid_nbt_array_length(),
        InvalidUtf => invalid_nbt_utf(),
        RootNotCompound => nbt_root_not_compound(),
        Trailing => trailing_nbt_bytes(),
    }
}

/// Builds `Valimc.NBT` terms; raw values and UTF-8 strings are sub-binaries of the input.
struct Terms<'a> {
    env: Env<'a>,
    input: Binary<'a>,
}

impl<'a> nbt::Visitor for Terms<'a> {
    type Value = Term<'a>;
    fn int(&mut self, value: i64) -> Term<'a> {
        value.encode(self.env)
    }
    fn raw(&mut self, start: usize, len: usize) -> Term<'a> {
        self.input
            .make_subbinary(start, len)
            .expect("range within input")
            .encode(self.env)
    }
    fn string(&mut self, text: nbt::Text) -> Term<'a> {
        match text {
            nbt::Text::Slice(start, len) => self.raw(start, len),
            nbt::Text::Owned(s) => binary(self.env, s.as_bytes()).encode(self.env),
        }
    }
    fn list(&mut self, element: u8, items: Vec<Term<'a>>) -> Term<'a> {
        (nbt_type(element), items).encode(self.env)
    }
    fn compound(&mut self, entries: Vec<(Term<'a>, u8, Term<'a>)>) -> Term<'a> {
        let (keys, values): (Vec<Term<'a>>, Vec<Term<'a>>) = entries
            .into_iter()
            .map(|(name, id, value)| (name, (nbt_type(id), value).encode(self.env)))
            .unzip();
        // A repeated name keeps its last value, as vanilla's CompoundTag does.
        Term::map_from_arrays(self.env, &keys, &values).unwrap_or_else(|_| {
            keys.into_iter()
                .zip(values)
                .fold(Term::map_new(self.env), |map, (k, v)| {
                    map.map_put(k, v).expect("map")
                })
        })
    }
}

fn read_nbt<'a>(
    env: Env<'a>,
    input: Binary<'a>,
    bytes: usize,
    nodes: i64,
    depth: u32,
) -> Result<Term<'a>, Atom> {
    let limits = nbt::Limits {
        bytes,
        nodes,
        depth,
    };
    let mut terms = Terms { env, input };
    let slice = input.as_slice();
    nbt::read(slice, limits, &mut terms)
        .map(|value| (nbt_atoms::compound(), value).encode(env))
        .map_err(nbt_error)
}

/// Read a disk NBT root (`Valimc.Native.dispatch/3` picks this or the dirty twin).
#[rustler::nif]
fn nbt_read<'a>(
    env: Env<'a>,
    input: Binary<'a>,
    bytes: usize,
    nodes: i64,
    depth: u32,
) -> Result<Term<'a>, Atom> {
    read_nbt(env, input, bytes, nodes, depth)
}

/// `nbt_read` on a dirty CPU scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn nbt_read_dirty<'a>(
    env: Env<'a>,
    input: Binary<'a>,
    bytes: usize,
    nodes: i64,
    depth: u32,
) -> Result<Term<'a>, Atom> {
    read_nbt(env, input, bytes, nodes, depth)
}

// ---- LZ4 region chunks (VMC-021) ----

mod lz4_atoms {
    rustler::atoms! { truncated_compression, invalid_compression, nbt_byte_limit }
}

fn lz4_decode<'a>(env: Env<'a>, input: Binary<'a>, max: usize) -> Result<Binary<'a>, Atom> {
    match valimc_core::lz4::decode_stream(input.as_slice(), max) {
        Ok(decoded) => Ok(bytes(env, decoded)),
        Err(valimc_core::lz4::Lz4Error::Truncated) => Err(lz4_atoms::truncated_compression()),
        Err(valimc_core::lz4::Lz4Error::Corrupt) => Err(lz4_atoms::invalid_compression()),
        Err(valimc_core::lz4::Lz4Error::Limit) => Err(lz4_atoms::nbt_byte_limit()),
    }
}

/// Decode an LZ4 block stream (`Valimc.Native.dispatch/3` picks this or the
/// dirty twin).
#[rustler::nif]
fn lz4_decode_stream<'a>(env: Env<'a>, input: Binary<'a>, max: usize) -> Result<Binary<'a>, Atom> {
    lz4_decode(env, input, max)
}

/// `lz4_decode_stream` on a dirty CPU scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn lz4_decode_stream_dirty<'a>(
    env: Env<'a>,
    input: Binary<'a>,
    max: usize,
) -> Result<Binary<'a>, Atom> {
    lz4_decode(env, input, max)
}

// ---- Imported columns (VMC-021b) ----

/// One section as imported: block palette, packed data, bits; biome palette, data, bits.
pub(crate) type SectionSpec<'a> = (Vec<u16>, Binary<'a>, u32, Vec<u16>, Binary<'a>, u32);

pub(crate) fn imported_column(
    sections: &[SectionSpec],
) -> Result<valimc_core::column::Column, Atom> {
    use valimc_core::column::{Column, SECTIONS};
    use valimc_core::section::Biomes;
    if sections.len() != SECTIONS {
        return Err(atoms::invalid_y());
    }
    let mut storages = Vec::with_capacity(SECTIONS);
    let mut biomes = Vec::with_capacity(SECTIONS);
    for (palette, data, bits, biome_palette, biome_data, biome_bits) in sections {
        storages.push(
            Storage::from_palette(palette, data.as_slice(), *bits).ok_or(atoms::invalid_layers())?,
        );
        biomes.push(
            Biomes::from_palette(biome_palette, biome_data.as_slice(), *biome_bits)
                .ok_or(atoms::invalid_layers())?,
        );
    }
    Ok(Column {
        sections: storages,
        biomes: Some(biomes),
    })
}

/// The column image of 24 imported sections, without a region (imports).
#[rustler::nif]
fn column_image_of<'a>(env: Env<'a>, sections: Vec<SectionSpec>) -> Result<Binary<'a>, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    let column = imported_column(&sections)?;
    let mut valid = true;
    for storage in &column.sections {
        storage.for_each(|_, state| valid &= flags.valid(state as u32));
    }
    if !valid {
        return Err(atoms::invalid_state());
    }
    Ok(bytes(env, column.to_image()))
}

/// The column image of a flat world's chunk (VMC-028b): every column holds
/// `layers` (384 big-endian states from the bottom), its biome `biome`.
#[rustler::nif]
fn column_layers_image<'a>(
    env: Env<'a>,
    layers: Binary<'a>,
    biome: u16,
) -> Result<Binary<'a>, Atom> {
    let flags = FLAGS.get().ok_or(atoms::flags_missing())?;
    if layers.len() != HEIGHT * 2 {
        return Err(atoms::invalid_layers());
    }
    let mut states = [0u16; HEIGHT];
    for (state, bytes) in states.iter_mut().zip(layers.as_slice().as_chunks::<2>().0) {
        *state = u16::from_be_bytes(*bytes);
        if !flags.valid(*state as u32) {
            return Err(atoms::invalid_state());
        }
    }
    let mut column = valimc_core::column::Column::from_layers(&states);
    column.biomes = Some(vec![
        valimc_core::section::Biomes::Single(biome);
        valimc_core::column::SECTIONS
    ]);
    Ok(bytes(env, column.to_image()))
}

/// Vanilla paletted storage of big-endian u16 `values` (export, VMC-021e3): the
/// palette and the packed longs as a big-endian binary.
#[rustler::nif]
fn pack_paletted<'a>(env: Env<'a>, values: Binary<'a>, min_bits: u32) -> Result<Term<'a>, Atom> {
    if !values.len().is_multiple_of(2) {
        return Err(atoms::invalid_layers());
    }
    let values: Vec<u16> = values
        .as_slice()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|b| u16::from_be_bytes(*b))
        .collect();
    let (palette, longs) =
        valimc_core::section::pack_vanilla(&values, min_bits).ok_or(atoms::invalid_layers())?;
    let mut data = NewBinary::new(env, longs.len() * 8);
    for (bytes, long) in data
        .as_mut_slice()
        .as_chunks_mut::<8>()
        .0
        .iter_mut()
        .zip(&longs)
    {
        *bytes = long.to_be_bytes();
    }
    Ok((palette, Binary::from(data)).encode(env))
}
