//! Villager trades (VMC-044b1), from the trade facts (`TradeOracle`,
//! `priv/loot/trades.json`): each `villager_trade` as `VillagerTrade`, each
//! `trade_set` with its trades in holder-set order, each profession's set by
//! level and the wandering trader's sets.
//!
//! `offers` is `AbstractVillager.addOffersFromTradeSet`: the set's amount,
//! then trades drawn with or without repeats, each made by `getOffer` (its
//! merchant predicate, the result through its modifiers, the additional
//! trade cost the result carries, doubled for the listed enchantments, the
//! costs clamped to their item's stack size). It draws from the set's random
//! sequence, which the caller owns (`sequence` seeds a fresh one as
//! `RandomSequences` does).

use std::collections::HashMap;

use super::{Condition, Ctx, Death, FloatProvider, Function, IntProvider, Loot, LootWorld, Stack};
use crate::worldgen::json::Json;
use crate::worldgen::random::{mix_stafford13, seed_from_hash, Random};

/// A trade's cost (`TradeCost`): an item, its count and, when it asks for
/// components, the potion it must hold (the only exact component trades
/// name).
#[derive(Debug)]
struct TradeCost {
    item: String,
    count: IntProvider,
    potion: Option<String>,
}

/// One `villager_trade`.
#[derive(Debug)]
struct Trade {
    wants: TradeCost,
    additional_wants: Option<TradeCost>,
    gives: (String, i32),
    max_uses: IntProvider,
    xp: IntProvider,
    reputation_discount: FloatProvider,
    predicate: Option<Condition>,
    modifier: Option<Function>,
    double_price: Option<Vec<String>>,
}

/// One `trade_set`.
#[derive(Debug)]
struct TradeSet {
    trades: Vec<String>,
    amount: IntProvider,
    allow_duplicates: bool,
    sequence: Option<String>,
}

/// The trade facts.
#[derive(Debug, Default)]
pub struct Trades {
    trades: HashMap<String, Trade>,
    sets: HashMap<String, TradeSet>,
    /// Each profession's set by level (1 to 5).
    professions: HashMap<String, Vec<(i32, String)>>,
    wandering: Vec<String>,
}

/// An offer's cost (`ItemCost`): the item, its count and the potion its
/// components ask for.
#[derive(Clone, Debug, PartialEq)]
pub struct Cost {
    pub item: String,
    pub count: i32,
    pub potion: Option<String>,
}

/// A `MerchantOffer` as made: its costs, result, uses, experience and price
/// multiplier.
#[derive(Clone, Debug, PartialEq)]
pub struct Offer {
    pub buy: Cost,
    pub buy_b: Option<Cost>,
    pub sell: Stack,
    pub max_uses: i32,
    pub xp: i32,
    pub price_multiplier: f32,
}

/// The merchant a draw is for: its villager type (`villager/variant`) and
/// its position (the loot origin).
#[derive(Clone, Debug)]
pub struct Merchant {
    pub villager_type: String,
    pub origin: [f64; 3],
}

/// `RandomSequences.createSequence`: the Xoroshiro state of sequence `id`
/// for world seed `seed` with `salt` (the world seed and the id both
/// included).
pub fn sequence(seed: i64, salt: i32, id: &str) -> (u64, u64) {
    const SILVER: u64 = 0x6A09_E667_F3BC_C909;
    const GOLDEN: u64 = 0x9E37_79B9_7F4A_7C15;
    let seed = (seed ^ salt as i64) as u64;
    let lo = seed ^ SILVER;
    let hi = lo.wrapping_add(GOLDEN);
    let (hash_lo, hash_hi) = seed_from_hash(id);
    (mix_stafford13(lo ^ hash_lo), mix_stafford13(hi ^ hash_hi))
}

impl Trades {
    pub(super) fn parse(loot: &Loot, json: &Json) -> Result<Trades, String> {
        let mut trades = HashMap::new();
        for (id, t) in json.field("trades")?.entries()? {
            trades.insert(
                id.clone(),
                Self::trade(loot, t).map_err(|e| format!("trade {id}: {e}"))?,
            );
        }
        let mut sets = HashMap::new();
        for (id, set) in json.field("sets")?.entries()? {
            let list = set
                .field("trades")?
                .as_array()?
                .iter()
                .map(|t| t.as_str().map(str::to_string))
                .collect::<Result<Vec<_>, _>>()?;
            if let Some(missing) = list.iter().find(|t| !trades.contains_key(*t)) {
                return Err(format!("trade set {id} names unknown trade {missing}"));
            }
            sets.insert(
                id.clone(),
                TradeSet {
                    trades: list,
                    amount: Loot::int_provider(set.field("amount")?)?,
                    allow_duplicates: set.field("allow_duplicates")?.as_bool()?,
                    sequence: match set.get("random_sequence") {
                        Some(Json::String(s)) => Some(s.clone()),
                        _ => None,
                    },
                },
            );
        }
        let mut professions = HashMap::new();
        for (name, levels) in json.field("professions")?.entries()? {
            let mut by_level = Vec::new();
            for (level, set) in levels.entries()? {
                let set = set.as_str()?.to_string();
                if !sets.contains_key(&set) {
                    return Err(format!("profession {name} names unknown set {set}"));
                }
                by_level.push((level.parse::<i32>().map_err(|e| e.to_string())?, set));
            }
            by_level.sort();
            professions.insert(name.clone(), by_level);
        }
        let wandering = json
            .field("wandering_trader")?
            .as_array()?
            .iter()
            .map(|s| s.as_str().map(str::to_string))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Trades {
            trades,
            sets,
            professions,
            wandering,
        })
    }

    fn cost(json: &Json) -> Result<TradeCost, String> {
        let potion = match json.get("components") {
            None => None,
            Some(components) => {
                let mut potion = None;
                for (component, value) in components.entries()? {
                    match component.as_str() {
                        "minecraft:potion_contents" => {
                            potion = Some(value.field("potion")?.as_str()?.to_string())
                        }
                        other => return Err(format!("trade cost component {other}")),
                    }
                }
                potion
            }
        };
        Ok(TradeCost {
            item: json.field("id")?.as_str()?.to_string(),
            count: match json.get("count") {
                Some(c) => Loot::int_provider(c)?,
                None => IntProvider::Constant(1),
            },
            potion,
        })
    }

    fn trade(loot: &Loot, json: &Json) -> Result<Trade, String> {
        let gives = json.field("gives")?;
        if gives.get("components").is_some() {
            return Err("a trade's given components are not implemented".into());
        }
        let int = |key: &str, default: i32| match json.get(key) {
            Some(v) => Loot::int_provider(v),
            None => Ok(IntProvider::Constant(default)),
        };
        Ok(Trade {
            wants: Self::cost(json.field("wants")?)?,
            additional_wants: json.get("additional_wants").map(Self::cost).transpose()?,
            gives: (
                gives.field("id")?.as_str()?.to_string(),
                gives.get("count").map_or(Ok(1), Json::as_i32)?,
            ),
            max_uses: int("max_uses", 4)?,
            xp: int("xp", 1)?,
            reputation_discount: match json.get("reputation_discount") {
                Some(v) => Loot::float_provider(v)?,
                None => FloatProvider::Constant(0.0),
            },
            predicate: json
                .get("merchant_predicate")
                .map(|p| loot.condition(p))
                .transpose()?,
            modifier: json
                .get("given_item_modifier")
                .map(|m| loot.function(m))
                .transpose()?,
            double_price: json
                .get("double_trade_price_enchantments")
                .map(|e| {
                    loot.holder_set("minecraft:enchantment", e)
                        .map(|h| h.members)
                })
                .transpose()?,
        })
    }

    /// Whether `set` is a trade set.
    pub fn has_set(&self, set: &str) -> bool {
        self.sets.contains_key(set)
    }

    /// The set a profession draws at `level`, or none.
    pub fn profession_set(&self, profession: &str, level: i32) -> Option<&str> {
        self.professions
            .get(profession)?
            .iter()
            .find(|(l, _)| *l == level)
            .map(|(_, s)| s.as_str())
    }

    /// The wandering trader's sets, in the order it draws them.
    pub fn wandering_sets(&self) -> &[String] {
        &self.wandering
    }

    /// A set's random sequence.
    pub fn set_sequence(&self, set: &str) -> Option<&str> {
        self.sets.get(set)?.sequence.as_deref()
    }
}

impl TradeCost {
    /// `toItemCost`.
    fn item_cost(&self, loot: &Loot, ctx: &mut Ctx, additional: i32) -> Cost {
        let count = self
            .count
            .get(ctx)
            .wrapping_add(additional)
            .clamp(0, loot.max_stack(&self.item));
        Cost {
            item: self.item.clone(),
            count,
            potion: self.potion.clone(),
        }
    }
}

impl Loot {
    /// `VillagerTrade.getOffer`.
    fn offer(&self, trade: &Trade, ctx: &mut Ctx) -> Result<Option<Offer>, String> {
        if let Some(p) = &trade.predicate {
            if !p.test(ctx) {
                return Ok(None);
            }
        }
        let mut result = Stack::new(&trade.gives.0);
        result.count = trade.gives.1;
        let mut additional = 0i32;
        if let Some(m) = &trade.modifier {
            result = self.apply(m, result, ctx)?;
            if result.is_empty() {
                return Ok(None);
            }
        }
        if let Some(extra) = result.additional_trade_cost.take() {
            additional = additional.wrapping_add(extra);
        }
        if let Some(set) = &trade.double_price {
            if result
                .stored_enchantments
                .iter()
                .any(|(e, _)| set.contains(e))
            {
                additional = additional.wrapping_mul(2);
            }
        }
        let buy = trade.wants.item_cost(self, ctx, additional);
        if buy.count < 1 {
            return Ok(None);
        }
        let buy_b = trade
            .additional_wants
            .as_ref()
            .map(|c| c.item_cost(self, ctx, 0));
        if buy_b.as_ref().is_some_and(|b| b.count < 1) {
            return Ok(None);
        }
        Ok(Some(Offer {
            buy,
            buy_b,
            sell: result,
            max_uses: trade.max_uses.get(ctx).max(1),
            xp: trade.xp.get(ctx).max(0),
            price_multiplier: trade.reputation_discount.get(ctx).max(0.0),
        }))
    }

    /// `addOffersFromTradeSet` of `set` for `merchant`, drawing from
    /// `random` (the set's sequence): the offers it adds, in order.
    pub fn trade_offers(
        &self,
        set: &str,
        merchant: &Merchant,
        random: &mut Random,
        world: &mut dyn LootWorld,
    ) -> Result<Vec<Offer>, String> {
        let trades = &self.trades;
        let set = trades
            .sets
            .get(set)
            .ok_or_else(|| format!("unknown trade set {set}"))?;
        let mut ctx = Ctx {
            random: random.clone(),
            luck: 0.0,
            origin: merchant.origin,
            world,
            visited: Vec::new(),
            trade: true,
            death: Some(Death {
                properties: vec![(
                    "minecraft:villager/variant".to_string(),
                    merchant.villager_type.clone(),
                )],
                ..Death::default()
            }),
            block: None,
        };
        let wanted = set.amount.get(&mut ctx);
        let mut left: Vec<&Trade> = set.trades.iter().map(|t| &trades.trades[t]).collect();
        let mut offers = Vec::new();
        while (offers.len() as i32) < wanted && !left.is_empty() {
            let roll = ctx.random.next_int_bounded(left.len() as i32) as usize;
            if set.allow_duplicates {
                match self.offer(left[roll], &mut ctx)? {
                    Some(offer) => offers.push(offer),
                    None => {
                        left.remove(roll);
                    }
                }
            } else {
                let trade = left.remove(roll);
                if let Some(offer) = self.offer(trade, &mut ctx)? {
                    offers.push(offer);
                }
            }
        }
        *random = ctx.random;
        Ok(offers)
    }

    /// The trade facts.
    pub fn trades(&self) -> &Trades {
        &self.trades
    }
}
