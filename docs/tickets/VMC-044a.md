# VMC-044a — Villagers and golems without trades

Status: Done
Milestone: M3
Depends on: [VMC-041b](VMC-041b.md), [VMC-042b](VMC-042b.md).

Villages are populated by generation (VMC-042b):

- villagers with their brain's daily schedule (work, gossip, sleep in beds,
  flee zombies) and professions taken from job sites;
- iron golems guarding them, cats and wandering traders.

Trades, reputation, breeding and raids stay in VMC-044. A villager still
offers no trades.

Slices:

- [VMC-044a1](VMC-044a1.md) — points of interest and a villager's day:
  homes, job sites and the meeting point, the schedule, sleeping in beds,
  professions from job sites, panicking at zombies.
- [VMC-044a2](VMC-044a2.md) — iron golems: their goals, guarding villagers
  and villagers summoning them.
- [VMC-044a3](VMC-044a3.md) — cats: strays and the village's cat
  spawner.
- [VMC-044a4](VMC-044a4.md) — wandering traders and their spawner.

Acceptance:

- A generated village lives through a day and night as the oracle's fixtures
  do.
- Zombies attack villagers, and golems defend them.

All four slices are implemented and match their oracle scenes; each waits on
the client. Their client scenarios make one handoff: a fresh world's plains
village through a day and a night, with a zombie and a golem summoned among
its villagers, its cats and a summoned wandering trader.

## Handoff (October 2026)

Done and on main: the shared brain commit and VMC-044a1 (villagers), 044a2
(iron golems), 044a3 (cats) and 044a4 (wandering traders), each Awaiting
client with its implementation notes, checks and client scenario. Verified
before the push: the affected test files (`villager_region`,
`natural_spawning`, `animal_region`, `mob_*`, `combat`, `hostile_region`,
`full_chunk`) and the oracle stages `village`, `animals`, `ai_facts` and
`animal_facts`. Earlier rebases also passed every `--changed` stage for
044a1 and 044a2; the last broad `--changed` run was cut short at wrap-up,
so the other affected stages (`loot`, `mob_ai`, `hostile_*`) were not re-run
on the final rebase.

Remaining: the one client handoff for all four slices; trades, reputation,
breeding and raids (VMC-044); trader llamas and taming (VMC-043); periodic
effects on mobs; saving the trader spawner's delay and chance with the
level (both custom spawners count per group).

Gotchas: regenerate generated facts per commit after a rebase (a textual
merge of `ai_facts.json` once dropped a new `monster` field from these
entries); `loot/tables.json` is sorted by key. On main,
`Combat.source_info(nil)` (since VMC-043d3) crashes `Store.kill/2` and
`/kill`: three failures in `test/entity_bodies_test.exs`, not fixed here.

Closed with M3 (October 31, 2026): its client observations passed in the [gate run](VMC-078.md#gate-run-on-the-native-mob-core-october-30-2026) and the [VMC-083 run](VMC-083.md#client-run-october-31-release-67a9072e).
