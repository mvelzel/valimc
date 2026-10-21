//! What spawning a structure's mobs draws from the level's random
//! (VMC-025f): entities are recorded, not simulated, but their
//! `finalizeSpawn` takes values from the region's random, which later
//! placement in the same chunk shares. Counts follow vanilla at a normal
//! difficulty at the world's start (special multiplier 0, as
//! `WorldGenRegion.getCurrentDifficultyAt` gives then).

use super::super::random::Random;
use super::super::region::Region;
use super::place::Ctx;
use super::BiomeSet;

/// `Mob.finalizeSpawn`: the follow range bonus (a triangle of two doubles)
/// and left-handedness.
fn mob(random: &mut Random) {
    mob_with(random, false);
}

/// `Mob.finalizeSpawn` for a mob that may already have its follow range
/// bonus (a template mob saved with one draws only left-handedness).
fn mob_with(random: &mut Random, bonus: bool) {
    if !bonus {
        random.next_double();
        random.next_double();
    }
    random.next_float();
}

/// `finalizeSpawn` of a template's entity (`StructureTemplate.placeEntities`
/// with finalized entities, VMC-025f3) from its type and SNBT; entities that
/// are not mobs draw nothing.
pub fn finalize_template(region: &mut Region, kind: &str, snbt: &str) -> Result<(), String> {
    let bonus = snbt.contains("\"minecraft:random_spawn_bonus\"");
    let random = &mut region.random;
    match kind {
        // A camel's memories and attributes draw nothing.
        "minecraft:villager"
        | "minecraft:iron_golem"
        | "minecraft:allay"
        | "minecraft:witch"
        | "minecraft:evoker"
        | "minecraft:piglin_brute"
        | "minecraft:camel" => mob_with(random, bonus),
        // After `Mob`: the variant (any of eleven at a full moon, the
        // attributes' default), then the sound variant.
        "minecraft:cat" => {
            mob_with(random, bonus);
            random.next_int_bounded(11);
            random.next_int_bounded(2);
        }
        // The variant (one per climate) and the sound variant, then `Mob`.
        "minecraft:cow" => {
            random.next_int_bounded(1);
            random.next_int_bounded(2);
            mob_with(random, bonus);
        }
        "minecraft:pig" => {
            random.next_int_bounded(1);
            random.next_int_bounded(3);
            mob_with(random, bonus);
        }
        // `SheepColorSpawnRules`: a colour of weight 100, where every
        // climate's first four (18) are single colours and the common one
        // draws again between white (499) and pink (1).
        "minecraft:sheep" => {
            if random.next_int_bounded(100) >= 18 {
                random.next_int_bounded(500);
            }
            mob_with(random, bonus);
        }
        // Variant and markings, then `randomizeAttributes`: health (two
        // ints), speed and jump strength (three doubles each).
        "minecraft:horse" => {
            random.next_int_bounded(7);
            random.next_int_bounded(5);
            random.next_int_bounded(8);
            random.next_int_bounded(9);
            for _ in 0..6 {
                random.next_double();
            }
            mob_with(random, bonus);
        }
        // A baby one time in five.
        "minecraft:hoglin" => {
            random.next_float();
            mob_with(random, bonus);
        }
        // A bastion's piglin: its hunting cooldown (30–120 s), golden armour
        // pieces a tenth of the time each (adults), the enchantment chance of
        // its weapon and of each armour piece, then `Mob`.
        "minecraft:piglin" => {
            random.next_int_bounded(1801);
            let mut armour = 0;
            if !snbt.contains("IsBaby:1b") {
                for _ in 0..4 {
                    if random.next_float() < 0.1 {
                        armour += 1;
                    }
                }
            }
            if snbt.contains("mainhand:{") {
                random.next_float();
            }
            for _ in 0..armour {
                random.next_float();
            }
            mob_with(random, bonus);
        }
        "minecraft:zombie_villager" => zombie(random, bonus)?,
        "minecraft:armor_stand" | "minecraft:cushion" => {}
        other => return Err(format!("finalizing a template's {other} is not modelled")),
    }
    Ok(())
}

/// `Zombie.finalizeSpawn` (a template's zombie villager): `Mob`, loot
/// pickup, a baby (and a jockey's chances), door breaking, armour and weapon
/// chances, the weapon's enchantment chance, Halloween heads.
fn zombie(random: &mut Random, bonus: bool) -> Result<(), String> {
    mob_with(random, bonus);
    random.next_float();
    let baby = random.next_float() < 0.05;
    if baby && random.next_float() >= 0.05 && random.next_float() < 0.05 {
        return Err("a zombie chicken jockey is not modelled".into());
    }
    random.next_float();
    // `Mob.populateDefaultEquipmentSlots` (no armour at the world's start),
    // then a sword, spear or shovel a hundredth of the time.
    random.next_float();
    if random.next_float() < 0.01 {
        random.next_int_bounded(6);
        random.next_float();
    }
    if is_halloween() && random.next_float() < 0.25 {
        random.next_float();
    }
    Ok(())
}

/// `finalizeSpawn` of a mob a structure spawns, by entity type.
pub fn finalize(c: &mut Ctx, kind: &str) -> Result<(), String> {
    let random = &mut c.region.random;
    match kind {
        "minecraft:witch" | "minecraft:evoker" | "minecraft:allay" | "minecraft:elder_guardian" => {
            mob(random)
        }
        // The cat's variant (one of the variants that pass, the black ones
        // in a swamp hut) and its sound variant (classic or royal).
        "minecraft:cat" => {
            mob(random);
            random.next_int_bounded(1);
            random.next_int_bounded(2);
        }
        // An iron axe, then the chance to enchant it.
        "minecraft:vindicator" => {
            mob(random);
            random.next_float();
        }
        other => return Err(format!("spawning {other} in a structure is not modelled")),
    }
    Ok(())
}

/// `Drowned.finalizeSpawn` over `Zombie.finalizeSpawn`; whether the drowned
/// rides a zombie nautilus (outside `frequent` biomes, an adult with a
/// trident half the time), whose own `finalizeSpawn` follows.
pub fn finalize_drowned(c: &mut Ctx, pos: [i32; 3], frequent: &BiomeSet) -> Result<bool, String> {
    let random = &mut c.region.random;
    mob(random);
    // Picking up loot, then a baby (a chicken jockey's two chances).
    random.next_float();
    let baby = random.next_float() < 0.05;
    if baby && random.next_float() >= 0.05 && random.next_float() < 0.05 {
        return Err("a drowned chicken jockey is not modelled".into());
    }
    // Breaking doors, then the trident or fishing rod and its enchantment.
    random.next_float();
    let mut trident = false;
    if random.next_float() > 0.9 {
        trident = random.next_int_bounded(16) < 10;
        random.next_float();
    }
    if is_halloween() && random.next_float() < 0.25 {
        random.next_float();
    }
    // A nautilus shell, then a zombie nautilus to ride for some with a
    // trident.
    random.next_float();
    if !(trident && random.next_float() < 0.5 && !baby) {
        return Ok(false);
    }
    if frequent.contains(c.region.biome(pos)) {
        return Ok(false);
    }
    // `ZombieNautilus.finalizeSpawn`: its variant (the one of the highest
    // priority that the biome allows), the attack cooldown memory
    // (2,400–3,600 ticks), then `Mob.finalizeSpawn` (adults only, no baby
    // chance for the first of a group).
    let random = &mut c.region.random;
    random.next_int_bounded(1);
    random.next_int_bounded(1201);
    mob(random);
    Ok(true)
}

/// `SpecialDates.isHalloween`: October 31 (by the system clock, in UTC).
fn is_halloween() -> bool {
    let days = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() / 86_400)
        .unwrap_or(0) as i64;
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    month == 10 && day == 31
}
