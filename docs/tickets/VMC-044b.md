# VMC-044b — Professions and trades

Status: In progress
Milestone: M4
Depends on: [VMC-044a](VMC-044a.md), [VMC-072](VMC-072.md) (the loot evaluator).

Villagers with a job site wear their profession (VMC-044a1) but offer
nothing. After this ticket a player trades with villagers and wandering
traders as in vanilla 26.3: offers drawn from the generated trade sets, the
merchant menu, trade experience and levels, restocks at the job site and
demand pricing.

26.3 makes trades data: `villager_trade` and `trade_set` registries (the
data pack's JSON, 391 trades in 83 sets), each trade a loot-style template
(costs as context number providers, a `merchant_predicate` such as the
villager's variant, `given_item_modifier` functions: random and levelled
enchantments, potions, dyes, stews, exploration maps). A set draws its
offers from a server-wide random sequence named by the set
(`MinecraftServer.getRandomSequence`), not from the villager's random.

Slices:

- [VMC-044b1](VMC-044b1.md) — trade facts, random sequences and offers:
  the oracle's trade data, `RandomSequences`, a villager's and a wandering
  trader's offers drawn as vanilla draws them and saved with the mob.
- [VMC-044b2](VMC-044b2.md) — the merchant menu and trading: opening it,
  the offers packet, selecting a trade, the payment and result slots, a
  trade's uses, experience, the orb, levels and new offers, closing; the
  villager following its trading player; durable trades.
- [VMC-044b3](VMC-044b3.md) — restocks and prices: restocking at the job
  site twice a day, demand, special prices (reputation, Hero of the
  Village), the unhappy villager.

Acceptance (the backlog row):

- Workstation claims, offers, the trading menu, experience and levels,
  restocks and demand pricing match the oracle.
- A trade is one group frame: the player's inventory, the villager's
  offers, experience and level and the orb are durable together or not at
  all, so a crash never loses or duplicates an emerald or an item.

Workstation claims and professions came with VMC-044a1; this ticket keeps
them and checks them again with trades in its oracle scenes.

Ownership: a villager belongs to the group of its section; the trading
player stands within 4 blocks of it (`stillValid`), so the player's session
is hosted by the same group and a trade is a call inside it. Random
sequences have one owner per world (VMC-044b1).
