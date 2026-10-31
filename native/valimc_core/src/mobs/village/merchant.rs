//! Merchants (VMC-044b2): what a villager's or a wandering trader's owner
//! asks and changes of it around a trade (`AbstractVillager` and the
//! trading parts of `Villager` and `WanderingTrader`).
//!
//! Its offers are its family data's `offers` (`Valimc.Menus.Offers`' maps,
//! made by its owner); whom it trades with (`tradingPlayer`) and whom it
//! last traded with (`lastTradedPlayer`) are its data's `trading` and
//! `last_traded`, which vanilla never saves: a restored merchant trades
//! with nobody (`record::restore`). The owner reads it
//! (`view`), starts and stops its trading, makes it unhappy, applies a
//! trade (`notifyTrade` and `rewardTradeXp`: uses, the ambient timer, the
//! orb's draw, experience, a level-up and its Regeneration) and plays
//! `notifyTradeUpdated`'s sound.

use crate::mobs::combat::{self, Event, Rules, SoundRef};
use crate::mobs::living::effects;
use crate::mobs::model::{NativeMob, Rung};
use crate::mobs::sensing::Uuid;
use crate::mobs::term::{Map, Value, NIL};

pub const VILLAGER: &str = "minecraft:villager";
pub const WANDERING_TRADER: &str = "minecraft:wandering_trader";

/// `VillagerData.NEXT_LEVEL_XP_THRESHOLDS`.
const THRESHOLDS: [i64; 5] = [0, 10, 70, 150, 250];

/// Whether a mob of `entity_type` trades.
pub fn merchant(entity_type: &str) -> bool {
    entity_type == VILLAGER || entity_type == WANDERING_TRADER
}

/// A uuid a data field holds.
pub fn uuid_of(data: &crate::mobs::model::FamilyData, key: &str) -> Option<Uuid> {
    data.get(key)?.as_binary()?.try_into().ok()
}

/// Whom it trades with.
pub fn trading(mob: &NativeMob) -> Option<Uuid> {
    uuid_of(&mob.body.data, "trading")
}

/// Start (`Some`) or stop trading.
pub fn set_trading(mob: &mut NativeMob, player: Option<Uuid>) -> bool {
    mob.body.data.set("trading", uuid_value(player));
    true
}

fn int(mob: &NativeMob, key: &str) -> i64 {
    mob.body.data.get(key).and_then(Value::as_int).unwrap_or(0)
}

fn uuid_value(uuid: Option<Uuid>) -> Value {
    Value::or_nil(uuid, |u| Value::Binary(u.to_vec()))
}

/// What the owner reads: `%{type, alive, baby, sleeping, profession, level,
/// xp, villager_type, offers, trading, custom_name}`.
pub fn view(mob: &NativeMob) -> Value {
    let data = &mob.body.data;
    let get = |k: &str| data.get(k).cloned().unwrap_or(NIL);
    let alive = crate::mobs::living::mob::alive(&mob.body.mob);
    let mut m = Map::new();
    m.insert_atom(
        "type",
        Value::Binary(mob.body.entity_type.as_bytes().to_vec()),
    );
    m.insert_atom("alive", Value::bool(alive));
    m.insert_atom("baby", Value::bool(int(mob, "age") < 0));
    m.insert_atom(
        "sleeping",
        Value::bool(data.get("sleeping").is_some_and(|v| !v.is_nil())),
    );
    m.insert_atom("profession", get("profession"));
    m.insert_atom("level", get("level"));
    m.insert_atom("xp", get("xp"));
    m.insert_atom("villager_type", get("villager_type"));
    m.insert_atom("offers", get("offers"));
    m.insert_atom("trading", uuid_value(trading(mob)));
    m.insert_atom("custom_name", mob.body.custom_name.clone().unwrap_or(NIL));
    Value::Map(m)
}

/// `makeSound`: at its volume (1) and voice pitch, drawn from its random.
fn sound(rules: &Rules, mob: &mut NativeMob, name: &str, events: &mut Vec<Event>) {
    let Some(id) = rules.facts.sounds.id(name) else {
        return;
    };
    let base = if int(mob, "age") < 0 { 1.5 } else { 1.0 };
    let uuid = mob.uuid;
    let pitch = combat::random(&mut mob.body.mob, &uuid).voice_pitch(base) as f64;
    let source = rules
        .facts
        .sounds
        .sources
        .get("neutral")
        .copied()
        .unwrap_or(0);
    events.push(Event::Sound {
        sound: SoundRef::Id(id),
        source,
        volume: 1.0,
        pitch,
    });
}

/// `Villager.setUnhappy`: its counter at 40 and the no sound.
pub fn unhappy(rules: &Rules, mob: &mut NativeMob, events: &mut Vec<Event>) {
    mob.body.data.set("unhappy", Value::Int(40));
    sound(rules, mob, "minecraft:entity.villager.no", events);
}

/// `getAmbientSoundInterval`.
fn ambient_interval(rules: &Rules, mob: &NativeMob) -> i64 {
    rules
        .of(&mob.body.entity_type)
        .and_then(|ty| rules.facts.ai.mob(ty.id).map(|m| m.ambient_interval))
        .unwrap_or(80) as i64
}

/// `notifyTradeUpdated`: at most once in 20 ticks of its ambient timer, the
/// yes (a result) or no sound. Whether it played.
pub fn updated(rules: &Rules, mob: &mut NativeMob, valid: bool, events: &mut Vec<Event>) -> bool {
    let interval = ambient_interval(rules, mob);
    let Some(state) = mob.body.mob.ai.as_mut().and_then(|m| m.state.as_mut()) else {
        return false;
    };
    if state.ambient <= -interval + 20 {
        return false;
    }
    state.ambient = -interval;
    let name = if mob.body.entity_type == WANDERING_TRADER {
        if valid {
            "minecraft:entity.wandering_trader.yes"
        } else {
            "minecraft:entity.wandering_trader.no"
        }
    } else if valid {
        "minecraft:entity.villager.yes"
    } else {
        "minecraft:entity.villager.no"
    };
    sound(rules, mob, name, events);
    true
}

fn offer_int(offer: &Map, key: &str) -> i64 {
    offer.get_atom(key).and_then(Value::as_int).unwrap_or(0)
}

/// A trade of offer `index` with `player`, its trading player
/// (`MerchantResultSlot.onTake` past the payment): `notifyTrade` and
/// `rewardTradeXp`. `%{pop: experience | nil, leveled, level, xp, offers}`,
/// or why it cannot trade.
pub fn trade(
    rules: &Rules,
    mob: &mut NativeMob,
    index: usize,
    player: Uuid,
) -> Result<Value, &'static str> {
    if trading(mob) != Some(player) {
        return Err("not_trading");
    }
    let mut offers: Vec<Value> = match mob.body.data.get("offers").and_then(Value::as_list) {
        Some(list) => list.to_vec(),
        None => return Err("no_offers"),
    };
    let Some(Value::Map(offer)) = offers.get_mut(index) else {
        return Err("no_offer");
    };
    let uses = offer_int(offer, "uses");
    if uses >= offer_int(offer, "max_uses") {
        return Err("out_of_stock");
    }
    offer.insert_atom("uses", Value::Int(uses + 1));
    let gained = offer_int(offer, "xp");
    let reward = offer
        .get_atom("reward_exp")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    mob.body.data.set("offers", Value::List(offers));
    let interval = ambient_interval(rules, mob);
    if let Some(state) = mob.body.mob.ai.as_mut().and_then(|m| m.state.as_mut()) {
        state.ambient = -interval;
    }
    let uuid = mob.uuid;
    let villager = mob.body.entity_type == VILLAGER;
    let mut pop = None;
    let mut leveled = false;
    if villager {
        let mut xp = 3 + combat::random(&mut mob.body.mob, &uuid).int(4) as i64;
        let total = int(mob, "xp") + gained;
        mob.body.data.set("xp", Value::Int(total));
        mob.body.data.set("last_traded", uuid_value(Some(player)));
        let level = int(mob, "level");
        if (1..5).contains(&level) && total >= THRESHOLDS[level as usize] {
            mob.body.data.set("level", Value::Int(level + 1));
            if let Some(id) = rules.facts.effects.id("minecraft:regeneration") {
                let rung = Rung {
                    ticks: 200,
                    amplifier: 0,
                    ambient: false,
                    particles: true,
                    icon: true,
                };
                effects::add(&mut mob.body.mob.living.effects, id as i32, rung);
            }
            leveled = true;
            xp += 5;
        }
        if reward {
            pop = Some(xp);
        }
    } else if reward {
        pop = Some(3 + combat::random(&mut mob.body.mob, &uuid).int(4) as i64);
    }
    let mut m = Map::new();
    m.insert_atom("pop", Value::or_nil(pop, Value::Int));
    m.insert_atom("leveled", Value::bool(leveled));
    m.insert_atom("level", Value::Int(int(mob, "level")));
    m.insert_atom("xp", Value::Int(int(mob, "xp")));
    m.insert_atom(
        "offers",
        mob.body.data.get("offers").cloned().unwrap_or(NIL),
    );
    Ok(Value::Map(m))
}

// ## Restocks and prices (VMC-044b3)

fn offers_of(mob: &NativeMob) -> Option<Vec<Value>> {
    mob.body
        .data
        .get("offers")?
        .as_list()
        .map(<[Value]>::to_vec)
}

fn each_offer(offers: &mut [Value], mut f: impl FnMut(&mut Map)) {
    for offer in offers.iter_mut() {
        if let Value::Map(m) = offer {
            f(m);
        }
    }
}

/// `MerchantOffer.updateDemand` of every offer: up by its uses, down by
/// its uses left.
fn update_demand(offers: &mut [Value]) {
    each_offer(offers, |m| {
        let (uses, max) = (offer_int(m, "uses"), offer_int(m, "max_uses"));
        let demand = offer_int(m, "demand") + uses - (max - uses);
        m.insert_atom("demand", Value::Int(demand));
    });
}

fn reset_uses(offers: &mut [Value]) {
    each_offer(offers, |m| m.insert_atom("uses", Value::Int(0)));
}

/// `Villager.updateSpecialPrices` for its trading player: special prices
/// reset, less the player's reputation times each price multiplier and,
/// under Hero of the Village (`trading_hero`, its amplifier), at least one
/// of `0.3 + 0.0625 × amplifier` of the base cost.
fn special_prices(mob: &mut NativeMob, offers: &mut [Value]) {
    // Gossip and its reputation are VMC-044c's.
    let reputation: i64 = 0;
    let hero = mob.body.data.get("trading_hero").and_then(Value::as_int);
    each_offer(offers, |m| {
        let mut special = 0i64;
        if reputation != 0 {
            let multiplier = m
                .get_atom("price_multiplier")
                .and_then(Value::as_float)
                .unwrap_or(0.0) as f32;
            special -= ((reputation as f32) * multiplier).floor() as i64;
        }
        if let Some(amplifier) = hero {
            let modifier = (0.3f32 + 0.0625f32 * amplifier as f32) as f64;
            let base = m
                .get_atom("buy")
                .and_then(Value::as_map)
                .and_then(|s| s.get_atom("count"))
                .and_then(Value::as_int)
                .unwrap_or(0);
            let cut = (modifier * base as f64).floor() as i64;
            special -= cut.max(1);
        }
        m.insert_atom("special_price", Value::Int(special));
    });
}

/// Start trading with `player` (Hero of the Village at `hero`, or none):
/// `updateSpecialPrices`, then `setTradingPlayer`.
pub fn start(mob: &mut NativeMob, player: Uuid, hero: Option<i64>) -> bool {
    mob.body
        .data
        .set("trading_hero", Value::or_nil(hero, Value::Int));
    if let Some(mut offers) = offers_of(mob) {
        special_prices(mob, &mut offers);
        mob.body.data.set("offers", Value::List(offers));
    }
    set_trading(mob, Some(player))
}

/// Its offers made (`updateTrades`): priced for its trading player, if
/// any (`updateSpecialPrices`).
pub fn set_offers(mob: &mut NativeMob, offers: Value) -> bool {
    match offers {
        Value::List(mut list) if trading(mob).is_some() => {
            special_prices(mob, &mut list);
            mob.body.data.set("offers", Value::List(list))
        }
        other => mob.body.data.set("offers", other),
    }
}

/// What a restock check found: whether to restock, or the offers it would
/// have made first (`getOffers`), with the demand updates a new day's
/// catch-up owes them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Restock {
    No,
    Yes,
    Wanted { demand_updates: i64 },
}

/// `Villager.shouldRestock` at game time `now` on overworld day `day`: a new
/// day (half a day since its last restock, or a later day than it last
/// checked) catches up the demand it missed; then it may restock (none
/// today yet, or one at least 2400 ticks ago) when a trade was used.
pub fn should_restock(mob: &mut NativeMob, now: i64, day: i64) -> Restock {
    let int = |mob: &NativeMob, k: &str| mob.body.data.get(k).and_then(Value::as_int).unwrap_or(0);
    let mut new_day = now > int(mob, "last_restock") + 12000;
    let checked = int(mob, "restock_day");
    new_day |= checked > 0 && day > checked;
    mob.body.data.set("restock_day", Value::Int(day));
    let mut owed = 0;
    if new_day {
        mob.body.data.set("last_restock", Value::Int(now));
        // `resetNumberOfRestocks`: `catchUpDemand`, then none today.
        let missed = 2 - int(mob, "restocks_today");
        match offers_of(mob) {
            Some(mut offers) => {
                if missed > 0 {
                    reset_uses(&mut offers);
                }
                for _ in 0..missed.max(0) {
                    update_demand(&mut offers);
                }
                if trading(mob).is_some() {
                    special_prices(mob, &mut offers);
                }
                mob.body.data.set("offers", Value::List(offers));
            }
            None => owed = missed.max(0),
        }
        mob.body.data.set("restocks_today", Value::Int(0));
    }
    let today = int(mob, "restocks_today");
    let allowed = today == 0 || (today < 2 && now > int(mob, "last_restock") + 2400);
    match offers_of(mob) {
        None if new_day || allowed => Restock::Wanted {
            demand_updates: owed,
        },
        None => Restock::No,
        Some(offers) => {
            let used = offers
                .iter()
                .any(|o| o.as_map().is_some_and(|m| offer_int(m, "uses") > 0));
            if allowed && used {
                Restock::Yes
            } else {
                Restock::No
            }
        }
    }
}

/// `Villager.restock` at game time `now`: demand, then every trade back.
pub fn restock(mob: &mut NativeMob, now: i64) {
    let Some(mut offers) = offers_of(mob) else {
        return;
    };
    update_demand(&mut offers);
    reset_uses(&mut offers);
    if trading(mob).is_some() {
        special_prices(mob, &mut offers);
    }
    mob.body.data.set("offers", Value::List(offers));
    mob.body.data.set("last_restock", Value::Int(now));
    let today = mob
        .body
        .data
        .get("restocks_today")
        .and_then(Value::as_int)
        .unwrap_or(0);
    mob.body.data.set("restocks_today", Value::Int(today + 1));
}
