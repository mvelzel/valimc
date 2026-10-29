//! BEAM terms to and from `valimc_core::mobs::term::Value` (VMC-081d): the
//! terms native mob records are made of. Decoding copies binaries, borrows
//! the static text of atoms records use (`KNOWN_ATOMS`, so a record's keys
//! allocate nothing), reads tuples in place and keeps maps in Erlang's key
//! order (small BEAM maps already iterate in it). Anything without a typed
//! variant (a bignum, pid, reference, fun, port, bitstring or improper list)
//! travels as its external term format and is rebuilt as it came.

use rustler::sys::{self, ErlNifCharEncoding, ERL_NIF_TERM};
use rustler::types::map::MapIterator;
use rustler::{Binary, Encoder, Env, NifResult, Term, TermType};
use valimc_core::mobs::term::{known_atom, Atom, Map, Value};

/// The value of `term`.
pub fn decode(term: Term) -> NifResult<Value> {
    Ok(match term.get_type() {
        TermType::Atom => match atom_of(term) {
            Some(atom) => Value::Atom(atom),
            None => opaque(term),
        },
        TermType::Integer => match term.decode::<i64>() {
            Ok(i) => Value::Int(i),
            Err(_) => opaque(term),
        },
        TermType::Float => Value::Float(term.decode::<f64>()?),
        TermType::Binary => match term.decode::<Binary>() {
            Ok(binary) => Value::Binary(binary.as_slice().to_vec()),
            // A bitstring.
            Err(_) => opaque(term),
        },
        TermType::List => match term.list_length() {
            Ok(len) => {
                let mut items = Vec::with_capacity(len);
                for item in term.into_list_iterator()? {
                    items.push(decode(item)?);
                }
                Value::List(items)
            }
            // An improper list.
            Err(_) => opaque(term),
        },
        TermType::Tuple => {
            let env = term.get_env();
            let items = tuple_items(term)?;
            let mut values = Vec::with_capacity(items.len());
            for &item in items {
                values.push(decode(unsafe { Term::new(env, item) })?);
            }
            Value::Tuple(values)
        }
        TermType::Map => {
            let mut pairs = Vec::with_capacity(term.map_size()?);
            for (key, value) in MapIterator::new(term).ok_or(rustler::Error::BadArg)? {
                pairs.push((decode(key)?, decode(value)?));
            }
            Value::Map(Map::from_pairs(pairs).ok_or(rustler::Error::BadArg)?)
        }
        _ => opaque(term),
    })
}

/// The term of `value` in `env`.
pub fn encode<'a>(env: Env<'a>, value: &Value) -> NifResult<Term<'a>> {
    Ok(match value {
        Value::Atom(atom) => rustler::Atom::from_str(env, atom.as_str())?.to_term(env),
        Value::Int(i) => i.encode(env),
        Value::Float(f) => f.encode(env),
        Value::Binary(bytes) => crate::binary(env, bytes).encode(env),
        Value::List(items) => {
            let terms = encode_all(env, items.iter())?;
            unsafe {
                Term::new(
                    env,
                    sys::enif_make_list_from_array(
                        env.as_c_arg(),
                        terms.as_ptr(),
                        terms.len() as u32,
                    ),
                )
            }
        }
        Value::Tuple(items) => {
            let terms = encode_all(env, items.iter())?;
            unsafe {
                Term::new(
                    env,
                    sys::enif_make_tuple_from_array(
                        env.as_c_arg(),
                        terms.as_ptr(),
                        terms.len() as u32,
                    ),
                )
            }
        }
        Value::Map(map) => {
            let keys = encode_all(env, map.keys())?;
            let values = encode_all(env, map.iter().map(|(_, v)| v))?;
            let mut out: ERL_NIF_TERM = 0;
            let made = unsafe {
                sys::enif_make_map_from_arrays(
                    env.as_c_arg(),
                    keys.as_ptr(),
                    values.as_ptr(),
                    keys.len(),
                    &mut out,
                )
            };
            if made == 0 {
                return Err(rustler::Error::BadArg);
            }
            unsafe { Term::new(env, out) }
        }
        Value::Opaque(etf) => env.binary_to_term(etf).ok_or(rustler::Error::BadArg)?.0,
    })
}

fn encode_all<'v>(
    env: Env,
    values: impl ExactSizeIterator<Item = &'v Value>,
) -> NifResult<Vec<ERL_NIF_TERM>> {
    let mut terms = Vec::with_capacity(values.len());
    for value in values {
        terms.push(encode(env, value)?.as_c_arg());
    }
    Ok(terms)
}

// An atom's name: the static text of a known one, else owned; `None` for
// one outside Latin-1 (NIF 2.15 reads no other), which travels opaque.
fn atom_of(term: Term) -> Option<Atom> {
    let env = term.get_env().as_c_arg();
    let mut len: u32 = 0;
    let latin1 = ErlNifCharEncoding::ERL_NIF_LATIN1;
    if unsafe { sys::enif_get_atom_length(env, term.as_c_arg(), &mut len, latin1) } == 0 {
        return None;
    }
    let mut stack = [0u8; 256];
    let mut heap = Vec::new();
    let buffer: &mut [u8] = if (len as usize) < stack.len() {
        &mut stack
    } else {
        heap.resize(len as usize + 1, 0);
        &mut heap
    };
    let written =
        unsafe { sys::enif_get_atom(env, term.as_c_arg(), buffer.as_mut_ptr(), len + 1, latin1) };
    if written == 0 {
        return None;
    }
    let bytes = &buffer[..len as usize];
    Some(match std::str::from_utf8(bytes) {
        Ok(name) => match known_atom(name) {
            Some(known) => Atom::from_static(known),
            None => Atom::new(name),
        },
        // Latin-1 past ASCII.
        Err(_) => Atom::new(&bytes.iter().map(|&b| char::from(b)).collect::<String>()),
    })
}

fn tuple_items<'a>(term: Term<'a>) -> NifResult<&'a [ERL_NIF_TERM]> {
    let mut arity = 0;
    let mut array: *const ERL_NIF_TERM = std::ptr::null();
    let ok = unsafe {
        sys::enif_get_tuple(
            term.get_env().as_c_arg(),
            term.as_c_arg(),
            &mut arity,
            &mut array,
        )
    };
    if ok == 0 {
        return Err(rustler::Error::BadArg);
    }
    if arity == 0 {
        return Ok(&[]);
    }
    // The tuple's elements live as long as the term.
    Ok(unsafe { std::slice::from_raw_parts(array, arity as usize) })
}

fn opaque(term: Term) -> Value {
    Value::Opaque(term.to_binary().as_slice().into())
}
