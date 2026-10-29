//! Erlang terms as mob records hold them (VMC-081d): a native mob is written
//! to the region log, checkpoints and handoffs as the very term
//! `Valimc.Entity.Store` writes for an Elixir one, so the codec
//! (`mobs::record`) builds and reads these values, and the NIF shim converts
//! them to and from BEAM terms (`valimc_nif::mob_term`).
//!
//! Everything a record holds has a variant: atoms, integers that fit an
//! `i64`, floats (their exact bits: `-0.0` stays apart from `0.0`, as OTP 27
//! keeps it), binaries, proper lists, tuples and maps; a struct is a map with
//! a `__struct__` atom key. Whatever else could occur (a bignum, a pid, a
//! reference, a fun, a bitstring or an improper list inside an opaque item
//! component or brain memory) is kept as its external term format bytes,
//! `Value::Opaque`, and written back as it came.
//!
//! A map keeps its pairs in a vector sorted by Erlang's term order of the
//! keys (the order `:maps.to_list/1` gives small maps and
//! `term_to_binary(_, [:deterministic])` writes), so lookups are binary
//! searches and iteration is deterministic.

use std::borrow::Cow;
use std::cmp::Ordering;
use std::fmt;

/// An atom's text. Atoms a record uses are static (`Atom::from_static`, and
/// the NIF interns decoded names against `KNOWN_ATOMS`); others own theirs.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Atom(Cow<'static, str>);

impl Atom {
    /// An atom of static text (no allocation).
    pub const fn from_static(name: &'static str) -> Atom {
        Atom(Cow::Borrowed(name))
    }

    /// An atom of `name`, borrowing the static text of a known atom.
    pub fn new(name: &str) -> Atom {
        match known_atom(name) {
            Some(known) => Atom(Cow::Borrowed(known)),
            None => Atom(Cow::Owned(name.to_owned())),
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for Atom {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, ":{}", self.0)
    }
}

/// The static text of `name` if a record may use it (binary search).
pub fn known_atom(name: &str) -> Option<&'static str> {
    KNOWN_ATOMS
        .binary_search(&name)
        .ok()
        .map(|index| KNOWN_ATOMS[index])
}

/// Atoms records use, sorted: decoded names among these are borrowed rather
/// than allocated. Missing ones still work (owned).
pub const KNOWN_ATOMS: &[&str] = &[
    "Elixir.MapSet",
    "Elixir.Valimc.Entity.MobMotion",
    "Elixir.Valimc.Protocol.ItemStack",
    "__struct__",
    "absorption",
    "age",
    "age_locked",
    "ai",
    "air_supply",
    "anchor",
    "attach_face",
    "attributes",
    "baby",
    "base",
    "beam",
    "body",
    "brain",
    "can_break_doors",
    "can_pick_up_loot",
    "cannot_be_hunted",
    "cannot_hunt",
    "carried",
    "charging",
    "chest",
    "chunk_generation",
    "circle",
    "climbing",
    "collar",
    "color",
    "command",
    "components",
    "control",
    "conversion",
    "converting",
    "count",
    "creepy",
    "crouching",
    "cure",
    "cure_by",
    "custom_name",
    "dancing",
    "dark",
    "data",
    "death_ticks",
    "death_time",
    "despawn_delay",
    "dolphin",
    "drinking",
    "drop_chances",
    "duration",
    "effects",
    "equipment",
    "eye",
    "eye_water",
    "fall_distance",
    "false",
    "feet",
    "finalize",
    "finalized",
    "fire_ticks",
    "fish",
    "float",
    "flying",
    "forced_age",
    "forward",
    "from_bucket",
    "frozen_ticks",
    "got_fish",
    "ground",
    "guardian",
    "has_egg",
    "head",
    "heal_cooldown",
    "health",
    "hold",
    "home",
    "hop",
    "hops",
    "horizontal_collision",
    "hurt_by_player",
    "hurt_ticks",
    "ignited",
    "immune",
    "impulse",
    "in_love",
    "in_snow",
    "in_water",
    "invisible",
    "item_id",
    "jockey",
    "jump",
    "jumped",
    "jumping",
    "kind",
    "knot",
    "lava",
    "laying_egg",
    "leash",
    "left_handed",
    "legs",
    "level",
    "life",
    "living",
    "love_cause",
    "lying",
    "main_hand",
    "mainhand",
    "map",
    "max_swell",
    "memories",
    "mob",
    "modifiers",
    "moistness",
    "more_carrots",
    "motion",
    "move_dist",
    "move_to",
    "moving",
    "natural",
    "nav_speed",
    "next_speed",
    "next_step",
    "nil",
    "no_ai",
    "no_gravity",
    "no_jump_delay",
    "off_hand",
    "offhand",
    "on_ground",
    "path_up",
    "peek",
    "peek_amount",
    "persistent",
    "phase",
    "player",
    "player_created",
    "player_memory",
    "playing_dead",
    "point",
    "portal_cooldown",
    "powder_snow",
    "power",
    "powered",
    "pre_move",
    "preserved",
    "profession",
    "puff",
    "radius",
    "random",
    "relax",
    "removed",
    "resting",
    "rise",
    "rotation",
    "saddle",
    "searching",
    "set",
    "sheared",
    "sitting",
    "sitting_damage",
    "size",
    "sleeping",
    "sound_variant",
    "spawner",
    "special",
    "speed",
    "squid",
    "stared_at",
    "started",
    "stew",
    "strafe",
    "stuck_multiplier",
    "suffocating",
    "support",
    "swell",
    "swell_dir",
    "swimming",
    "tame",
    "target_time",
    "ticks",
    "time_in_overworld",
    "travel",
    "treasure",
    "true",
    "type",
    "unhappy",
    "up",
    "using",
    "uuid",
    "variant",
    "velocity",
    "vertical_collision",
    "villager",
    "villager_type",
    "wait",
    "wander_target",
    "wanted",
    "was_on_ground",
    "water",
    "x",
    "xp",
    "y",
    "z",
];

/// An Erlang term a record holds.
#[derive(Clone)]
pub enum Value {
    Atom(Atom),
    Int(i64),
    Float(f64),
    Binary(Vec<u8>),
    /// A proper list.
    List(Vec<Value>),
    Tuple(Vec<Value>),
    Map(Map),
    /// Any other term, as `term_to_binary/1` writes it (leading 131 included).
    Opaque(Box<[u8]>),
}

pub const NIL: Value = Value::Atom(Atom::from_static("nil"));
pub const TRUE: Value = Value::Atom(Atom::from_static("true"));
pub const FALSE: Value = Value::Atom(Atom::from_static("false"));

impl Value {
    pub const fn atom(name: &'static str) -> Value {
        Value::Atom(Atom::from_static(name))
    }

    pub fn bool(value: bool) -> Value {
        if value {
            TRUE
        } else {
            FALSE
        }
    }

    pub fn tuple<const N: usize>(items: [Value; N]) -> Value {
        Value::Tuple(items.into())
    }

    /// `{x, y, z}` of floats.
    pub fn vec3(v: [f64; 3]) -> Value {
        Value::tuple([Value::Float(v[0]), Value::Float(v[1]), Value::Float(v[2])])
    }

    /// `{x, y, z}` of integers.
    pub fn ivec3(v: [i64; 3]) -> Value {
        Value::tuple([Value::Int(v[0]), Value::Int(v[1]), Value::Int(v[2])])
    }

    /// `value` or nil.
    pub fn or_nil<T>(value: Option<T>, f: impl FnOnce(T) -> Value) -> Value {
        value.map_or(NIL, f)
    }

    pub fn is_nil(&self) -> bool {
        self.is_atom("nil")
    }

    pub fn is_atom(&self, name: &str) -> bool {
        matches!(self, Value::Atom(a) if a.as_str() == name)
    }

    /// Elixir truthiness: anything but nil and false.
    pub fn truthy(&self) -> bool {
        !(self.is_nil() || self.is_atom("false"))
    }

    pub fn as_atom(&self) -> Option<&Atom> {
        match self {
            Value::Atom(a) => Some(a),
            _ => None,
        }
    }

    /// `is_boolean`.
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Atom(a) if a.as_str() == "true" => Some(true),
            Value::Atom(a) if a.as_str() == "false" => Some(false),
            _ => None,
        }
    }

    /// `is_integer` (within an `i64`).
    pub fn as_int(&self) -> Option<i64> {
        match self {
            Value::Int(i) => Some(*i),
            _ => None,
        }
    }

    /// `is_float`.
    pub fn as_float(&self) -> Option<f64> {
        match self {
            Value::Float(f) => Some(*f),
            _ => None,
        }
    }

    /// `is_number`, as a double.
    pub fn as_number(&self) -> Option<f64> {
        match self {
            Value::Int(i) => Some(*i as f64),
            Value::Float(f) => Some(*f),
            _ => None,
        }
    }

    pub fn as_binary(&self) -> Option<&[u8]> {
        match self {
            Value::Binary(b) => Some(b),
            _ => None,
        }
    }

    pub fn as_list(&self) -> Option<&[Value]> {
        match self {
            Value::List(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_tuple(&self) -> Option<&[Value]> {
        match self {
            Value::Tuple(items) => Some(items),
            _ => None,
        }
    }

    /// A tuple of exactly `N` elements.
    pub fn as_tuple_n<const N: usize>(&self) -> Option<&[Value; N]> {
        self.as_tuple().and_then(|items| items.try_into().ok())
    }

    pub fn as_map(&self) -> Option<&Map> {
        match self {
            Value::Map(m) => Some(m),
            _ => None,
        }
    }

    /// `{x, y, z}` of floats (`vector?`).
    pub fn as_vec3(&self) -> Option<[f64; 3]> {
        let [x, y, z] = self.as_tuple_n::<3>()?;
        Some([x.as_float()?, y.as_float()?, z.as_float()?])
    }

    /// `{x, y, z}` of integers.
    pub fn as_ivec3(&self) -> Option<[i64; 3]> {
        let [x, y, z] = self.as_tuple_n::<3>()?;
        Some([x.as_int()?, y.as_int()?, z.as_int()?])
    }

    /// The struct module of a struct map (`__struct__`).
    pub fn struct_name(&self) -> Option<&str> {
        self.as_map()?
            .get_atom("__struct__")
            .and_then(Value::as_atom)
            .map(Atom::as_str)
    }

    /// Whether this is a `%module{}` struct (`is_struct/2`).
    pub fn is_struct(&self, module: &str) -> bool {
        self.struct_name() == Some(module)
    }

    /// Erlang's term class rank (number < atom < reference < fun < port <
    /// pid < tuple < map < nil < list < bitstring).
    fn class(&self) -> u8 {
        match self {
            Value::Int(_) | Value::Float(_) => 0,
            Value::Atom(_) => 1,
            Value::Tuple(_) => 6,
            Value::Map(_) => 7,
            Value::List(items) if items.is_empty() => 8,
            Value::List(_) => 9,
            Value::Binary(_) => 10,
            Value::Opaque(etf) => opaque_class(etf),
        }
    }
}

// The class of an opaque term from its external format tag.
fn opaque_class(etf: &[u8]) -> u8 {
    match etf.get(1) {
        // SMALL_BIG_EXT, LARGE_BIG_EXT.
        Some(110 | 111) => 0,
        // REFERENCE_EXT, NEW_REFERENCE_EXT, NEWER_REFERENCE_EXT.
        Some(101 | 114 | 90) => 2,
        // FUN_EXT, NEW_FUN_EXT, EXPORT_EXT.
        Some(117 | 112 | 113) => 3,
        // PORT_EXT, NEW_PORT_EXT, V4_PORT_EXT.
        Some(102 | 89 | 120) => 4,
        // PID_EXT, NEW_PID_EXT.
        Some(103 | 88) => 5,
        // LIST_EXT (an improper list).
        Some(108) => 9,
        // BIT_BINARY_EXT and anything else.
        _ => 10,
    }
}

impl PartialEq for Value {
    /// Exact equality (`=:=`): floats by their bits, so `0.0 != -0.0` and
    /// `1 != 1.0`.
    fn eq(&self, other: &Value) -> bool {
        match (self, other) {
            (Value::Atom(a), Value::Atom(b)) => a == b,
            (Value::Int(a), Value::Int(b)) => a == b,
            (Value::Float(a), Value::Float(b)) => a.to_bits() == b.to_bits(),
            (Value::Binary(a), Value::Binary(b)) => a == b,
            (Value::List(a), Value::List(b)) => a == b,
            (Value::Tuple(a), Value::Tuple(b)) => a == b,
            (Value::Map(a), Value::Map(b)) => a == b,
            (Value::Opaque(a), Value::Opaque(b)) => a == b,
            _ => false,
        }
    }
}

impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::Atom(a) => a.fmt(f),
            Value::Int(i) => write!(f, "{i}"),
            Value::Float(x) => write!(f, "{x:?}"),
            Value::Binary(b) => match std::str::from_utf8(b) {
                Ok(s) => write!(f, "{s:?}"),
                Err(_) => write!(f, "<<{b:?}>>"),
            },
            Value::List(items) => f.debug_list().entries(items).finish(),
            Value::Tuple(items) => {
                write!(f, "{{")?;
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        write!(f, ", ")?;
                    }
                    item.fmt(f)?;
                }
                write!(f, "}}")
            }
            Value::Map(m) => f.debug_map().entries(m.iter()).finish(),
            Value::Opaque(etf) => write!(f, "#Opaque<{etf:?}>"),
        }
    }
}

/// Erlang's exact term order (the order of map keys): numbers by value, an
/// integer before an equal float; atoms by their text; tuples by size, then
/// elements; maps by size, then keys, then values; lists element by element;
/// binaries byte by byte. Opaque terms of one class compare by their bytes,
/// which only orders them deterministically.
pub fn compare(a: &Value, b: &Value) -> Ordering {
    let (ca, cb) = (a.class(), b.class());
    if ca != cb {
        return ca.cmp(&cb);
    }
    match (a, b) {
        (Value::Int(x), Value::Int(y)) => x.cmp(y),
        (Value::Float(x), Value::Float(y)) => compare_floats(*x, *y),
        (Value::Int(x), Value::Float(y)) => compare_int_float(*x, *y).then(Ordering::Less),
        (Value::Float(x), Value::Int(y)) => {
            compare_int_float(*y, *x).reverse().then(Ordering::Greater)
        }
        (Value::Atom(x), Value::Atom(y)) => x.as_str().as_bytes().cmp(y.as_str().as_bytes()),
        (Value::Tuple(x), Value::Tuple(y)) => x.len().cmp(&y.len()).then_with(|| compare_seq(x, y)),
        (Value::Map(x), Value::Map(y)) => x.len().cmp(&y.len()).then_with(|| {
            let keys = x
                .iter()
                .zip(y.iter())
                .map(|((k1, _), (k2, _))| compare(k1, k2));
            let values = x
                .iter()
                .zip(y.iter())
                .map(|((_, v1), (_, v2))| compare(v1, v2));
            keys.chain(values)
                .find(|o| *o != Ordering::Equal)
                .unwrap_or(Ordering::Equal)
        }),
        (Value::List(x), Value::List(y)) => compare_seq(x, y).then(x.len().cmp(&y.len())),
        (Value::Binary(x), Value::Binary(y)) => x.cmp(y),
        (Value::Opaque(x), Value::Opaque(y)) => x.cmp(y),
        // Mixed number/opaque bignum, or other mixed members of one class.
        _ => {
            let rank = |v: &Value| match v {
                Value::Opaque(_) => 1,
                _ => 0,
            };
            rank(a).cmp(&rank(b))
        }
    }
}

fn compare_seq(x: &[Value], y: &[Value]) -> Ordering {
    x.iter()
        .zip(y)
        .map(|(a, b)| compare(a, b))
        .find(|o| *o != Ordering::Equal)
        .unwrap_or(Ordering::Equal)
}

// Erlang compares floats arithmetically: -0.0 equals 0.0. As map keys they
// are distinct, -0.0 first.
fn compare_floats(x: f64, y: f64) -> Ordering {
    x.partial_cmp(&y)
        .unwrap_or(Ordering::Equal)
        .then_with(|| x.is_sign_positive().cmp(&y.is_sign_positive()))
}

// An integer against a float by exact value.
fn compare_int_float(i: i64, f: f64) -> Ordering {
    const TWO_63: f64 = 9_223_372_036_854_775_808.0;
    if f >= TWO_63 {
        return Ordering::Less;
    }
    if f < -TWO_63 {
        return Ordering::Greater;
    }
    let whole = f.trunc();
    match i.cmp(&(whole as i64)) {
        Ordering::Equal => 0.0f64.partial_cmp(&(f - whole)).unwrap_or(Ordering::Equal),
        other => other,
    }
}

/// A map: pairs sorted by `compare` of their keys, keys unique.
#[derive(Clone, Default, PartialEq)]
pub struct Map(Vec<(Value, Value)>);

impl Map {
    pub fn new() -> Map {
        Map(Vec::new())
    }

    pub fn with_capacity(capacity: usize) -> Map {
        Map(Vec::with_capacity(capacity))
    }

    /// A map of `pairs` in any order; `None` if a key repeats.
    pub fn from_pairs(mut pairs: Vec<(Value, Value)>) -> Option<Map> {
        if !pairs
            .windows(2)
            .all(|w| compare(&w[0].0, &w[1].0) == Ordering::Less)
        {
            pairs.sort_by(|a, b| compare(&a.0, &b.0));
            if pairs
                .windows(2)
                .any(|w| compare(&w[0].0, &w[1].0) == Ordering::Equal)
            {
                return None;
            }
        }
        Some(Map(pairs))
    }

    /// A map of atom keys.
    pub fn from_atoms<const N: usize>(pairs: [(&'static str, Value); N]) -> Map {
        let pairs = pairs
            .into_iter()
            .map(|(k, v)| (Value::atom(k), v))
            .collect();
        Map::from_pairs(pairs).expect("distinct atom keys")
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn iter(&self) -> impl ExactSizeIterator<Item = (&Value, &Value)> {
        self.0.iter().map(|(k, v)| (k, v))
    }

    pub fn keys(&self) -> impl ExactSizeIterator<Item = &Value> {
        self.0.iter().map(|(k, _)| k)
    }

    pub fn into_pairs(self) -> Vec<(Value, Value)> {
        self.0
    }

    pub fn pairs(&self) -> &[(Value, Value)] {
        &self.0
    }

    fn find(&self, key: &Value) -> Result<usize, usize> {
        self.0.binary_search_by(|(k, _)| compare(k, key))
    }

    pub fn get(&self, key: &Value) -> Option<&Value> {
        self.find(key).ok().map(|i| &self.0[i].1)
    }

    /// The value of atom key `name`, without building the atom.
    pub fn get_atom(&self, name: &str) -> Option<&Value> {
        self.0
            .binary_search_by(|(k, _)| match k {
                Value::Atom(a) => a.as_str().as_bytes().cmp(name.as_bytes()),
                other => other.class().cmp(&1),
            })
            .ok()
            .map(|i| &self.0[i].1)
    }

    /// `Map.put/3`.
    pub fn insert(&mut self, key: Value, value: Value) {
        match self.find(&key) {
            Ok(i) => self.0[i].1 = value,
            Err(i) => self.0.insert(i, (key, value)),
        }
    }

    pub fn insert_atom(&mut self, key: &'static str, value: Value) {
        self.insert(Value::atom(key), value);
    }

    pub fn remove(&mut self, key: &Value) -> Option<Value> {
        self.find(key).ok().map(|i| self.0.remove(i).1)
    }
}

impl From<Map> for Value {
    fn from(map: Map) -> Value {
        Value::Map(map)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_atoms_are_sorted_and_unique() {
        assert!(KNOWN_ATOMS.windows(2).all(|w| w[0] < w[1]));
        assert_eq!(known_atom("mob"), Some("mob"));
        assert_eq!(known_atom("not_a_record_atom"), None);
    }

    #[test]
    fn term_order() {
        use Value::*;
        let ordered = [
            Int(-5),
            Float(-0.0),
            Float(0.0),
            Int(1),
            Float(1.0),
            Float(1.5),
            Int(2),
            Value::atom("a"),
            Value::atom("ab"),
            Value::atom("b"),
            Value::tuple([Int(9)]),
            Value::tuple([Int(1), Int(1)]),
            Value::Map(super::Map::from_atoms([("z", Int(1))])),
            Value::Map(super::Map::from_atoms([("a", Int(1)), ("b", Int(1))])),
            List(vec![]),
            List(vec![Int(1)]),
            List(vec![Int(1), Int(0)]),
            List(vec![Int(2)]),
            Binary(vec![]),
            Binary(vec![0]),
            Binary(vec![1]),
        ];
        for w in ordered.windows(2) {
            assert_eq!(compare(&w[0], &w[1]), Ordering::Less, "{w:?}");
            assert_eq!(compare(&w[1], &w[0]), Ordering::Greater, "{w:?}");
        }
        assert_eq!(
            compare_int_float(i64::MAX, 9_223_372_036_854_775_807.0),
            Ordering::Less
        );
    }

    #[test]
    fn maps_sort_and_find() {
        let map = Map::from_pairs(vec![
            (Value::atom("b"), Value::Int(2)),
            (Value::Binary(b"x".to_vec()), Value::Int(3)),
            (Value::atom("a"), Value::Int(1)),
            (Value::Int(7), Value::Int(0)),
        ])
        .unwrap();
        assert_eq!(map.get_atom("a"), Some(&Value::Int(1)));
        assert_eq!(map.get_atom("b"), Some(&Value::Int(2)));
        assert_eq!(map.get_atom("c"), None);
        assert_eq!(map.get(&Value::Binary(b"x".to_vec())), Some(&Value::Int(3)));
        assert_eq!(map.keys().next(), Some(&Value::Int(7)));
        assert!(Map::from_pairs(vec![(NIL, NIL), (NIL, TRUE)]).is_none());
        assert_ne!(Value::Float(0.0), Value::Float(-0.0));
        assert_ne!(Value::Int(1), Value::Float(1.0));
    }
}
