//! What the living rules read beyond `mobs::facts` (VMC-081d), installed
//! with them from the generated files the Elixir decodes
//! (`Valimc.Living.NativeFacts` hands their decoded JSON over): the
//! enchantments' damage protection, immunity, attack and item damage effects
//! (`Valimc.Protocol.EnchantmentEffects`), each item's maximum damage, stock
//! damage component and attack damage type (`ItemTypes`, `Weapons`), the
//! blocks' landing rules (`BlockFacts.landing/1`) and the types that breathe
//! under water (`SpawnFacts.water_breather?/1`). The ids of the effects,
//! damage types, attributes and tags the rules name are resolved once here,
//! with each damage type's tags the rules ask as bits.

use super::super::facts::MobFacts;
use super::super::model::Slot;
use crate::worldgen::json::Json;
use std::collections::HashMap;

/// Status effect ids the rules name (`EffectTypes.id/1`).
#[derive(Clone, Copy, Debug)]
pub struct EffectIds {
    pub speed: i32,
    pub slowness: i32,
    pub regeneration: i32,
    pub poison: i32,
    pub wither: i32,
    pub hunger: i32,
    pub instant_health: i32,
    pub instant_damage: i32,
    pub saturation: i32,
    pub resistance: i32,
    pub fire_resistance: i32,
    pub water_breathing: i32,
    pub conduit_power: i32,
    pub breath_of_the_nautilus: i32,
    pub jump_boost: i32,
    pub slow_falling: i32,
    pub levitation: i32,
    pub absorption: i32,
    pub invisibility: i32,
    pub glowing: i32,
}

/// Damage type registry ids the rules name.
#[derive(Clone, Copy, Debug)]
pub struct DamageIds {
    pub on_fire: u16,
    pub in_fire: u16,
    pub lava: u16,
    pub drown: u16,
    pub magic: u16,
    pub indirect_magic: u16,
    pub wither: u16,
    pub mob_attack: u16,
    pub generic_kill: u16,
    pub hot_floor: u16,
    pub campfire: u16,
    pub cactus: u16,
    pub sweet_berry_bush: u16,
}

/// Attribute ids the rules name.
#[derive(Clone, Copy, Debug)]
pub struct AttributeIds {
    pub max_health: u16,
    pub armor: u16,
    pub armor_toughness: u16,
    pub knockback_resistance: u16,
    pub burning_time: u16,
    pub oxygen_bonus: u16,
    pub safe_fall_distance: u16,
    pub fall_damage_multiplier: u16,
    pub attack_damage: u16,
    pub attack_knockback: u16,
}

/// Damage type tag bits (`DamageSource.is?/2`).
pub mod tag {
    pub const IS_FIRE: u32 = 1 << 0;
    pub const IS_FALL: u32 = 1 << 1;
    pub const IS_FREEZING: u32 = 1 << 2;
    pub const DAMAGES_HELMET: u32 = 1 << 3;
    pub const BYPASSES_COOLDOWN: u32 = 1 << 4;
    pub const BYPASSES_ARMOR: u32 = 1 << 5;
    pub const BYPASSES_EFFECTS: u32 = 1 << 6;
    pub const BYPASSES_RESISTANCE: u32 = 1 << 7;
    pub const BYPASSES_ENCHANTMENTS: u32 = 1 << 8;
    pub const BYPASSES_INVULNERABILITY: u32 = 1 << 9;
    pub const NO_ANGER: u32 = 1 << 10;
    pub const NO_KNOCKBACK: u32 = 1 << 11;
    pub const IS_PROJECTILE: u32 = 1 << 12;
    pub const IS_EXPLOSION: u32 = 1 << 13;

    pub(super) const NAMES: [(u32, &str); 14] = [
        (IS_FIRE, "minecraft:is_fire"),
        (IS_FALL, "minecraft:is_fall"),
        (IS_FREEZING, "minecraft:is_freezing"),
        (DAMAGES_HELMET, "minecraft:damages_helmet"),
        (BYPASSES_COOLDOWN, "minecraft:bypasses_cooldown"),
        (BYPASSES_ARMOR, "minecraft:bypasses_armor"),
        (BYPASSES_EFFECTS, "minecraft:bypasses_effects"),
        (BYPASSES_RESISTANCE, "minecraft:bypasses_resistance"),
        (BYPASSES_ENCHANTMENTS, "minecraft:bypasses_enchantments"),
        (
            BYPASSES_INVULNERABILITY,
            "minecraft:bypasses_invulnerability",
        ),
        (NO_ANGER, "minecraft:no_anger"),
        (NO_KNOCKBACK, "minecraft:no_knockback"),
        (IS_PROJECTILE, "minecraft:is_projectile"),
        (IS_EXPLOSION, "minecraft:is_explosion"),
    ];
}

/// Entity type tag bits the rules ask (`EntityTypes.tag?/2`).
pub mod entity_tag {
    pub const FALL_DAMAGE_IMMUNE: u8 = 1 << 0;
    pub const FREEZE_HURTS_EXTRA: u8 = 1 << 1;
    pub const CAN_BREATHE_UNDER_WATER: u8 = 1 << 2;
    pub const BURN_IN_DAYLIGHT: u8 = 1 << 3;
    /// `SpawnFacts.water_breather?/1` (not a tag).
    pub const WATER_BREATHER: u8 = 1 << 4;

    pub(super) const NAMES: [(u8, &str); 4] = [
        (FALL_DAMAGE_IMMUNE, "minecraft:fall_damage_immune"),
        (FREEZE_HURTS_EXTRA, "minecraft:freeze_hurts_extra_types"),
        (CAN_BREATHE_UNDER_WATER, "minecraft:can_breathe_under_water"),
        (BURN_IN_DAYLIGHT, "minecraft:burn_in_daylight"),
    ];
}

/// An item's stock attribute modifier and the slots it acts in.
#[derive(Clone, Debug, PartialEq)]
pub struct ItemModifier {
    pub attribute: u16,
    pub id: String,
    pub amount: f64,
    pub operation: u8,
    /// Bits by `Slot as usize`.
    pub slots: u8,
}

/// What the rules read of an item type.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ItemFacts {
    /// Its `max_damage` (`ItemTypes.item(id)["max_damage"]`).
    pub max_damage: Option<i64>,
    /// Whether its stock components hold `minecraft:damage` (0).
    pub damage_default: bool,
    /// Whether its stock components hold `minecraft:kinetic_weapon` (a
    /// spear's).
    pub kinetic_default: bool,
    /// The damage type its attacks deal (`Weapons.damage_type/2`).
    pub damage_type: Option<u16>,
    /// Its stock attribute modifiers in order (`Weapons.modifiers/2`).
    pub modifiers: Vec<ItemModifier>,
}

/// Damage type tags a source must have (true) or lack (false).
pub type Requirement = Vec<(String, bool)>;

/// An attack effect's entity condition: the target's (`this`) or the
/// direct attacker's type in an entity type tag.
#[derive(Clone, Debug, PartialEq)]
pub struct EntityRequirement {
    pub this: bool,
    pub tag: String,
}

/// `LevelBasedValue.Linear`: `(base, per level above the first)`.
pub type Linear = (f64, f64);

/// One enchantment's effects the rules read.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Enchantment {
    /// Bits by `Slot as usize` of its slot groups.
    pub slots: u8,
    pub protection: Vec<(Linear, Requirement)>,
    pub immunity: Vec<Requirement>,
    pub damage: Vec<(Linear, Option<EntityRequirement>)>,
    pub knockback: Vec<(Linear, Option<EntityRequirement>)>,
    /// `RemoveBinomial`'s fraction and the item tag the tool must be in
    /// (or not).
    pub item_damage: Vec<((Linear, Linear), (String, bool))>,
}

/// `Block.fallOn`'s damage call (`BlockFacts.landing/1`).
#[derive(Clone, Debug, PartialEq)]
pub struct LandingRule {
    pub distance_scale: f64,
    pub distance_offset: f64,
    pub multiplier: f64,
    pub source: u16,
}

/// A landing palette entry: the rules without and with sneaking.
pub type LandingPair = [Option<LandingRule>; 2];

/// The living rules' facts.
#[derive(Debug)]
pub struct LivingFacts {
    pub effects: EffectIds,
    /// The number of effect types.
    pub effect_count: i32,
    pub damage: DamageIds,
    pub attributes: AttributeIds,
    /// Tag bits by damage type id.
    damage_tags: Vec<u32>,
    /// Each damage type's tags, namespaced and sorted (loot's
    /// `damage_source_properties`).
    damage_tag_names: Vec<Vec<String>>,
    /// Tag bits by entity type id.
    entity_tags: Vec<u8>,
    items: HashMap<i32, ItemFacts>,
    /// By name.
    pub enchantments: HashMap<String, Enchantment>,
    /// The enchantment engine over the same definitions (VMC-037q).
    pub enchant: super::enchant::Engine,
    landing_states: Vec<u16>,
    landing: Vec<LandingPair>,
    /// `bubble_column`'s block id.
    pub bubble_column: Option<u16>,
    /// `HostileFacts.drop_chance/0`, widened.
    pub drop_chance: f64,
}

static NO_ITEM: ItemFacts = ItemFacts {
    max_damage: None,
    damage_default: false,
    kinetic_default: false,
    damage_type: None,
    modifiers: Vec::new(),
};

/// The slots of an `EquipmentSlotGroup`.
pub fn slot_group(name: &str) -> Result<u8, String> {
    let bits = |slots: &[Slot]| slots.iter().fold(0u8, |m, s| m | 1 << *s as usize);
    Ok(match name {
        "any" => 0xFF,
        "hand" => bits(&[Slot::Mainhand, Slot::Offhand]),
        // `EquipmentSlotGroup.ARMOR`: every armor slot, the body's too.
        "armor" => bits(&[Slot::Feet, Slot::Legs, Slot::Chest, Slot::Head, Slot::Body]),
        other => match Slot::from_name(other) {
            Some(slot) => 1 << slot as usize,
            None => return Err(format!("unknown slot group {other}")),
        },
    })
}

impl LivingFacts {
    /// The facts from the installer's map (`Valimc.Living.NativeFacts`):
    /// `enchantments` (the definitions), `items` (`protocol/items.json`'s),
    /// `damage_defaults` (item ids whose stock components hold damage),
    /// `kinetic_defaults` (those whose stock components hold a kinetic
    /// weapon),
    /// `combat_items` (`combat_facts`' items), `landing` (the block facts'
    /// landing column) and `water_breathers` (type names), over `mob`.
    pub fn parse(json: &Json, mob: &MobFacts) -> Result<LivingFacts, String> {
        let at = |key: &str| json.field(key).map_err(|e| format!("living facts: {e}"));
        let effect = |name: &str| -> Result<i32, String> {
            mob.effects
                .id(&format!("minecraft:{name}"))
                .map(|i| i as i32)
                .ok_or_else(|| format!("unknown effect {name}"))
        };
        let effects = EffectIds {
            speed: effect("speed")?,
            slowness: effect("slowness")?,
            regeneration: effect("regeneration")?,
            poison: effect("poison")?,
            wither: effect("wither")?,
            hunger: effect("hunger")?,
            instant_health: effect("instant_health")?,
            instant_damage: effect("instant_damage")?,
            saturation: effect("saturation")?,
            resistance: effect("resistance")?,
            fire_resistance: effect("fire_resistance")?,
            water_breathing: effect("water_breathing")?,
            conduit_power: effect("conduit_power")?,
            breath_of_the_nautilus: effect("breath_of_the_nautilus")?,
            jump_boost: effect("jump_boost")?,
            slow_falling: effect("slow_falling")?,
            levitation: effect("levitation")?,
            absorption: effect("absorption")?,
            invisibility: effect("invisibility")?,
            glowing: effect("glowing")?,
        };
        let damage_id = |name: &str| {
            mob.damage_types
                .id(name)
                .ok_or_else(|| format!("unknown damage type {name}"))
        };
        let damage = DamageIds {
            on_fire: damage_id("on_fire")?,
            in_fire: damage_id("in_fire")?,
            lava: damage_id("lava")?,
            drown: damage_id("drown")?,
            magic: damage_id("magic")?,
            indirect_magic: damage_id("indirect_magic")?,
            wither: damage_id("wither")?,
            mob_attack: damage_id("mob_attack")?,
            generic_kill: damage_id("generic_kill")?,
            hot_floor: damage_id("hot_floor")?,
            campfire: damage_id("campfire")?,
            cactus: damage_id("cactus")?,
            sweet_berry_bush: damage_id("sweet_berry_bush")?,
        };
        let attribute = |name: &str| {
            mob.attributes
                .id(name)
                .ok_or_else(|| format!("unknown attribute {name}"))
        };
        let attributes = AttributeIds {
            max_health: attribute("max_health")?,
            armor: attribute("armor")?,
            armor_toughness: attribute("armor_toughness")?,
            knockback_resistance: attribute("knockback_resistance")?,
            burning_time: attribute("burning_time")?,
            oxygen_bonus: attribute("oxygen_bonus")?,
            safe_fall_distance: attribute("safe_fall_distance")?,
            fall_damage_multiplier: attribute("fall_damage_multiplier")?,
            attack_damage: attribute("attack_damage")?,
            attack_knockback: attribute("attack_knockback")?,
        };

        let types = mob.damage_types.types.len();
        let damage_tags = (0..types)
            .map(|id| {
                tag::NAMES
                    .iter()
                    .filter(|(_, name)| mob.damage_tag(id as u16, name))
                    .fold(0, |bits, (bit, _)| bits | bit)
            })
            .collect();
        let mut damage_tag_names = vec![Vec::new(); types];
        if let Some(tags) = mob.tags.tags.get("minecraft:damage_type") {
            for (name, ids) in tags {
                for &id in ids {
                    if let Some(names) = damage_tag_names.get_mut(id as usize) {
                        names.push(name.clone());
                    }
                }
            }
        }
        for names in &mut damage_tag_names {
            names.sort();
        }

        let mut entity_tags: Vec<u8> = (0..mob.entities.types.len())
            .map(|id| {
                entity_tag::NAMES
                    .iter()
                    .filter(|(_, name)| mob.entity_tag(id as u16, name))
                    .fold(0, |bits, (bit, _)| bits | bit)
            })
            .collect();
        for name in at("water_breathers")?.as_array()? {
            let name = name.as_str()?;
            let id = mob
                .entities
                .id(name)
                .ok_or_else(|| format!("unknown entity type {name}"))?;
            entity_tags[id as usize] |= entity_tag::WATER_BREATHER;
        }

        let mut items: HashMap<i32, ItemFacts> = HashMap::new();
        for (name, row) in at("items")?.entries()? {
            let id = row.field("id")?.as_i32()?;
            let max_damage = match row.get("max_damage") {
                None | Some(Json::Null) => None,
                Some(n) => Some(n.as_f64()? as i64),
            };
            items.entry(id).or_default().max_damage = max_damage;
            let _ = name;
        }
        for id in at("damage_defaults")?.as_array()? {
            items.entry(id.as_i32()?).or_default().damage_default = true;
        }
        if let Some(ids) = json.get("kinetic_defaults") {
            for id in ids.as_array()? {
                items.entry(id.as_i32()?).or_default().kinetic_default = true;
            }
        }
        for (name, components) in at("combat_items")?.entries()? {
            let id = mob
                .items
                .id(name)
                .ok_or_else(|| format!("unknown item {name}"))?;
            let item = items.entry(id).or_default();
            if let Some(t) = components.get("minecraft:damage_type") {
                item.damage_type = Some(damage_id(t.as_str()?)?);
            }
            if let Some(modifiers) = components.get("minecraft:attribute_modifiers") {
                for m in modifiers.as_array()? {
                    let operation = match m.field("operation")?.as_str()? {
                        "add_value" => 0,
                        "add_multiplied_base" => 1,
                        "add_multiplied_total" => 2,
                        other => return Err(format!("unknown operation {other}")),
                    };
                    let slot = match m.get("slot") {
                        Some(s) => s.as_str()?,
                        None => "any",
                    };
                    item.modifiers.push(ItemModifier {
                        attribute: attribute(m.field("type")?.as_str()?)?,
                        id: m.field("id")?.as_str()?.to_owned(),
                        amount: m.field("amount")?.as_f64()?,
                        operation,
                        slots: slot_group(slot)?,
                    });
                }
            }
        }

        let enchantments = parse_enchantments(at("enchantments")?)?;
        let enchant = super::enchant::Engine::parse(at("enchantments")?, mob)?;
        let (landing_states, landing) = parse_landing(at("landing")?, mob)?;

        Ok(LivingFacts {
            effects,
            effect_count: mob.effects.len() as i32,
            damage,
            attributes,
            damage_tags,
            damage_tag_names,
            entity_tags,
            items,
            enchantments,
            enchant,
            landing_states,
            landing,
            bubble_column: mob.blocks.id("minecraft:bubble_column"),
            drop_chance: mob.hostile.drop_chance as f64,
        })
    }

    /// Whether damage type `source` has tag bit `bit` (`DamageSource.is?/2`).
    #[inline]
    pub fn is(&self, source: u16, bit: u32) -> bool {
        self.damage_tags
            .get(source as usize)
            .is_some_and(|t| t & bit != 0)
    }

    /// The tags of damage type `source` (`DamageTypes.tags_of/1`), sorted.
    pub fn tags_of(&self, source: u16) -> &[String] {
        self.damage_tag_names
            .get(source as usize)
            .map_or(&[], Vec::as_slice)
    }

    /// Whether entity type `id` has tag bit `bit` (`entity_tag`).
    #[inline]
    pub fn entity_is(&self, id: u16, bit: u8) -> bool {
        self.entity_tags
            .get(id as usize)
            .is_some_and(|t| t & bit != 0)
    }

    /// An item type's facts (none for an unknown one).
    pub fn item(&self, id: i32) -> &ItemFacts {
        self.items.get(&id).unwrap_or(&NO_ITEM)
    }

    /// `BlockFacts.landing(state)`, without sneaking.
    pub fn landing(&self, state: u16) -> Option<&LandingRule> {
        let index = *self.landing_states.get(state as usize)? as usize;
        self.landing.get(index)?[0].as_ref()
    }
}

fn linear(json: &Json) -> Result<Linear, String> {
    match json.field("type")?.as_str()? {
        "minecraft:linear" => Ok((
            json.field("base")?.as_f64()?,
            json.field("per_level_above_first")?.as_f64()?,
        )),
        other => Err(format!("unsupported enchantment level value {other}")),
    }
}

fn requirement(json: Option<&Json>) -> Result<Requirement, String> {
    let Some(json) = json else {
        return Ok(Vec::new());
    };
    if json.field("type")?.as_str()? != "minecraft:damage_source_properties" {
        return Err("unsupported enchantment requirement".into());
    }
    let predicate = json.field("predicate")?;
    if predicate.entries()?.len() != 1 {
        return Err("unsupported enchantment requirement predicate".into());
    }
    predicate
        .field("tags")?
        .as_array()?
        .iter()
        .map(|t| {
            let id = t.field("id")?.as_str()?;
            let tag = id
                .strip_prefix('#')
                .ok_or_else(|| format!("expected a tag, got {id}"))?;
            Ok((tag.to_owned(), t.field("expected")?.as_bool()?))
        })
        .collect()
}

fn entity_requirement(json: Option<&Json>) -> Result<Option<EntityRequirement>, String> {
    let Some(json) = json else {
        return Ok(None);
    };
    if json.field("type")?.as_str()? != "minecraft:entity_properties" {
        return Err("unsupported attack effect requirement".into());
    }
    let this = match json.field("entity")?.as_str()? {
        "this" => true,
        "direct_attacker" => false,
        other => return Err(format!("unsupported attack effect entity {other}")),
    };
    let predicate = json.field("predicate")?;
    if predicate.entries()?.len() != 1 {
        return Err("unsupported attack effect predicate".into());
    }
    let tag = predicate.field("minecraft:entity_type")?.as_str()?;
    let tag = tag
        .strip_prefix('#')
        .ok_or_else(|| format!("expected an entity tag, got {tag}"))?;
    Ok(Some(EntityRequirement {
        this,
        tag: tag.to_owned(),
    }))
}

fn match_tool(json: &Json) -> Result<(String, bool), String> {
    let (json, expected) = match json.field("type")?.as_str()? {
        "minecraft:inverted" => (json.field("term")?, false),
        _ => (json, true),
    };
    if json.field("type")?.as_str()? != "minecraft:match_tool" {
        return Err("unsupported item damage requirement".into());
    }
    let items = json.field("predicate")?.field("items")?.as_str()?;
    let tag = items
        .strip_prefix('#')
        .ok_or_else(|| format!("expected an item tag, got {items}"))?;
    Ok((tag.to_owned(), expected))
}

fn parse_enchantments(json: &Json) -> Result<HashMap<String, Enchantment>, String> {
    let mut out = HashMap::new();
    for (name, definition) in json.entries()? {
        let effects = definition.field("effects")?;
        let list = |key: &str| -> Result<&[Json], String> {
            match effects.get(key) {
                None => Ok(&[]),
                Some(j) => j.as_array(),
            }
        };
        let mut slots = 0u8;
        for group in definition.field("slots")?.as_array()? {
            slots |= slot_group(group.as_str()?)?;
        }
        let protection = list("minecraft:damage_protection")?
            .iter()
            .map(|entry| {
                let effect = entry.field("effect")?;
                if effect.field("type")?.as_str()? != "minecraft:add" {
                    return Err(format!("{name}: unsupported damage protection"));
                }
                Ok((
                    linear(effect.field("value")?)?,
                    requirement(entry.get("requirements"))?,
                ))
            })
            .collect::<Result<Vec<_>, String>>()?;
        let immunity = list("minecraft:damage_immunity")?
            .iter()
            .map(|entry| {
                if !entry.field("effect")?.entries()?.is_empty() {
                    return Err(format!("{name}: unsupported damage immunity"));
                }
                requirement(entry.get("requirements"))
            })
            .collect::<Result<Vec<_>, String>>()?;
        let attack = |key: &str| -> Result<Vec<(Linear, Option<EntityRequirement>)>, String> {
            list(key)?
                .iter()
                .map(|entry| {
                    let effect = entry.field("effect")?;
                    if effect.field("type")?.as_str()? != "minecraft:add" {
                        return Err(format!("{name}: unsupported attack effect"));
                    }
                    Ok((
                        linear(effect.field("value")?)?,
                        entity_requirement(entry.get("requirements"))?,
                    ))
                })
                .collect()
        };
        let damage = attack("minecraft:damage")?;
        let knockback = attack("minecraft:knockback")?;
        let item_damage = list("minecraft:item_damage")?
            .iter()
            .map(|entry| {
                let effect = entry.field("effect")?;
                if effect.field("type")?.as_str()? != "minecraft:remove_binomial" {
                    return Err(format!("{name}: unsupported item damage"));
                }
                let chance = effect.field("chance")?;
                if chance.field("type")?.as_str()? != "minecraft:fraction" {
                    return Err(format!("{name}: unsupported item damage chance"));
                }
                Ok((
                    (
                        linear(chance.field("numerator")?)?,
                        linear(chance.field("denominator")?)?,
                    ),
                    match_tool(entry.field("requirements")?)?,
                ))
            })
            .collect::<Result<Vec<_>, String>>()?;
        if protection.is_empty()
            && immunity.is_empty()
            && damage.is_empty()
            && knockback.is_empty()
            && item_damage.is_empty()
        {
            continue;
        }
        out.insert(
            name.clone(),
            Enchantment {
                slots,
                protection,
                immunity,
                damage,
                knockback,
                item_damage,
            },
        );
    }
    Ok(out)
}

/// The landing column: each state's palette index (one or two bytes per
/// state, as hex) and the palette of `[without, with sneaking]` rules.
fn parse_landing(json: &Json, mob: &MobFacts) -> Result<(Vec<u16>, Vec<LandingPair>), String> {
    let hex = json.field("states")?.as_str()?;
    if !hex.len().is_multiple_of(2) {
        return Err("odd landing states".into());
    }
    let bytes = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).map_err(|e| e.to_string()))
        .collect::<Result<Vec<u8>, String>>()?;
    let count = json.field("state_count")?.as_f64()? as usize;
    let states = if bytes.len() == count {
        bytes.iter().map(|&b| b as u16).collect()
    } else if bytes.len() == 2 * count {
        bytes
            .chunks(2)
            .map(|c| u16::from_be_bytes([c[0], c[1]]))
            .collect()
    } else {
        return Err("landing column does not cover every state".into());
    };
    let rule = |j: &Json| -> Result<Option<LandingRule>, String> {
        if *j == Json::Null {
            return Ok(None);
        }
        let source = j.field("source")?.as_str()?;
        Ok(Some(LandingRule {
            distance_scale: j.field("distance_scale")?.as_f64()?,
            distance_offset: j.field("distance_offset")?.as_f64()?,
            multiplier: j.field("multiplier")?.as_f64()?,
            source: mob
                .damage_types
                .id(source)
                .ok_or_else(|| format!("unknown damage type {source}"))?,
        }))
    };
    let palette = json
        .field("palette")?
        .as_array()?
        .iter()
        .map(|pair| match pair.as_array()? {
            [plain, shift] => Ok([rule(plain)?, rule(shift)?]),
            _ => Err("bad landing pair".to_string()),
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok((states, palette))
}
