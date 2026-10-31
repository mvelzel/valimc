# Feature backlog

Open work only. [Current work](roadmap.md) orders it and says which slices run
in parallel; [completed](history/completed.md) indexes finished tickets. Each
row is refined into tickets before work. Acceptance gates need automated,
actual-client and vanilla reference scenarios.

### M4 — Survival progression

M3 ([VMC-078](tickets/VMC-078.md)) is done. M4 makes survival worth
continuing: experience spent on enchantments, gear repaired and upgraded,
potions brewed, villages traded with and defended. The
[roadmap](roadmap.md#m4--survival-progression-in-progress) orders these and
says which run in parallel. In every slice:

- Behaviour comes from pinned 26.3 through oracle extractors: enchantment
  and potion data from the generated registries, offers, costs and random
  draws checked against fixtures.
- Menus are durable transactions: a crash never loses or duplicates an
  item, a level or an emerald.
- Villagers, raids and illagers belong to the group that owns their section,
  and a raid crosses group lines through the shared transaction primitives.

| ID | Slice | Acceptance gate |
|---|---|---|
| [VMC-085](tickets/VMC-085.md) | M3 leftovers | The playing-dead axolotl heals as vanilla; dolphin guidance and the cat on the client; `/gamerule mob_griefing`, `/effect … saturation` and `/item replace` |
| VMC-006a | Stored game rules | Every 26.3 game rule stored with the world, sent where the client reads it and enforced where its system exists; `/gamerule` runs them all |
| VMC-037p | Every status effect | Every 26.3 effect's mechanics on players and mobs (haste, invisibility and glowing, luck, the omens, Hero of the Village, wind charged, weaving, oozing, infested and the rest) match the oracle |
| [VMC-037q](tickets/VMC-037q.md) | Enchantment effects | Every 26.3 enchantment works on tools, weapons, armour, bows, crossbows, tridents and maces through the generated effect components, checked against the oracle |
| [VMC-038a](tickets/VMC-038a.md) | Enchanting table | Bookshelf power, offered enchantments and the enchantment seed, lapis and level costs match the oracle |
| VMC-038b | Anvils and grindstones | Repair, combining, renaming, prior-work penalty and "Too Expensive!"; anvil wear and falling anvils; the grindstone's removal and experience; checked against the oracle |
| VMC-038c | Smithing | Netherite upgrades and armour trims with templates match the oracle |
| VMC-034o | Brewing and potions | Brewing stand fuel, recipes and timing; splash and lingering potions, clouds and tipped arrows; cauldrons with potions and hoppers on the stand, matching the oracle |
| VMC-004b | Recursive and collection item components | Container, bundle and attribute-modifier components and the rest of the codecs, bounded, with oracle round trips; a destroyed item holding them drops its contents |
| VMC-032c | Remaining containers | Shulker boxes keep contents broken and carried, ender chests per player, barrels and the rest of 26.3's containers; an occupied furnace's removal ([VMC-034f](tickets/VMC-034f.md)) |
| VMC-044b | Professions and trades | Workstation claims, offers, the trading menu, experience and levels, restocks and demand pricing match the oracle; durable trades |
| VMC-044c | Villager life | Breeding with beds and food, gossip and reputation, discounts, zombification and curing match the oracle |
| VMC-044d | Illagers and patrols | Pillagers, vindicators, evokers with vexes and fangs, ravagers and the totem; outposts and patrols; ominous bottles, matching the oracle |
| VMC-044e | Raids | Bad Omen into a raid, waves by difficulty, the bell, Hero of the Village and a raid across group lines, durable through restarts |
| [VMC-084](tickets/VMC-084.md) | M4 gate | A fresh-world progression run with enchanting, upgrades, brewing, trades and a won raid; all fixtures; persistence; the raid tick budget |

Out of M4 (M5 and later): vehicles and riding (VMC-046), taming and the
remaining mob families (VMC-043), the wither and warden (VMC-045), maps,
books and signs (VMC-051), advancements (VMC-052), fire spread (VMC-031),
weather effects (VMC-039) and the remaining command families.

### A — Session and protocol

| ID | Slice | Acceptance gate |
|---|---|---|
| VMC-008 | Data-pack registries and reload | Pack registries and tags sent to clients, play-phase reconfiguration and `/reload` without stale caches |
| VMC-009 | Signed chat and command signatures | Profile keys, vanilla validation and acknowledgments, verified command signatures, proxy policy ([VMC-007c](tickets/VMC-007c.md)) |
| VMC-016b2 | Live mode transitions and spectator visibility | Spectator camera and teleport, mode switches end item use, spectators hidden from peers as vanilla |

### D — Blocks, items and survival economy

| ID | Slice | Acceptance gate |
|---|---|---|
| VMC-030 | Behaviour catalog | Every 26.3 block's behaviour tracked in one coverage matrix (VMC-029d starts it) |
| VMC-031 | Fire spread and burnout | Fire spreads, burns blocks out and goes out as vanilla (flow is VMC-031a) |
| VMC-033 | Recipe book and special recipes | Recipe book state, `place_recipe` autofill, special and component crafting outputs |
| VMC-034 | Other processing blocks | The processing blocks beyond the furnaces and brewing stand (brewing is VMC-034o) |
| VMC-039 | Weather effects | Snow and ice forming, lightning and thunder effects (growth is VMC-039a) |

### E — Entities, machines and coupled mechanics

| ID | Slice | Acceptance gate |
|---|---|---|
| VMC-043 | Mob families beyond M3 | Taming (wolves, cats, parrots), horses and llamas, bees, foxes, goats, frogs, camels, armadillos, sniffers, breezes and the rest; every 26.3 entity tracked |
| VMC-045 | The wither and special entities | The wither, the warden and 26.3 variants and archetypes with durable lifecycle (the dragon is VMC-045a) |
| VMC-046 | Boats, minecarts, mounts and pushing | Rails/vehicle physics, passengers, collision, portals and handoff parity |
| VMC-051 | Maps, books, signs, sounds and game events | Bounded content, client metadata updates, banners and persistent data; exploration maps from container loot (VMC-072c) |
| VMC-052 | Advancements, statistics and scoreboards | Triggers/rewards/criteria, objectives, persistence and visibility |

### F — Operations, extensibility and qualification

| ID | Slice | Acceptance gate |
|---|---|---|
| [VMC-053](tickets/VMC-053.md) | Vanilla command families | Parsers/selectors/permissions/suggestions, command blocks/functions and exact errors |
| VMC-054 | Resource packs, dialogs and custom payloads | Current negotiation/UI codecs and bounded processing |
| VMC-055 | Upgrades, backups, recovery and shutdown | Tested migration/rollback and durable acknowledged world/player state |
| [VMC-056](tickets/VMC-056.md) | Metrics, tracing and tick profiling | Interactive profiler: [056a](tickets/VMC-056a.md); latency/tracing and reproducible workload records remain |
| VMC-057 | Malformed/abusive clients and load matrix | No cross-player failures, retry storms or unbounded work/allocation |
| VMC-058 | Supervised Elixir extension API | Versioned contracts, explicit authorized mutations, bounded callbacks and isolation |
| VMC-059 | Measured performance optimization | Matched feature coverage/workloads against vanilla, Paper/Folia and relevant rewrites |
| VMC-060 | Release and compatibility certification | Every block/item/entity/menu/mechanic/command/gamerule has a tested coverage status |

## Milestone gates and concurrency constraints

A: protocol features interoperate with the unmodified client, including
online mode.
D: a persistent survival loop with correct inventory, crafting, health, hunger,
containers, tools and environment.
E: behavior coverage for every current block/item/entity, including machines
across boundaries, handoff, failures and scheduler counts. Simplified fast
redstone does not establish vanilla semantics; this holds for M3's redstone too.
F: complete compatibility matrix, operational recovery and matched performance
qualification, with every deviation documented.

No deadline or fastest-server claim is attached to this backlog. Optimize measured
bottlenecks with compact owner-local state, immutable binary sharing, ETS
observations, batched replication, bounded pure jobs and I/O workers. Introduce
native acceleration or clustering only with profiling and a defined failure/
consistency model. Bedrock and Java plugin compatibility are separate future scopes.
