# Feature backlog

Open work only. [Current work](roadmap.md) orders it and says which slices run
in parallel; [completed](history/completed.md) indexes finished tickets. Each
row is refined into tickets before work. Acceptance gates need automated,
actual-client and vanilla reference scenarios.

### M3 — Survival core

The [roadmap](roadmap.md#m3--survival-core-planned) orders these and says which run in
parallel. In every slice:

- Behaviour comes from pinned 26.3 through oracle extractors.
- Mobs belong to the group that owns their section. Physics, AI and trackers
  run once per section per tick, and pathfinding runs as bounded jobs over
  snapshots.
- An entity or shape update without behaviour yet never fails generation.

| ID | Slice | Acceptance gate |
|---|---|---|
| [VMC-043a](tickets/VMC-043a.md) | Entity kinds beyond items and orbs | Generated entity facts; summoned mobs and primed TNT persist, hand off and replicate as in vanilla |
| [VMC-015i](tickets/VMC-015i.md) | Living-entity travel in the kernel | Mob falling, swimming, climbing, step-up and pushing match the oracle; hundreds of mobs per group within budget |
| [VMC-041a](tickets/VMC-041a.md) | Goals, targets, brains and sensors | Goal selection and brain fixtures match the oracle; a shared goal library |
| [VMC-041b](tickets/VMC-041b.md) | Pathfinding and navigation | Paths of the four node evaluators match the oracle; searches never run in the owner |
| [VMC-037n](tickets/VMC-037n.md) | Melee combat, mob death, loot and XP | Attack cooldown, criticals, knockback, armor and shields; mob loot and XP match the oracle |
| [VMC-037o](tickets/VMC-037o.md) | Projectiles | Arrows, thrown items, fireballs and eyes of ender fly and hit as the oracle's fixtures |
| [VMC-050a](tickets/VMC-050a.md) | Explosions, TNT and falling blocks | Craters, damage and knockback match the oracle, committed across group lines at once |
| [VMC-042a](tickets/VMC-042a.md) | Natural spawning and despawning | Spawn attempts, packs, per-player caps and despawn distances match the oracle |
| [VMC-042b](tickets/VMC-042b.md) | Structure mobs and spawners | Structures place their entities; spawners spawn; no generation error for entities |
| [VMC-043b](tickets/VMC-043b.md) | Overworld hostiles | Zombie and skeleton families, creepers, spiders, endermen, witches, slimes, phantoms and silverfish behave as the oracle's fixtures |
| [VMC-043c](tickets/VMC-043c.md) | Farm and passive animals | Breeding, growth, shearing, milking and drops match the oracle |
| [VMC-043d](tickets/VMC-043d.md) | Nether mobs | Piglins (bartering), blazes, ghasts and the rest match the oracle; a fortress yields blaze rods |
| [VMC-043e](tickets/VMC-043e.md) | Water, ambient and End mobs | Fish, squid, dolphins, turtles, axolotls, guardians, bats, shulkers and endermites match the oracle |
| [VMC-044a](tickets/VMC-044a.md) | Villagers and golems without trades | A generated village lives through a day and night as the oracle's fixtures |
| [VMC-029d](tickets/VMC-029d.md) | Survival block states and shape updates | Every obtainable block places in its vanilla state; `ShapeOracle` excludes nothing |
| [VMC-029e](tickets/VMC-029e.md) | Survival mining of every block | Every survival-obtainable block mines with vanilla's break time and drops; none is refused |
| [VMC-031a](tickets/VMC-031a.md) | Water and lava flow | Flow, mixing, sources and buckets match the oracle across group lines |
| [VMC-039a](tickets/VMC-039a.md) | Crops, plants and saplings grow | Growth by random ticks and bone meal matches the oracle |
| [VMC-032b](tickets/VMC-032b.md) | Double chests | Joined chests, the large menu and splitting, across group lines too |
| [VMC-040a](tickets/VMC-040a.md) | Beds, sleep and spawn points | Sleep, night skip, bed respawn, bed and anchor explosions match the oracle |
| [VMC-034n4c](tickets/VMC-034n4c.md) | Experience orb gaps | Orbs merge, jump in lava and launch as vanilla's, checked against the oracle |
| [VMC-026d](tickets/VMC-026d.md) | Eyes of ender; mobs and orbs through portals | Eyes lead to vanilla's stronghold; mobs and orbs cross portals with their state |
| [VMC-045a](tickets/VMC-045a.md) | The Ender Dragon fight | Phases, crystals, the exit portal, gateways and the respawn ritual |
| [VMC-078](tickets/VMC-078.md) | M3 gate | A fresh-world survival run to the dragon's death; no generation errors; every slice's fixtures; tick budget with spawning |

Out of M3: redstone components (VMC-047–049), enchanting, anvils and brewing,
villager trading, POIs and raids, vehicles and riding (VMC-046), maps, books
and signs, advancements, and the remaining command families.

### A — Session and protocol

| ID | Slice | Acceptance gate |
|---|---|---|
| VMC-004b | Recursive and collection item components | Container, bundle contents, charged projectiles, attribute modifiers and the remaining component codecs; bounded, with oracle round trips |
| VMC-006 | Remaining gamerules | The full 26.3 gamerule set stored, sent and enforced where its system exists |
| VMC-008 | Data-pack registries and reload | Pack registries and tags sent to clients, play-phase reconfiguration and `/reload` without stale caches |
| VMC-009 | Signed chat and command signatures | Profile keys, vanilla validation and acknowledgments, verified command signatures, proxy policy ([VMC-007c](tickets/VMC-007c.md)) |
| VMC-016b2 | Live mode transitions and spectator visibility | Spectator camera and teleport, mode switches end item use, spectators hidden from peers as vanilla |

### D — Blocks, items and survival economy

| ID | Slice | Acceptance gate |
|---|---|---|
| VMC-030 | Behaviour catalog | Every 26.3 block's behaviour tracked in one coverage matrix (VMC-029d starts it) |
| VMC-031 | Fire spread and burnout | Fire spreads, burns blocks out and goes out as vanilla (flow is VMC-031a) |
| VMC-032 | Remaining containers | Barrels, shulker boxes, ender chests and the rest; an occupied furnace's removal ([VMC-034f](tickets/VMC-034f.md)) |
| VMC-033 | Recipe book and special recipes | Recipe book state, `place_recipe` autofill, special and component crafting outputs |
| VMC-034 | Brewing and other processing blocks | Brewing stands and the processing blocks beyond the three furnaces |
| VMC-037 | Remaining effects and enchantments | Every 26.3 effect and enchantment behaviour (melee and projectiles are VMC-037n and 037o) |
| VMC-038 | Enchanting, anvils, grindstones and smithing | Costs and randomness, repairs and transaction persistence |
| VMC-039 | Weather effects | Snow and ice forming, lightning and thunder effects (growth is VMC-039a) |

### E — Entities, machines and coupled mechanics

| ID | Slice | Acceptance gate |
|---|---|---|
| VMC-043 | Mob families beyond M3 | Taming (wolves, cats, parrots), horses and llamas, bees, foxes, goats, frogs, camels, armadillos, sniffers, breezes and the rest; every 26.3 entity tracked |
| VMC-044 | Villager trades, POIs and raids | Trades and restocks, reputation, breeding, raids and cross-region transfers (villagers live from VMC-044a) |
| VMC-045 | The wither and special entities | The wither, the warden and 26.3 variants and archetypes with durable lifecycle (the dragon is VMC-045a) |
| VMC-046 | Boats, minecarts, mounts and pushing | Rails/vehicle physics, passengers, collision, portals and handoff parity |
| VMC-047 | Redstone power and update order | Circuit fixtures, quasi-connectivity, update-sensitive builds and boundaries |
| VMC-048 | Repeaters, comparators, observers and pistons | Tick timing, moving blocks with their geometry in the physics kernel, sticky behavior and block-entity moves |
| VMC-049 | Hoppers, dispensers and droppers | Ordered inventory transfers; no duplication with parallel region ticks |
| VMC-051 | Maps, books, signs, sounds and game events | Bounded content, client metadata updates, banners and persistent data; exploration maps from container loot (VMC-072c) |
| VMC-052 | Advancements, statistics and scoreboards | Triggers/rewards/criteria, objectives, persistence and visibility |

### F — Operations, extensibility and qualification

| ID | Slice | Acceptance gate |
|---|---|---|
| [VMC-053](tickets/VMC-053.md) | Vanilla command families | Parsers/selectors/permissions/suggestions, command blocks/functions and exact errors |
| VMC-054 | Resource packs, dialogs and custom payloads | Current negotiation/UI codecs and bounded processing |
| VMC-055 | Upgrades, backups, recovery and shutdown | Tested migration/rollback and durable acknowledged world/player state |
| VMC-056 | Metrics, tracing and tick profiling | Per-owner queues, reductions/GC, latency and reproducible workload records |
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
redstone does not establish vanilla semantics.
F: complete compatibility matrix, operational recovery and matched performance
qualification, with every deviation documented.

No deadline or fastest-server claim is attached to this backlog. Optimize measured
bottlenecks with compact owner-local state, immutable binary sharing, ETS
observations, batched replication, bounded pure jobs and I/O workers. Introduce
native acceleration or clustering only with profiling and a defined failure/
consistency model. Bedrock and Java plugin compatibility are separate future scopes.
