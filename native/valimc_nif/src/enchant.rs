//! The enchantment engine's hooks for players (VMC-037q,
//! `valimc_core::mobs::living::enchant`), over the installed living facts.
//! Each is a short pure fold. `random` is a legacy random's state; the
//! result carries the state after the hook's draws.

use rustler::types::atom::Atom;
use rustler::{Encoder, Env, NifMap, NifResult, Term};
use valimc_core::mobs::living::enchant::{
    self, Action, Context, EntityHook, EntityView, Legacy, Target, Unconditioned, ValueHook,
};
use valimc_core::mobs::model::Slot;
use valimc_core::mobs::random::LegacyRandom;

/// An entity as requirements read it (`Valimc.Living.Enchant.entity/1`).
#[derive(NifMap)]
pub struct Entity {
    type_id: u16,
    on_ground: bool,
    in_water: bool,
    fall_flying: bool,
    flying: bool,
    vehicle: bool,
    can_see_sky: bool,
    affected_by: Option<u16>,
    horizontal_speed: f64,
    fall_distance: f64,
    tick_count: i32,
    player: Option<(String, i32)>,
}

impl Entity {
    fn view(&self) -> EntityView {
        EntityView {
            type_id: self.type_id,
            on_ground: self.on_ground,
            in_water: self.in_water,
            fall_flying: self.fall_flying,
            flying: self.flying,
            vehicle: self.vehicle,
            can_see_sky: self.can_see_sky,
            affected_by: self.affected_by,
            horizontal_speed: self.horizontal_speed,
            fall_distance: self.fall_distance,
            tick_count: self.tick_count,
            player: self.player.clone(),
        }
    }
}

/// A loot context (`Valimc.Living.Enchant.context/1`).
#[derive(NifMap)]
pub struct Ctx {
    this: Option<Entity>,
    attacker: Option<Entity>,
    direct: Option<Entity>,
    damage: Option<(u16, bool)>,
    tool: Option<i32>,
    thundering: bool,
    block: Option<(u16, bool)>,
}

struct Views {
    this: Option<EntityView>,
    attacker: Option<EntityView>,
    direct: Option<EntityView>,
}

impl Ctx {
    fn views(&self) -> Views {
        Views {
            this: self.this.as_ref().map(Entity::view),
            attacker: self.attacker.as_ref().map(Entity::view),
            direct: self.direct.as_ref().map(Entity::view),
        }
    }

    fn context<'a>(&self, views: &'a Views) -> Context<'a> {
        Context {
            this: views.this.as_ref(),
            attacker: views.attacker.as_ref(),
            direct: views.direct.as_ref(),
            damage: self.damage,
            tool: self.tool,
            active: None,
            thundering: self.thundering,
            block: self.block,
        }
    }
}

fn levels(enchantments: &[(String, i32)]) -> Vec<(&str, i32)> {
    enchantments.iter().map(|(n, l)| (n.as_str(), *l)).collect()
}

fn random(state: u64) -> NifResult<LegacyRandom> {
    LegacyRandom::from_state(state).ok_or(rustler::Error::BadArg)
}

fn slot(name: &str) -> NifResult<Slot> {
    Slot::from_name(name).ok_or(rustler::Error::BadArg)
}

fn value_hook(name: &str) -> NifResult<ValueHook> {
    Ok(match name {
        "damage_protection" => ValueHook::DamageProtection,
        "item_damage" => ValueHook::ItemDamage,
        "ammo_use" => ValueHook::AmmoUse,
        "projectile_piercing" => ValueHook::ProjectilePiercing,
        "block_experience" => ValueHook::BlockExperience,
        "mob_experience" => ValueHook::MobExperience,
        "repair_with_xp" => ValueHook::RepairWithXp,
        "trident_return_acceleration" => ValueHook::TridentReturnAcceleration,
        "fishing_time_reduction" => ValueHook::FishingTimeReduction,
        "fishing_luck_bonus" => ValueHook::FishingLuckBonus,
        "damage" => ValueHook::Damage,
        "smash_damage_per_fallen_block" => ValueHook::SmashDamagePerFallenBlock,
        "knockback" => ValueHook::Knockback,
        "armor_effectiveness" => ValueHook::ArmorEffectiveness,
        "projectile_count" => ValueHook::ProjectileCount,
        "projectile_spread" => ValueHook::ProjectileSpread,
        _ => return Err(rustler::Error::BadArg),
    })
}

fn entity_hook(name: &str) -> NifResult<EntityHook> {
    Ok(match name {
        "tick" => EntityHook::Tick,
        "projectile_spawned" => EntityHook::ProjectileSpawned,
        "hit_block" => EntityHook::HitBlock,
        "post_piercing_attack" => EntityHook::PostPiercingAttack,
        _ => return Err(rustler::Error::BadArg),
    })
}

fn target(name: &str) -> NifResult<Target> {
    Ok(match name {
        "attacker" => Target::Attacker,
        "damaging_entity" => Target::DamagingEntity,
        "victim" => Target::Victim,
        _ => return Err(rustler::Error::BadArg),
    })
}

fn target_name(target: Target) -> &'static str {
    match target {
        Target::Attacker => "attacker",
        Target::DamagingEntity => "damaging_entity",
        Target::Victim => "victim",
    }
}

fn atom<'a>(env: Env<'a>, name: &str) -> Term<'a> {
    Atom::from_str(env, name).unwrap().encode(env)
}

fn map<'a>(env: Env<'a>, fields: &[(&str, Term<'a>)]) -> Term<'a> {
    fields.iter().fold(Term::map_new(env), |m, (k, v)| {
        m.map_put(atom(env, k), *v).unwrap()
    })
}

fn float_provider<'a>(env: Env<'a>, p: &enchant::FloatProvider) -> Term<'a> {
    match p {
        enchant::FloatProvider::Constant(v) => (*v as f64).encode(env),
        enchant::FloatProvider::Uniform(a, b) => (*a as f64, *b as f64).encode(env),
    }
}

fn block_predicate<'a>(env: Env<'a>, p: &enchant::BlockPredicate) -> Term<'a> {
    use enchant::BlockPredicate as B;
    match p {
        B::AllOf(ps) => (
            atom(env, "all_of"),
            ps.iter()
                .map(|p| block_predicate(env, p))
                .collect::<Vec<_>>(),
        )
            .encode(env),
        B::Tag(o, t) => (atom(env, "tag"), (o[0], o[1], o[2]), t.as_str()).encode(env),
        B::Blocks(o, b) => (atom(env, "blocks"), (o[0], o[1], o[2]), b.clone()).encode(env),
        B::Fluids(o, f) => (atom(env, "fluids"), (o[0], o[1], o[2]), f.clone()).encode(env),
        B::Unobstructed => atom(env, "unobstructed"),
    }
}

/// Actions as a list term (a mob hurt's post-attack actions).
pub(crate) struct Actions(pub Vec<Action>);

impl Encoder for Actions {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        self.0
            .iter()
            .map(|a| action(env, a))
            .collect::<Vec<_>>()
            .encode(env)
    }
}

/// An action as `Valimc.Living.Enchant` reads it.
fn action<'a>(env: Env<'a>, action: &Action) -> Term<'a> {
    let f = |v: f32| (v as f64).encode(env);
    match action {
        Action::MobEffect {
            effect,
            ticks,
            amplifier,
        } => (atom(env, "mob_effect"), effect.as_str(), *ticks, *amplifier).encode(env),
        Action::Ignite(s) => (atom(env, "ignite"), f(*s)).encode(env),
        Action::Damage(a, t) => (atom(env, "damage"), f(*a), t.as_str()).encode(env),
        Action::ItemDamage(n) => (atom(env, "item_damage"), *n).encode(env),
        Action::Exhaustion(a) => (atom(env, "exhaustion"), f(*a)).encode(env),
        Action::Impulse(d, s, m) => (
            atom(env, "impulse"),
            (d[0], d[1], d[2]),
            (s[0], s[1], s[2]),
            f(*m),
        )
            .encode(env),
        Action::Sound(n, v, p) => (atom(env, "sound"), n.as_str(), f(*v), f(*p)).encode(env),
        Action::Particles(p) => (
            atom(env, "particles"),
            map(
                env,
                &[
                    ("particle", p.particle.as_str().encode(env)),
                    (
                        "horizontal",
                        (p.horizontal.0, p.horizontal.1 as f64, p.horizontal.2 as f64).encode(env),
                    ),
                    (
                        "vertical",
                        (p.vertical.0, p.vertical.1 as f64, p.vertical.2 as f64).encode(env),
                    ),
                    (
                        "horizontal_velocity",
                        (
                            p.horizontal_velocity.0 as f64,
                            float_provider(env, &p.horizontal_velocity.1),
                        )
                            .encode(env),
                    ),
                    (
                        "vertical_velocity",
                        (
                            p.vertical_velocity.0 as f64,
                            float_provider(env, &p.vertical_velocity.1),
                        )
                            .encode(env),
                    ),
                    ("speed", float_provider(env, &p.speed)),
                ],
            ),
        )
            .encode(env),
        Action::Summon(types, team) => (atom(env, "summon"), types.clone(), *team).encode(env),
        Action::Explode(e, radius, knockback) => (
            atom(env, "explode"),
            map(
                env,
                &[
                    ("attribute_to_user", e.attribute_to_user.encode(env)),
                    ("damage_type", e.damage_type.clone().encode(env)),
                    (
                        "knockback_multiplier",
                        knockback.map(|k| k as f64).encode(env),
                    ),
                    ("immune_blocks", e.immune_blocks.clone().encode(env)),
                    (
                        "offset",
                        (e.offset[0], e.offset[1], e.offset[2]).encode(env),
                    ),
                    ("radius", f(*radius)),
                    ("create_fire", e.create_fire.encode(env)),
                    (
                        "block_interaction",
                        e.block_interaction.as_str().encode(env),
                    ),
                    ("small_particle", e.small_particle.as_str().encode(env)),
                    ("large_particle", e.large_particle.as_str().encode(env)),
                    ("sound", e.sound.as_str().encode(env)),
                ],
            ),
        )
            .encode(env),
        Action::ReplaceDisk {
            radius,
            height,
            offset,
            predicate,
            state,
            event,
        } => (
            atom(env, "replace_disk"),
            map(
                env,
                &[
                    ("radius", radius.encode(env)),
                    ("height", height.encode(env)),
                    ("offset", (offset[0], offset[1], offset[2]).encode(env)),
                    (
                        "predicate",
                        match predicate {
                            Some(p) => block_predicate(env, p),
                            None => atom(env, "nil"),
                        },
                    ),
                    ("state", (state.0.as_str(), state.1.clone()).encode(env)),
                    ("event", event.clone().encode(env)),
                ],
            ),
        )
            .encode(env),
        Action::AddModifier(a, id, amount, op) => (
            atom(env, "add_modifier"),
            a.as_str(),
            id.as_str(),
            f(*amount),
            *op,
        )
            .encode(env),
        Action::RemoveModifier(a, id) => {
            (atom(env, "remove_modifier"), a.as_str(), id.as_str()).encode(env)
        }
    }
}

/// A value hook: `{:ok, {value, random}}`.
#[rustler::nif]
fn enchant_value(
    hook: String,
    enchantments: Vec<(String, i32)>,
    ctx: Ctx,
    state: u64,
    value: f64,
) -> NifResult<(Atom, (f64, u64))> {
    let facts = crate::mob_living::facts()?;
    let mob = crate::mob_facts::facts()?;
    let hook = value_hook(&hook)?;
    let mut r = random(state)?;
    let views = ctx.views();
    let mut draws = Legacy {
        random: &mut r,
        held: None,
    };
    let out = facts.enchant.value(
        mob,
        hook,
        &levels(&enchantments),
        &ctx.context(&views),
        &mut draws,
        value as f32,
    );
    Ok((crate::atoms::ok(), (out as f64, r.seed)))
}

/// An unconditioned value hook (`crossbow_charge_time`,
/// `trident_spin_attack_strength`).
#[rustler::nif]
fn enchant_unconditioned(
    hook: String,
    enchantments: Vec<(String, i32)>,
    value: f64,
) -> NifResult<(Atom, f64)> {
    let facts = crate::mob_living::facts()?;
    let hook = match hook.as_str() {
        "crossbow_charge_time" => Unconditioned::CrossbowChargeTime,
        "trident_spin_attack_strength" => Unconditioned::TridentSpinAttackStrength,
        _ => return Err(rustler::Error::BadArg),
    };
    let mut r = LegacyRandom::new(0);
    let mut draws = Legacy {
        random: &mut r,
        held: None,
    };
    let out = facts
        .enchant
        .unconditioned(hook, &levels(&enchantments), &mut draws, value as f32);
    Ok((crate::atoms::ok(), out as f64))
}

/// `processEquipmentDropChance`'s part of one piece held by `enchanted`.
#[rustler::nif]
fn enchant_equipment_drops(
    enchanted: String,
    enchantments: Vec<(String, i32)>,
    ctx: Ctx,
    state: u64,
    chance: f64,
) -> NifResult<(Atom, (f64, u64))> {
    let facts = crate::mob_living::facts()?;
    let mob = crate::mob_facts::facts()?;
    let mut r = random(state)?;
    let views = ctx.views();
    let mut draws = Legacy {
        random: &mut r,
        held: None,
    };
    let out = facts.enchant.equipment_drops(
        mob,
        target(&enchanted)?,
        &levels(&enchantments),
        &ctx.context(&views),
        &mut draws,
        chance as f32,
    );
    Ok((crate::atoms::ok(), (out as f64, r.seed)))
}

/// `isImmuneToDamage` for one piece.
#[rustler::nif]
fn enchant_immune(enchantments: Vec<(String, i32)>, ctx: Ctx) -> NifResult<(Atom, bool)> {
    let facts = crate::mob_living::facts()?;
    let mob = crate::mob_facts::facts()?;
    let views = ctx.views();
    let mut r = LegacyRandom::new(0);
    let mut draws = Legacy {
        random: &mut r,
        held: None,
    };
    let out = facts.enchant.immune(
        mob,
        &levels(&enchantments),
        &ctx.context(&views),
        &mut draws,
    );
    Ok((crate::atoms::ok(), out))
}

/// `forEachModifier(stack, slot)`: `[{attribute, id, amount, operation}]`.
#[rustler::nif]
fn enchant_modifiers(
    enchantments: Vec<(String, i32)>,
    slot_name: String,
) -> NifResult<(Atom, Vec<Modifier>)> {
    let facts = crate::mob_living::facts()?;
    let out = facts
        .enchant
        .attribute_modifiers(&levels(&enchantments), slot(&slot_name)?)
        .into_iter()
        .map(|(a, id, amount, op)| (a, id, amount as f64, op))
        .collect();
    Ok((crate::atoms::ok(), out))
}

/// `doPostAttack` of one item held by `enchanted` in `slot` (none: every
/// enchantment): `{:ok, {[{affected, action}], random}}`.
#[rustler::nif]
fn enchant_post_attack<'a>(
    env: Env<'a>,
    enchanted: String,
    enchantments: Vec<(String, i32)>,
    slot_name: Option<String>,
    ctx: Ctx,
    state: u64,
) -> NifResult<(Atom, (Vec<Term<'a>>, u64))> {
    let facts = crate::mob_living::facts()?;
    let mob = crate::mob_facts::facts()?;
    let mut r = random(state)?;
    let views = ctx.views();
    let mut draws = Legacy {
        random: &mut r,
        held: None,
    };
    // `runIterationOnItem(stack, slot, ...)` visits those acting in the slot.
    let mut levels = levels(&enchantments);
    if let Some(name) = slot_name {
        let slot = slot(&name)?;
        levels.retain(|(n, _)| facts.enchant.in_slot(n, slot));
    }
    let out = facts.enchant.post_attack(
        mob,
        target(&enchanted)?,
        &levels,
        &ctx.context(&views),
        &mut draws,
    );
    let terms = out
        .iter()
        .map(|(t, a)| (atom(env, target_name(*t)), action(env, a)).encode(env))
        .collect();
    Ok((crate::atoms::ok(), (terms, r.seed)))
}

/// An entity hook over one item in `slot` (none: every enchantment):
/// `{:ok, {actions, random}}`.
#[rustler::nif]
fn enchant_entity<'a>(
    env: Env<'a>,
    hook: String,
    enchantments: Vec<(String, i32)>,
    slot_name: Option<String>,
    ctx: Ctx,
    state: u64,
) -> NifResult<(Atom, (Vec<Term<'a>>, u64))> {
    let facts = crate::mob_living::facts()?;
    let mob = crate::mob_facts::facts()?;
    let mut r = random(state)?;
    let views = ctx.views();
    let mut draws = Legacy {
        random: &mut r,
        held: None,
    };
    let mut levels = levels(&enchantments);
    if let Some(name) = slot_name {
        let slot = slot(&name)?;
        levels.retain(|(n, _)| facts.enchant.in_slot(n, slot));
    }
    let out = facts.enchant.entity(
        mob,
        entity_hook(&hook)?,
        &levels,
        &ctx.context(&views),
        &mut draws,
    );
    let terms = out.iter().map(|a| action(env, a)).collect();
    Ok((crate::atoms::ok(), (terms, r.seed)))
}

type Active = Vec<(String, String, usize)>;
type Modifier = (String, String, f64, u8);
type Located<'a> = (Vec<Term<'a>>, Active, u64);
type Position = (i32, i32, i32);
type Sounds = (Option<String>, Option<String>, Option<String>);

fn active_of(active: &Active) -> NifResult<Vec<(Slot, String, usize)>> {
    active
        .iter()
        .map(|(s, n, i)| Ok((slot(s)?, n.clone(), *i)))
        .collect()
}

fn active_terms(active: Vec<(Slot, String, usize)>) -> Active {
    active
        .into_iter()
        .map(|(s, n, i)| (s.name().to_owned(), n, i))
        .collect()
}

/// `runLocationChangedEffects` for the item in `slot`: `{:ok, {actions,
/// active, random}}` with the entity's active location effects updated.
#[rustler::nif]
fn enchant_location<'a>(
    env: Env<'a>,
    slot_name: String,
    enchantments: Vec<(String, i32)>,
    active: Active,
    ctx: Ctx,
    state: u64,
) -> NifResult<(Atom, Located<'a>)> {
    let facts = crate::mob_living::facts()?;
    let mob = crate::mob_facts::facts()?;
    let mut r = random(state)?;
    let mut active = active_of(&active)?;
    let views = ctx.views();
    let mut draws = Legacy {
        random: &mut r,
        held: None,
    };
    let out = facts.enchant.location_changed(
        mob,
        slot(&slot_name)?,
        &levels(&enchantments),
        &mut active,
        &ctx.context(&views),
        &mut draws,
    );
    let terms = out.iter().map(|a| action(env, a)).collect();
    Ok((crate::atoms::ok(), (terms, active_terms(active), r.seed)))
}

/// `stopLocationBasedEffects` for the item leaving `slot`.
#[rustler::nif]
fn enchant_stop_location<'a>(
    env: Env<'a>,
    slot_name: String,
    enchantments: Vec<(String, i32)>,
    active: Active,
) -> NifResult<(Atom, (Vec<Term<'a>>, Active))> {
    let facts = crate::mob_living::facts()?;
    let mut active = active_of(&active)?;
    let out = facts
        .enchant
        .stop_location(slot(&slot_name)?, &levels(&enchantments), &mut active);
    let terms = out.iter().map(|a| action(env, a)).collect();
    Ok((crate::atoms::ok(), (terms, active_terms(active))))
}

/// `{prevent_armor_change, prevent_equipment_drop}` of the enchantments.
#[rustler::nif]
fn enchant_flags(enchantments: Vec<(String, i32)>) -> NifResult<(Atom, (bool, bool))> {
    let facts = crate::mob_living::facts()?;
    let levels = levels(&enchantments);
    Ok((
        crate::atoms::ok(),
        (
            facts.enchant.prevents_armor_change(&levels),
            facts.enchant.prevents_equipment_drop(&levels),
        ),
    ))
}

/// `replace_disk`'s candidate positions around `position`.
#[rustler::nif]
fn enchant_disk_positions(
    position: (f64, f64, f64),
    offset: (i32, i32, i32),
    radius: i32,
    height: i32,
) -> NifResult<(Atom, Vec<Position>)> {
    if !(0..=16).contains(&radius) || !(0..=16).contains(&height) {
        return Err(rustler::Error::BadArg);
    }
    let out = enchant::disk_positions(
        [position.0, position.1, position.2],
        [offset.0, offset.1, offset.2],
        radius,
        height,
    )
    .into_iter()
    .map(|p| (p[0], p[1], p[2]))
    .collect();
    Ok((crate::atoms::ok(), out))
}

/// How many of the enchantments acting in `slot` have value component `hook`.
#[rustler::nif]
fn enchant_count_with(
    hook: String,
    enchantments: Vec<(String, i32)>,
    slot_name: String,
) -> NifResult<(Atom, usize)> {
    let facts = crate::mob_living::facts()?;
    Ok((
        crate::atoms::ok(),
        facts.enchant.count_with(
            value_hook(&hook)?,
            &levels(&enchantments),
            slot(&slot_name)?,
        ),
    ))
}

/// The crossbow charging sounds of the enchantments (`{start, mid, end}`),
/// or nil for the default ones.
#[rustler::nif]
fn enchant_charging_sounds(enchantments: Vec<(String, i32)>) -> NifResult<(Atom, Option<Sounds>)> {
    let facts = crate::mob_living::facts()?;
    Ok((
        crate::atoms::ok(),
        facts
            .enchant
            .charging_sounds(&levels(&enchantments))
            .cloned(),
    ))
}
