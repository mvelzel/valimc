# VMC-044c — Villager life

Status: Awaiting client
Milestone: M4
Depends on: [VMC-044b](VMC-044b.md).

Villagers trade (VMC-044b) but remember nothing of players, never breed
and never turn. After this ticket they keep vanilla's gossip about
players, which prices and iron golems read; they eat and breed with beds
and food; and a zombie's villager turns into a zombie villager that a
player can cure.

Slices:

- [VMC-044c1](VMC-044c1.md) — gossip and reputation: `GossipContainer`,
  the reputation events (trades, hurts, murders a villager witnesses,
  cures), gossip shared as villagers meet and decaying daily, reputation
  in prices, and iron golems turning on players villagers hate.
- [VMC-044c2](VMC-044c2.md) — food and breeding: a villager's inventory
  and the food it picks up and shares, its food level, `VillagerMakeLove`
  with a free bed, and the baby.
- [VMC-044c3](VMC-044c3.md) — zombification and curing: a villager a
  zombie kills turns (by difficulty) into a zombie villager that keeps its
  data, offers, gossip and experience; Weakness and a golden apple cure it
  after its conversion time, with the cure's gossip.

Acceptance (the backlog row): breeding with beds and food, gossip and
reputation, discounts, zombification and curing match the oracle.

Farming (harvesting, planting, bone meal, the composter) stays out: food
reaches villagers from players, as items they pick up.

## Handoff

All three slices are live: gossip, prices and golems read reputation
(044c1), villagers eat, share food and breed with a free bed (044c2), and
zombies turn villagers that a player can cure (044c3). The client
scenarios are in each slice's Awaiting client section; one session can
run them in order on one village (trade and punch for gossip, feed two
villagers bread beside a bed, then the hard-difficulty kill and the cure).

