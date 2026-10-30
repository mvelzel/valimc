//! Loot tables. Evaluating one takes microseconds, so it runs on a normal
//! scheduler in the region owner.

use crate::codec::nbt_atoms;
use crate::worldgen::json_of;
use crate::{binary, reply};
use rustler::{Atom, Encoder, Env, NifResult, ResourceArc, Term};

mod atoms {
    rustler::atoms! { unknown_loot_table }
}

// ---- Container loot tables (VMC-072a) ----

pub struct LootRegistry {
    pub(crate) loot: std::sync::Arc<valimc_core::loot::Loot>,
}

#[rustler::resource_impl]
impl rustler::Resource for LootRegistry {}

/// Parse the loot facts (`priv/loot/tables.json`, `registries.json`); facts it
/// cannot evaluate raise.
#[rustler::nif(schedule = "DirtyCpu")]
fn loot_registry(tables: Term, registries: Term) -> NifResult<(Atom, ResourceArc<LootRegistry>)> {
    reply((|| {
        let loot = valimc_core::loot::Loot::parse(&json_of(tables)?, &json_of(registries)?)?;
        Ok(ResourceArc::new(LootRegistry {
            loot: std::sync::Arc::new(loot),
        }))
    })())
}

/// `{:error, :unknown_loot_table}` unless the facts hold `table` (a world's
/// block entity may name any).
fn known(registry: &LootRegistry, table: &str) -> NifResult<()> {
    if registry.loot.has_table(table) {
        Ok(())
    } else {
        Err(rustler::Error::Term(Box::new(atoms::unknown_loot_table())))
    }
}

/// What a table may ask the world, answered up front: the biome at the loot
/// origin, the structure a map search finds (for any destination) and the
/// next free map id.
struct LootAnswers {
    biome: Option<String>,
    structure: Option<[i32; 3]>,
    next_map: i32,
}

impl valimc_core::loot::LootWorld for LootAnswers {
    fn biome(&mut self, _pos: [i32; 3]) -> Option<String> {
        self.biome.clone()
    }
    fn map_structure(
        &mut self,
        _tag: Option<&str>,
        _structures: &[String],
        _origin: [i32; 3],
        _radius: i32,
        _skip_existing: bool,
    ) -> Option<[i32; 3]> {
        self.structure
    }
    fn new_map(&mut self, _x: i32, _z: i32, _scale: i32) -> i32 {
        let id = self.next_map;
        self.next_map += 1;
        id
    }
}

/// A `Valimc.NBT` term.
fn nbt_term<'a>(env: Env<'a>, kind: Atom, value: Term<'a>) -> Term<'a> {
    (kind, value).encode(env)
}

fn nbt_compound<'a>(env: Env<'a>, fields: Vec<(&str, Term<'a>)>) -> Term<'a> {
    let map = fields.into_iter().fold(Term::map_new(env), |map, (k, v)| {
        map.map_put(binary(env, k.as_bytes()).encode(env), v)
            .expect("map")
    });
    nbt_term(env, nbt_atoms::compound(), map)
}

fn nbt_string<'a>(env: Env<'a>, s: &str) -> Term<'a> {
    nbt_term(
        env,
        nbt_atoms::string(),
        binary(env, s.as_bytes()).encode(env),
    )
}

fn nbt_int<'a>(env: Env<'a>, n: i32) -> Term<'a> {
    nbt_term(env, nbt_atoms::int(), n.encode(env))
}

/// A text component's JSON as NBT: objects as compounds, strings, booleans
/// as bytes, integers as ints, other numbers as doubles, lists.
fn json_nbt<'a>(env: Env<'a>, json: &valimc_core::worldgen::json::Json) -> Term<'a> {
    use valimc_core::worldgen::json::Json;
    match json {
        Json::Object(fields) => nbt_compound(
            env,
            fields
                .iter()
                .map(|(k, v)| (k.as_str(), json_nbt(env, v)))
                .collect(),
        ),
        Json::String(s) => nbt_string(env, s),
        Json::Bool(b) => nbt_term(env, nbt_atoms::byte(), (*b as i32).encode(env)),
        Json::Number(n) if n.fract() == 0.0 && n.abs() < 2_147_483_648.0 => nbt_int(env, *n as i32),
        Json::Number(n) => nbt_term(
            env,
            nbt_atoms::double(),
            binary(env, &n.to_be_bytes()).encode(env),
        ),
        Json::Array(items) => {
            let tags: Vec<Term<'a>> = items.iter().map(|i| json_nbt(env, i)).collect();
            list_term(env, tags)
        }
        Json::Null => nbt_compound(env, Vec::new()),
    }
}

/// `Valimc.NBT.list/1` of tagged terms: one element type, values unwrapped.
fn list_term<'a>(env: Env<'a>, tags: Vec<Term<'a>>) -> Term<'a> {
    if tags.is_empty() {
        return nbt_term(
            env,
            nbt_atoms::list(),
            (nbt_atoms::end_(), Vec::<Term>::new()).encode(env),
        );
    }
    let mut kind = None;
    let mut values = Vec::with_capacity(tags.len());
    for tag in tags {
        let (k, v): (Atom, Term<'a>) = tag.decode().expect("tagged term");
        kind = Some(k);
        values.push(v);
    }
    nbt_term(
        env,
        nbt_atoms::list(),
        (kind.expect("a kind"), values).encode(env),
    )
}

/// A loot stack as an item tag (`{id, count, components}` as world files
/// store it).
fn loot_stack<'a>(env: Env<'a>, stack: &valimc_core::loot::Stack) -> Term<'a> {
    let mut components: Vec<(&str, Term<'a>)> = Vec::new();
    let levels = |list: &Vec<(String, i32)>| {
        nbt_compound(
            env,
            list.iter()
                .map(|(e, l)| (e.as_str(), nbt_int(env, *l)))
                .collect(),
        )
    };
    if !stack.enchantments.is_empty() {
        components.push(("minecraft:enchantments", levels(&stack.enchantments)));
    }
    if !stack.stored_enchantments.is_empty() {
        components.push((
            "minecraft:stored_enchantments",
            levels(&stack.stored_enchantments),
        ));
    }
    if stack.damage != 0 {
        components.push(("minecraft:damage", nbt_int(env, stack.damage)));
    }
    if let Some(p) = &stack.potion {
        components.push((
            "minecraft:potion_contents",
            nbt_compound(env, vec![("potion", nbt_string(env, p))]),
        ));
    }
    if !stack.stew_effects.is_empty() {
        let entries = stack
            .stew_effects
            .iter()
            .map(|(e, d)| {
                let mut fields = vec![("id", nbt_string(env, e))];
                if *d != 160 {
                    fields.push(("duration", nbt_int(env, *d)));
                }
                nbt_compound(env, fields)
            })
            .collect();
        components.push(("minecraft:suspicious_stew_effects", list_term(env, entries)));
    }
    if let Some(i) = &stack.instrument {
        components.push(("minecraft:instrument", nbt_string(env, i)));
    }
    if let Some(a) = stack.ominous_amplifier {
        components.push(("minecraft:ominous_bottle_amplifier", nbt_int(env, a)));
    }
    if let Some(n) = &stack.item_name {
        components.push(("minecraft:item_name", json_nbt(env, n)));
    }
    if let Some(n) = &stack.custom_name {
        components.push(("minecraft:custom_name", json_nbt(env, n)));
    }
    if let Some(id) = stack.map_id {
        components.push(("minecraft:map_id", nbt_int(env, id)));
    }
    if !stack.map_decorations.is_empty() {
        let entries = stack
            .map_decorations
            .iter()
            .map(|(key, kind, x, z, rotation)| {
                (
                    key.as_str(),
                    nbt_compound(
                        env,
                        vec![
                            ("type", nbt_string(env, kind)),
                            (
                                "x",
                                nbt_term(
                                    env,
                                    nbt_atoms::double(),
                                    binary(env, &x.to_be_bytes()).encode(env),
                                ),
                            ),
                            (
                                "z",
                                nbt_term(
                                    env,
                                    nbt_atoms::double(),
                                    binary(env, &z.to_be_bytes()).encode(env),
                                ),
                            ),
                            (
                                "rotation",
                                nbt_term(
                                    env,
                                    nbt_atoms::float(),
                                    binary(env, &rotation.to_be_bytes()).encode(env),
                                ),
                            ),
                        ],
                    ),
                )
            })
            .collect();
        components.push(("minecraft:map_decorations", nbt_compound(env, entries)));
    }
    if !stack.block_state.is_empty() {
        components.push((
            "minecraft:block_state",
            nbt_compound(
                env,
                stack
                    .block_state
                    .iter()
                    .map(|(k, v)| (k.as_str(), nbt_string(env, v)))
                    .collect(),
            ),
        ));
    }
    let mut fields = vec![
        ("id", nbt_string(env, &stack.item)),
        ("count", nbt_int(env, stack.count)),
    ];
    if !components.is_empty() {
        fields.push(("components", nbt_compound(env, components)));
    }
    nbt_compound(env, fields)
}

fn loot_random(seed: i64) -> valimc_core::worldgen::random::Random {
    valimc_core::worldgen::random::Random::legacy(seed)
}

/// `LootTable.fill` of an empty container with `size` slots and a stored
/// seed: the slots (item tags or nil) and the next free map id.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn loot_fill<'a>(
    env: Env<'a>,
    registry: ResourceArc<LootRegistry>,
    table: String,
    seed: i64,
    luck: f64,
    origin: (f64, f64, f64),
    size: usize,
    biome: Option<String>,
    structure: Option<(i32, i32, i32)>,
    next_map: i32,
) -> NifResult<(Atom, (Vec<Term<'a>>, i32))> {
    known(&registry, &table)?;
    let mut world = LootAnswers {
        biome,
        structure: structure.map(|(x, y, z)| [x, y, z]),
        next_map,
    };
    let slots = match registry.loot.fill(
        &table,
        loot_random(seed),
        luck as f32,
        [origin.0, origin.1, origin.2],
        size,
        &mut world,
    ) {
        Ok(slots) => slots,
        Err(message) => return reply(Err(message)),
    };
    let terms = slots
        .iter()
        .map(|slot| match slot {
            Some(stack) => loot_stack(env, stack),
            None => rustler::types::atom::nil().encode(env),
        })
        .collect();
    reply(Ok((terms, world.next_map)))
}

/// `LootTable.getRandomItems` with a stored seed (brushable blocks): the item
/// tags and the next free map id.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn loot_items<'a>(
    env: Env<'a>,
    registry: ResourceArc<LootRegistry>,
    table: String,
    seed: i64,
    luck: f64,
    origin: (f64, f64, f64),
    biome: Option<String>,
    structure: Option<(i32, i32, i32)>,
    next_map: i32,
) -> NifResult<(Atom, (Vec<Term<'a>>, i32))> {
    known(&registry, &table)?;
    let mut world = LootAnswers {
        biome,
        structure: structure.map(|(x, y, z)| [x, y, z]),
        next_map,
    };
    reply(
        registry
            .loot
            .items(
                &table,
                loot_random(seed),
                luck as f32,
                [origin.0, origin.1, origin.2],
                &mut world,
            )
            .map(|items| {
                (
                    items.iter().map(|s| loot_stack(env, s)).collect(),
                    world.next_map,
                )
            }),
    )
}

/// A mob's spawn equipment enchanted by cost (`EnchantmentsByCostWithDifficulty`,
/// VMC-043b): `item` with its `enchantments`, the cost range `min` to
/// `min + span` and the special multiplier, over the enchantments of `tag`,
/// drawing from the 48-bit legacy random state `random`. The enchantments
/// after and the random's state.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn loot_enchant(
    registry: ResourceArc<LootRegistry>,
    item: String,
    enchantments: Vec<(String, i32)>,
    min: i32,
    span: i32,
    special: f64,
    tag: String,
    random: u64,
) -> NifResult<(Atom, (Vec<(String, i32)>, u64))> {
    let mut random = valimc_core::worldgen::random::Random::legacy_at(random);
    reply(
        registry
            .loot
            .enchant_by_cost(
                &item,
                &enchantments,
                min,
                span,
                special as f32,
                &tag,
                &mut random,
            )
            .map(|list| (list, random.legacy_state().unwrap_or(0))),
    )
}

/// An entity's death drops (`LivingEntity.dropFromLootTable`, VMC-037n):
/// `death` is `{on_fire, baby, vehicle, killed_by_player, attacker,
/// direct_attacker, {properties, source}}`, each attacker `{type,
/// enchantments}` (its entity type or nil, its main-hand enchantments as
/// `[{id, level}]`) or nil, `properties` the entity's own as `[{name,
/// value}]` (VMC-043c). The item tags of the drops. A gift's or shearing's
/// table reads the same entity.
type DeathTerm = (
    bool,
    bool,
    Option<String>,
    bool,
    Option<(Option<String>, Vec<(String, i32)>)>,
    Option<(Option<String>, Vec<(String, i32)>)>,
    // The victim's properties, and the killing damage (VMC-043d): its type's
    // tags, its direct and source entities' types, whether they are one; or nil.
    (
        Vec<(String, String)>,
        Option<(Vec<String>, Option<String>, Option<String>, bool)>,
    ),
);

#[rustler::nif]
fn loot_entity<'a>(
    env: Env<'a>,
    registry: ResourceArc<LootRegistry>,
    table: String,
    seed: i64,
    luck: f64,
    origin: (f64, f64, f64),
    death: DeathTerm,
) -> NifResult<(Atom, Vec<Term<'a>>)> {
    known(&registry, &table)?;
    let (on_fire, baby, vehicle, killed_by_player, attacker, direct_attacker, (properties, source)) =
        death;
    let (attacker_type, attacker) = attacker.map_or((None, None), |(t, m)| (t, Some(m)));
    let (direct_attacker_type, direct_attacker) =
        direct_attacker.map_or((None, None), |(t, m)| (t, Some(m)));
    let mut world = LootAnswers {
        biome: None,
        structure: None,
        next_map: 0,
    };
    reply(
        registry
            .loot
            .entity_items(
                &table,
                loot_random(seed),
                luck as f32,
                [origin.0, origin.1, origin.2],
                valimc_core::loot::Death {
                    on_fire,
                    baby,
                    vehicle,
                    killed_by_player,
                    attacker,
                    direct_attacker,
                    attacker_type,
                    direct_attacker_type,
                    properties,
                    source: source.map(|(tags, direct, source, is_direct)| {
                        valimc_core::loot::DamageInfo {
                            tags,
                            direct,
                            source,
                            is_direct,
                            source_properties: Vec::new(),
                        }
                    }),
                },
                &mut world,
            )
            .map(|items| items.iter().map(|s| loot_stack(env, s)).collect()),
    )
}

/// A broken block's drops (`BlockBehaviour.getDrops`, VMC-029e): `block` is
/// `{name, properties, {tool, tool_enchantments}, entity, explosion_radius,
/// neighbours, dynamic}` with `properties` as `[{name, value}]`, the tool's
/// item (`minecraft:air` for an empty hand) and its `[{id, level}]` enchantments,
/// whether an entity broke it, an explosion's radius or nil, and the blocks a
/// location check may read as `[{{dx, dy, dz}, name, properties}]`, and the
/// dynamic drops as `[{name, [item]}]`. The item tags of the drops.
type BreakTerm = (
    String,
    Vec<(String, String)>,
    (String, Vec<(String, i32)>),
    bool,
    Option<f64>,
    Vec<((i32, i32, i32), String, Vec<(String, String)>)>,
    Vec<(String, Vec<String>)>,
);

#[rustler::nif]
fn loot_block<'a>(
    env: Env<'a>,
    registry: ResourceArc<LootRegistry>,
    table: String,
    seed: i64,
    origin: (f64, f64, f64),
    block: BreakTerm,
) -> NifResult<(Atom, Vec<Term<'a>>)> {
    known(&registry, &table)?;
    let (name, properties, (tool, tool_enchantments), entity, radius, neighbours, dynamic) = block;
    let mut world = LootAnswers {
        biome: None,
        structure: None,
        next_map: 0,
    };
    reply(
        registry
            .loot
            .block_items(
                &table,
                loot_random(seed),
                [origin.0, origin.1, origin.2],
                valimc_core::loot::BlockBreak {
                    block: name,
                    properties,
                    tool,
                    tool_enchantments,
                    entity,
                    explosion_radius: radius.map(|r| r as f32),
                    neighbours: neighbours
                        .into_iter()
                        .map(|((x, y, z), b, p)| ([x, y, z], b, p))
                        .collect(),
                    dynamic,
                },
                &mut world,
            )
            .map(|items| items.iter().map(|s| loot_stack(env, s)).collect()),
    )
}
