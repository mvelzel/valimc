//! Compiling the definitions' JSON (as `EnchantmentMetadata` writes it) into
//! the engine's types. Every form outside those the pinned pack uses is an
//! error.

use super::*;
use crate::mobs::facts::MobFacts;
use crate::mobs::living::facts::slot_group;
use crate::worldgen::json::Json;

type R<T> = Result<T, String>;

fn kind(json: &Json) -> R<&str> {
    json.field("type")?.as_str()
}

fn f32_of(json: &Json) -> R<f32> {
    Ok(json.as_f64()? as f32)
}

fn level(json: &Json) -> R<Level> {
    if let Json::Number(n) = json {
        return Ok(Level::Constant(*n as f32));
    }
    let sub = |key: &str| -> R<Box<Level>> { Ok(Box::new(level(json.field(key)?)?)) };
    Ok(match kind(json)? {
        "minecraft:constant" => Level::Constant(f32_of(json.field("value")?)?),
        "minecraft:linear" => Level::Linear(
            f32_of(json.field("base")?)?,
            f32_of(json.field("per_level_above_first")?)?,
        ),
        "minecraft:clamped" => Level::Clamped(
            sub("value")?,
            f32_of(json.field("min")?)?,
            f32_of(json.field("max")?)?,
        ),
        "minecraft:fraction" => Level::Fraction(sub("numerator")?, sub("denominator")?),
        "minecraft:levels_squared" => Level::Squared(f32_of(json.field("added")?)?),
        "minecraft:lookup" => Level::Lookup(
            json.field("values")?
                .as_array()?
                .iter()
                .map(f32_of)
                .collect::<R<_>>()?,
            sub("fallback")?,
        ),
        "minecraft:exponent" => Level::Exponent(sub("base")?, sub("power")?),
        other => return Err(format!("unsupported level-based value {other}")),
    })
}

fn float_provider(json: &Json) -> R<FloatProvider> {
    if let Json::Number(n) = json {
        return Ok(FloatProvider::Constant(*n as f32));
    }
    Ok(match kind(json)? {
        "minecraft:constant" => FloatProvider::Constant(f32_of(json.field("value")?)?),
        "minecraft:uniform" => FloatProvider::Uniform(
            f32_of(json.field("min_inclusive")?)?,
            f32_of(json.field("max_exclusive")?)?,
        ),
        other => return Err(format!("unsupported float provider {other}")),
    })
}

fn value_effect(json: &Json) -> R<ValueEffect> {
    Ok(match kind(json)? {
        "minecraft:add" => ValueEffect::Add(level(json.field("value")?)?),
        "minecraft:set" => ValueEffect::Set(level(json.field("value")?)?),
        "minecraft:multiply" => ValueEffect::Multiply(level(json.field("factor")?)?),
        "minecraft:remove_binomial" => ValueEffect::RemoveBinomial(level(json.field("chance")?)?),
        "minecraft:all_of" => ValueEffect::AllOf(
            json.field("effects")?
                .as_array()?
                .iter()
                .map(value_effect)
                .collect::<R<_>>()?,
        ),
        other => return Err(format!("unsupported value effect {other}")),
    })
}

fn names(json: &Json) -> R<Vec<String>> {
    match json {
        Json::String(s) => Ok(vec![s.clone()]),
        Json::Array(a) => a.iter().map(|s| Ok(s.as_str()?.to_owned())).collect(),
        other => Err(format!("expected names, got {other:?}")),
    }
}

fn tag_name(s: &str) -> R<String> {
    s.strip_prefix('#')
        .map(str::to_owned)
        .ok_or_else(|| format!("expected a tag, got {s}"))
}

fn vec3(json: &Json) -> R<[f64; 3]> {
    let a = json.as_array()?;
    if a.len() != 3 {
        return Err("expected three coordinates".into());
    }
    Ok([a[0].as_f64()?, a[1].as_f64()?, a[2].as_f64()?])
}

fn veci(json: &Json) -> R<[i32; 3]> {
    let a = json.as_array()?;
    if a.len() != 3 {
        return Err("expected three coordinates".into());
    }
    Ok([a[0].as_i32()?, a[1].as_i32()?, a[2].as_i32()?])
}

fn known(json: &Json, allowed: &[&str]) -> R<()> {
    for (key, _) in json.entries()? {
        if !allowed.contains(&key.as_str()) {
            return Err(format!("unsupported field {key}"));
        }
    }
    Ok(())
}

fn entity_predicate(mob: &MobFacts, json: &Json) -> R<EntityPredicate> {
    let mut p = EntityPredicate::default();
    for (key, value) in json.entries()? {
        match key.as_str() {
            "minecraft:entity_type" => {
                let name = value.as_str()?;
                p.entity_type = Some(if name.starts_with('#') {
                    Err(tag_name(name)?)
                } else {
                    Ok(mob
                        .entities
                        .ids
                        .get(name)
                        .copied()
                        .ok_or_else(|| format!("unknown entity type {name}"))?)
                });
            }
            "minecraft:flags" => {
                known(
                    value,
                    &["is_on_ground", "is_in_water", "is_fall_flying", "is_flying"],
                )?;
                let flag = |k: &str| value.get(k).map(Json::as_bool).transpose();
                p.on_ground = flag("is_on_ground")?;
                p.in_water = flag("is_in_water")?;
                p.fall_flying = flag("is_fall_flying")?;
                p.flying = flag("is_flying")?;
            }
            "minecraft:vehicle" => {
                if !value.entries()?.is_empty() {
                    return Err("unsupported vehicle predicate".into());
                }
                p.vehicle = true;
            }
            "minecraft:location" => {
                known(value, &["can_see_sky"])?;
                p.can_see_sky = Some(value.field("can_see_sky")?.as_bool()?);
            }
            "minecraft:movement_affected_by" => {
                known(value, &["block"])?;
                let block = value.field("block")?;
                known(block, &["blocks"])?;
                p.affected_by = Some(tag_name(block.field("blocks")?.as_str()?)?);
            }
            "minecraft:movement" => {
                known(value, &["horizontal_speed", "fall_distance"])?;
                let min = |k: &str| -> R<Option<f64>> {
                    match value.get(k) {
                        None => Ok(None),
                        Some(range) => {
                            known(range, &["min"])?;
                            Ok(Some(range.field("min")?.as_f64()?))
                        }
                    }
                };
                p.min_horizontal_speed = min("horizontal_speed")?;
                p.min_fall_distance = min("fall_distance")?;
            }
            "minecraft:periodic_tick" => p.periodic_tick = Some(value.as_i32()?),
            "minecraft:type_specific/player" => {
                known(value, &["gamemode", "food"])?;
                let modes = match value.get("gamemode") {
                    Some(m) => names(m)?,
                    None => Vec::new(),
                };
                let food = match value.get("food") {
                    Some(food) => {
                        known(food, &["level"])?;
                        let level = food.field("level")?;
                        known(level, &["min"])?;
                        Some(level.field("min")?.as_i32()?)
                    }
                    None => None,
                };
                p.player = Some((modes, food));
            }
            other => return Err(format!("unsupported entity predicate {other}")),
        }
    }
    Ok(p)
}

pub(super) fn condition(mob: &MobFacts, json: &Json) -> R<Condition> {
    let terms = |key: &str| -> R<Vec<Condition>> {
        json.field(key)?
            .as_array()?
            .iter()
            .map(|t| condition(mob, t))
            .collect()
    };
    Ok(match kind(json)? {
        "minecraft:all_of" => Condition::AllOf(terms("terms")?),
        "minecraft:any_of" => Condition::AnyOf(terms("terms")?),
        "minecraft:inverted" => Condition::Inverted(Box::new(condition(mob, json.field("term")?)?)),
        "minecraft:entity_properties" => {
            let who = match json.field("entity")?.as_str()? {
                "this" => Who::This,
                "attacker" => Who::Attacker,
                "direct_attacker" => Who::DirectAttacker,
                other => return Err(format!("unsupported entity target {other}")),
            };
            Condition::Entity(who, entity_predicate(mob, json.field("predicate")?)?)
        }
        "minecraft:damage_source_properties" => {
            let predicate = json.field("predicate")?;
            known(predicate, &["tags", "is_direct"])?;
            let tags = match predicate.get("tags") {
                Some(tags) => tags
                    .as_array()?
                    .iter()
                    .map(|t| {
                        Ok((
                            tag_name(t.field("id")?.as_str()?)?,
                            t.field("expected")?.as_bool()?,
                        ))
                    })
                    .collect::<R<_>>()?,
                None => Vec::new(),
            };
            let direct = predicate.get("is_direct").map(Json::as_bool).transpose()?;
            Condition::Damage(tags, direct)
        }
        "minecraft:match_tool" => {
            let predicate = json.field("predicate")?;
            known(predicate, &["items"])?;
            let items = predicate.field("items")?.as_str()?;
            Condition::MatchTool(if items.starts_with('#') {
                Err(tag_name(items)?)
            } else {
                Ok(mob
                    .items
                    .id(items)
                    .ok_or_else(|| format!("unknown item {items}"))?)
            })
        }
        "minecraft:random_chance" => {
            let chance = json.field("chance")?;
            Condition::Chance(match chance {
                Json::Number(n) => Level::Constant(*n as f32),
                _ if kind(chance)? == "minecraft:enchantment_level" => {
                    level(chance.field("amount")?)?
                }
                _ => return Err("unsupported random chance".into()),
            })
        }
        "minecraft:enchantment_active_check" => Condition::Active(json.field("active")?.as_bool()?),
        "minecraft:weather_check" => {
            known(json, &["type", "thundering"])?;
            Condition::Thundering(json.field("thundering")?.as_bool()?)
        }
        "minecraft:location_check" => {
            known(json, &["type", "predicate"])?;
            let predicate = json.field("predicate")?;
            known(predicate, &["block", "can_see_sky"])?;
            let block = match predicate.get("block") {
                Some(b) => {
                    known(b, &["blocks"])?;
                    Some(tag_name(b.field("blocks")?.as_str()?)?)
                }
                None => None,
            };
            let sky = predicate
                .get("can_see_sky")
                .map(Json::as_bool)
                .transpose()?;
            Condition::Location(block, sky)
        }
        other => return Err(format!("unsupported requirement {other}")),
    })
}

fn block_predicate(json: &Json) -> R<BlockPredicate> {
    let offset = |json: &Json| -> R<[i32; 3]> {
        match json.get("offset") {
            Some(o) => veci(o),
            None => Ok([0, 0, 0]),
        }
    };
    Ok(match kind(json)? {
        "minecraft:all_of" => BlockPredicate::AllOf(
            json.field("predicates")?
                .as_array()?
                .iter()
                .map(block_predicate)
                .collect::<R<_>>()?,
        ),
        "minecraft:matching_block_tag" => {
            BlockPredicate::Tag(offset(json)?, json.field("tag")?.as_str()?.to_owned())
        }
        "minecraft:matching_blocks" => {
            BlockPredicate::Blocks(offset(json)?, names(json.field("blocks")?)?)
        }
        "minecraft:matching_fluids" => {
            BlockPredicate::Fluids(offset(json)?, names(json.field("fluids")?)?)
        }
        "minecraft:unobstructed" => BlockPredicate::Unobstructed,
        other => return Err(format!("unsupported block predicate {other}")),
    })
}

fn particle_type(json: &Json) -> R<String> {
    known(json, &["type"])?;
    Ok(kind(json)?.to_owned())
}

fn position_source(json: &Json) -> R<(bool, f32, f32)> {
    known(json, &["type", "offset", "scale"])?;
    let in_box = match json.field("type")?.as_str()? {
        "in_bounding_box" => true,
        "entity_position" => false,
        other => return Err(format!("unsupported particle position {other}")),
    };
    let get = |k: &str, d: f32| -> R<f32> { json.get(k).map(f32_of).unwrap_or(Ok(d)) };
    Ok((in_box, get("offset", 0.0)?, get("scale", 1.0)?))
}

fn velocity_source(json: &Json) -> R<(f32, FloatProvider)> {
    known(json, &["movement_scale", "base"])?;
    Ok((
        json.get("movement_scale").map(f32_of).unwrap_or(Ok(0.0))?,
        match json.get("base") {
            Some(b) => float_provider(b)?,
            None => FloatProvider::Constant(0.0),
        },
    ))
}

pub(super) fn effect(json: &Json) -> R<Effect> {
    let lv = |k: &str| level(json.field(k)?);
    Ok(match kind(json)? {
        "minecraft:all_of" => Effect::AllOf(
            json.field("effects")?
                .as_array()?
                .iter()
                .map(effect)
                .collect::<R<_>>()?,
        ),
        "minecraft:apply_mob_effect" => Effect::MobEffect {
            effects: names(json.field("to_apply")?)?,
            min_duration: lv("min_duration")?,
            max_duration: lv("max_duration")?,
            min_amplifier: lv("min_amplifier")?,
            max_amplifier: lv("max_amplifier")?,
        },
        "minecraft:ignite" => Effect::Ignite(lv("duration")?),
        "minecraft:damage_entity" => Effect::DamageEntity(
            lv("min_damage")?,
            lv("max_damage")?,
            json.field("damage_type")?.as_str()?.to_owned(),
        ),
        "minecraft:change_item_damage" => Effect::ChangeItemDamage(lv("amount")?),
        "minecraft:apply_exhaustion" => Effect::Exhaustion(lv("amount")?),
        "minecraft:apply_impulse" => Effect::Impulse(
            vec3(json.field("direction")?)?,
            vec3(json.field("coordinate_scale")?)?,
            lv("magnitude")?,
        ),
        "minecraft:play_sound" => Effect::Sound(
            names(json.field("sound")?)?,
            float_provider(json.field("volume")?)?,
            float_provider(json.field("pitch")?)?,
        ),
        "minecraft:spawn_particles" => Effect::Particles(Box::new(Particles {
            particle: particle_type(json.field("particle")?)?,
            horizontal: position_source(json.field("horizontal_position")?)?,
            vertical: position_source(json.field("vertical_position")?)?,
            horizontal_velocity: velocity_source(json.field("horizontal_velocity")?)?,
            vertical_velocity: velocity_source(json.field("vertical_velocity")?)?,
            speed: match json.get("speed") {
                Some(s) => float_provider(s)?,
                None => FloatProvider::Constant(0.0),
            },
        })),
        "minecraft:summon_entity" => Effect::Summon(
            names(json.field("entity")?)?,
            json.get("join_team")
                .map(Json::as_bool)
                .unwrap_or(Ok(false))?,
        ),
        "minecraft:explode" => Effect::Explode(Box::new(Explode {
            attribute_to_user: json
                .get("attribute_to_user")
                .map(Json::as_bool)
                .unwrap_or(Ok(false))?,
            damage_type: json
                .get("damage_type")
                .map(|d| d.as_str().map(str::to_owned))
                .transpose()?,
            knockback_multiplier: json.get("knockback_multiplier").map(level).transpose()?,
            immune_blocks: json
                .get("immune_blocks")
                .map(|b| tag_name(b.as_str()?))
                .transpose()?,
            offset: json.get("offset").map(vec3).unwrap_or(Ok([0.0; 3]))?,
            radius: lv("radius")?,
            create_fire: json
                .get("create_fire")
                .map(Json::as_bool)
                .unwrap_or(Ok(false))?,
            block_interaction: json.field("block_interaction")?.as_str()?.to_owned(),
            small_particle: particle_type(json.field("small_particle")?)?,
            large_particle: particle_type(json.field("large_particle")?)?,
            sound: json.field("sound")?.as_str()?.to_owned(),
        })),
        "minecraft:replace_disk" => {
            let state = json.field("block_state")?;
            // A bare state is the simple state provider's shorthand.
            let state = match state.get("type").map(Json::as_str).transpose()? {
                Some("minecraft:simple_state_provider") => state.field("state")?,
                Some(other) => return Err(format!("unsupported state provider {other}")),
                None => state,
            };
            let properties = match state.get("properties") {
                Some(p) => p
                    .entries()?
                    .iter()
                    .map(|(k, v)| Ok((k.clone(), v.as_str()?.to_owned())))
                    .collect::<R<_>>()?,
                None => Vec::new(),
            };
            Effect::ReplaceDisk {
                radius: lv("radius")?,
                height: lv("height")?,
                offset: json.get("offset").map(veci).unwrap_or(Ok([0; 3]))?,
                predicate: json.get("predicate").map(block_predicate).transpose()?,
                state: (
                    state
                        .field("Name")
                        .or_else(|_| state.field("id"))?
                        .as_str()?
                        .to_owned(),
                    properties,
                ),
                event: json
                    .get("trigger_game_event")
                    .map(|e| e.as_str().map(str::to_owned))
                    .transpose()?,
            }
        }
        "minecraft:attribute" => Effect::Attribute(
            json.field("attribute")?.as_str()?.to_owned(),
            json.field("id")?.as_str()?.to_owned(),
            lv("amount")?,
            operation(json.field("operation")?.as_str()?)?,
        ),
        other => return Err(format!("unsupported effect {other}")),
    })
}

fn operation(name: &str) -> R<u8> {
    Ok(match name {
        "add_value" => 0,
        "add_multiplied_base" => 1,
        "add_multiplied_total" => 2,
        other => return Err(format!("unsupported operation {other}")),
    })
}

fn target(name: &str) -> R<Target> {
    Ok(match name {
        "attacker" => Target::Attacker,
        "damaging_entity" => Target::DamagingEntity,
        "victim" => Target::Victim,
        other => return Err(format!("unsupported enchantment target {other}")),
    })
}

const VALUES: [(&str, ValueHook); 16] = [
    ("minecraft:damage_protection", ValueHook::DamageProtection),
    ("minecraft:item_damage", ValueHook::ItemDamage),
    ("minecraft:ammo_use", ValueHook::AmmoUse),
    (
        "minecraft:projectile_piercing",
        ValueHook::ProjectilePiercing,
    ),
    ("minecraft:block_experience", ValueHook::BlockExperience),
    ("minecraft:mob_experience", ValueHook::MobExperience),
    ("minecraft:repair_with_xp", ValueHook::RepairWithXp),
    (
        "minecraft:trident_return_acceleration",
        ValueHook::TridentReturnAcceleration,
    ),
    (
        "minecraft:fishing_time_reduction",
        ValueHook::FishingTimeReduction,
    ),
    ("minecraft:fishing_luck_bonus", ValueHook::FishingLuckBonus),
    ("minecraft:damage", ValueHook::Damage),
    (
        "minecraft:smash_damage_per_fallen_block",
        ValueHook::SmashDamagePerFallenBlock,
    ),
    ("minecraft:knockback", ValueHook::Knockback),
    (
        "minecraft:armor_effectiveness",
        ValueHook::ArmorEffectiveness,
    ),
    ("minecraft:projectile_count", ValueHook::ProjectileCount),
    ("minecraft:projectile_spread", ValueHook::ProjectileSpread),
];

const ENTITY: [(&str, EntityHook); 4] = [
    ("minecraft:tick", EntityHook::Tick),
    (
        "minecraft:projectile_spawned",
        EntityHook::ProjectileSpawned,
    ),
    ("minecraft:hit_block", EntityHook::HitBlock),
    (
        "minecraft:post_piercing_attack",
        EntityHook::PostPiercingAttack,
    ),
];

fn requirements(mob: &MobFacts, entry: &Json) -> R<Option<Condition>> {
    entry
        .get("requirements")
        .map(|r| condition(mob, r))
        .transpose()
}

fn definition(mob: &MobFacts, name: &str, json: &Json) -> R<Definition> {
    let mut d = Definition {
        name: name.to_owned(),
        max_level: json.get("max_level").map(Json::as_i32).unwrap_or(Ok(1))?,
        ..Definition::default()
    };
    for group in json.field("slots")?.as_array()? {
        d.slots |= slot_group(group.as_str()?)?;
    }
    for (key, value) in json.field("effects")?.entries()? {
        let list = || value.as_array();
        if let Some((_, hook)) = VALUES.iter().find(|(k, _)| k == key) {
            let effects = list()?
                .iter()
                .map(|e| Ok((value_effect(e.field("effect")?)?, requirements(mob, e)?)))
                .collect::<R<_>>()?;
            d.values.insert(*hook, effects);
        } else if let Some((_, hook)) = ENTITY.iter().find(|(k, _)| k == key) {
            let effects = list()?
                .iter()
                .map(|e| Ok((effect(e.field("effect")?)?, requirements(mob, e)?)))
                .collect::<R<_>>()?;
            d.entity.insert(*hook, effects);
        } else {
            match key.as_str() {
                "minecraft:crossbow_charge_time" => {
                    d.unconditioned
                        .insert(Unconditioned::CrossbowChargeTime, value_effect(value)?);
                }
                "minecraft:trident_spin_attack_strength" => {
                    d.unconditioned.insert(
                        Unconditioned::TridentSpinAttackStrength,
                        value_effect(value)?,
                    );
                }
                "minecraft:equipment_drops" => {
                    for e in list()? {
                        // `equipmentDropsCodec`: the victim is always the affected.
                        d.equipment_drops.push((
                            target(e.field("enchanted")?.as_str()?)?,
                            match e.get("affected") {
                                Some(a) => target(a.as_str()?)?,
                                None => Target::Victim,
                            },
                            value_effect(e.field("effect")?)?,
                            requirements(mob, e)?,
                        ));
                    }
                }
                "minecraft:post_attack" => {
                    for e in list()? {
                        d.post_attack.push(Targeted {
                            enchanted: target(e.field("enchanted")?.as_str()?)?,
                            affected: target(e.field("affected")?.as_str()?)?,
                            effect: effect(e.field("effect")?)?,
                            condition: requirements(mob, e)?,
                        });
                    }
                }
                "minecraft:location_changed" => {
                    for e in list()? {
                        d.location_changed
                            .push((effect(e.field("effect")?)?, requirements(mob, e)?));
                    }
                }
                "minecraft:attributes" => {
                    for e in list()? {
                        d.attributes.push(AttributeEffect {
                            attribute: e.field("attribute")?.as_str()?.to_owned(),
                            id: e.field("id")?.as_str()?.to_owned(),
                            amount: level(e.field("amount")?)?,
                            operation: operation(e.field("operation")?.as_str()?)?,
                        });
                    }
                }
                "minecraft:damage_immunity" => {
                    for e in list()? {
                        if !e.field("effect")?.entries()?.is_empty() {
                            return Err("unsupported damage immunity".into());
                        }
                        d.immunity.push(requirements(mob, e)?);
                    }
                }
                "minecraft:prevent_armor_change" => d.prevent_armor_change = true,
                "minecraft:prevent_equipment_drop" => d.prevent_equipment_drop = true,
                "minecraft:crossbow_charging_sounds" => {
                    for e in list()? {
                        let get = |k: &str| -> R<Option<String>> {
                            e.get(k).map(|s| s.as_str().map(str::to_owned)).transpose()
                        };
                        d.charging_sounds
                            .push((get("start")?, get("mid")?, get("end")?));
                    }
                }
                "minecraft:trident_sound" => d.trident_sounds = names(value)?,
                other => return Err(format!("unsupported effect component {other}")),
            }
        }
    }
    Ok(d)
}

impl Engine {
    /// The engine from the definitions (`enchantments` of
    /// `registry/enchantments.json`), resolving names through `mob`.
    pub fn parse(json: &Json, mob: &MobFacts) -> Result<Engine, String> {
        let mut definitions = HashMap::new();
        for (name, def) in json.entries()? {
            definitions.insert(
                name.clone(),
                definition(mob, name, def).map_err(|e| format!("{name}: {e}"))?,
            );
        }
        Ok(Engine { definitions })
    }
}
