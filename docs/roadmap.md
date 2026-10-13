# Minecraft Java 26.3 implementation roadmap

Updated: October 13, 2026. Target: vanilla survival compatibility, protocol 777.
Runtime: Elixir 1.20.4 / OTP 29.1.1. Baseline: `4495775`.

Vanilla defines exact behavior; Paper contributes compatibility edge cases;
Pumpkin, SteelMC and other implementations contribute subsystem/design ideas.
See `research.md`, `development.md` and root `AGENTS.md`. Unchecked entries are
not implemented. Split large entries into bounded sub-tickets before starting;
keep IDs stable and append suffixes rather than renumbering.

## Current board

| Ticket | Status | Outcome / next gate |
|---|---|---|
| [VMC-001](tickets/VMC-001.md) | Verified; publication pending | 17 tests/oracle/release/audit pass; regenerated helper and real-client restart/join/render/stats pass |
| [VMC-002](tickets/VMC-002.md) | Ready after 001 | Advertise the actual custom commands; validate GUI completion/execution |
| VMC-003 | Planned | Validated player pose survives reconnect and graceful restart |
| VMC-004 | Planned | Versioned item/component codecs and synchronized creative slots |

Only one implementation ticket is active. Records retain acceptance criteria,
checks, manual evidence and commit subject; Git history supplies checkpoint SHAs.
Pushing a ticket does not declare a milestone or the whole server complete.

## Existing foundation

Implemented preview: bounded TCP sessions, status/offline login/compression,
vanilla core-pack registries/tags, flat chunk streaming, creative movement,
nearby entity replication, simple creative block edits, custom block snapshots
and `/help`, `/stats`, `/spawn`. Region tick deadlines contain no survival
simulation. The initial 17 tests, Mojang oracle and limited load benchmarks cover
this preview only. Authentication, physics, item components, Anvil, generation,
lighting, AI, redstone, fluids and full survival remain unimplemented.

## Ordered backlog

Each milestone depends on the relevant preceding ownership/state foundations.
Acceptance gates require automated, actual-client and appropriate vanilla
reference scenarios. Individual dependencies are refined in a ticket before work.

### A — Session and player foundations

| ID | Slice | Acceptance gate |
|---|---|---|
| VMC-001 | Development workflow and broader reference survey | Agent instructions, private-reference audit, reproducible computer use, verified baseline |
| VMC-002 | Custom command graph | Official decoder and actual-client completion/execution agree with the command catalog |
| VMC-003 | Player pose persistence | Reconnect and graceful restart restore validated pose; corrupt data and I/O failures stay isolated |
| VMC-004 | Item-stack and component codecs | Mojang round trips, bounded malformed inputs; unsupported state never silently desynchronizes |
| VMC-005 | Authoritative inventory transactions | State IDs, slots, click/drag/shift/hotbar/drop, full inventory persistence and menus |
| VMC-006 | Play initialization and world defaults | Clocks, weather, difficulty and gamerules match the 26.3 packet/state model |
| VMC-007 | Session authentication and encryption | Official online-mode join, AES/compression interoperability, invalid sessions rejected |
| VMC-008 | Registry/data-pack negotiation and reload | Features, tags, components, known packs and reconfiguration; no stale caches |
| VMC-009 | Signed chat and command signatures | Vanilla validation/acknowledgments, argument suggestions, no fabricated signatures |
| VMC-010 | Configuration, administration and permissions | Console/RCON, operators, bans/whitelist; checks precede every mutation |

### B — Authoritative simulation and ownership

| ID | Slice | Acceptance gate |
|---|---|---|
| VMC-011 | Deterministic region ticks | Explicit tick phases/order; reproducible traces across scheduler counts |
| VMC-012 | Region boundary protocol and entity transfer | Tick-tagged inputs/snapshots, epochs/fencing, no duplicated or lost entities |
| VMC-013 | Chunk/entity tickets and unload lifecycle | Loaded dependency guarantees, bounded resident memory, safe save/unload |
| VMC-014 | Block shapes and movement validation | Vanilla collision/step/swim/climb/teleport fixtures, reconciliation under latency |
| VMC-015 | Gravity, velocity and grounded state | Authoritative fall distance, acceleration, knockback and prediction agreement |
| VMC-016 | Game modes and abilities | Survival/creative/adventure/spectator interaction and UI rules |
| VMC-017 | Health, damage, death and respawn | Causes/cooldowns/drops, spawn points, persistent lifecycle |
| VMC-018 | Entity metadata, attributes and passengers | Current serializers, equipment, visibility transitions, spawn/change/despawn |
| VMC-019 | Durable simulation recovery | No duplicate acknowledged transactions after player/region failures or restart |

### C — Vanilla worlds and storage

| ID | Slice | Acceptance gate |
|---|---|---|
| VMC-020 | NBT and versioned world schemas | Bounded corrupt/malicious input; golden vanilla round trips |
| VMC-021 | Anvil chunk/entity/region storage | Import/export, sector reuse, negative coordinates, crash-safe writes |
| VMC-022 | Heightmaps and light propagation | Skylight/block light, emissive/opaque edits and chunk-boundary parity |
| VMC-023 | Biome/noise sampling and seed RNG | Same seed/settings/arithmetic match vanilla sample fixtures |
| VMC-024 | Terrain, carvers, aquifers and surfaces | Block-for-block differential chunks across seeds/dimensions |
| VMC-025 | Structures and decorations | Seed/order parity for structures, features, ores and bounded generation dependencies |
| VMC-026 | Nether, End and portals | Dimension lifecycle, coordinates/tickets, beds/anchors, entity/player transitions |
| VMC-027 | World border and spawn search | Vanilla height/build limits and positive/negative/unloaded-boundary outcomes |
| VMC-028 | Generation/data-pack configuration | Registry reload/version upgrade with deterministic generation caches |

### D — Blocks, items and survival economy

| ID | Slice | Acceptance gate |
|---|---|---|
| VMC-029 | Placement, use, mining and neighbor updates | Replaceable/oriented blocks, reach, tools/speeds/drops and authoritative acknowledgments |
| VMC-030 | Scheduled/random ticks and behavior catalog | Priority/order/RNG/chunk activation; every 26.3 block tracked in a coverage matrix |
| VMC-031 | Fluids, waterlogging and fire | Propagation, sources, mixing, spread/extinguishing, cross-region fixtures |
| VMC-032 | Block entities and container menus | Persistent contents, transactional interactions and correct lifecycle/metadata |
| VMC-033 | Crafting and recipe-book synchronization | Every recipe family, consumption/remainders, UI state agreement |
| VMC-034 | Furnaces, brewing and processing blocks | Fuel/progress/output, concurrent automation, restart behavior |
| VMC-035 | Item entities, pickups and durability | No lost/duplicated items under concurrent pickup, failures or reconnect |
| VMC-036 | Hunger, exhaustion and regeneration | Deterministic vanilla timelines with difficulty/gamerules |
| VMC-037 | Combat, projectiles, effects and enchantments | Hits, armor, shields, cooldowns, knockback and component semantics |
| VMC-038 | XP, enchanting, anvils and smithing | Costs/RNG, repairs, grindstones and transaction persistence |
| VMC-039 | Farming, growth and environmental behavior | Plant families, weather, freezing/snow/thunder and biome rules |
| VMC-040 | Sleeping and spawn points | Multiplayer quorum, dimension restrictions, time transitions and safe respawn |

### E — Entities, machines and coupled mechanics

| ID | Slice | Acceptance gate |
|---|---|---|
| VMC-041 | AI sensors, brains and bounded pathfinding | Owner snapshots/pure jobs; stale results rejected; vanilla behavior fixtures |
| VMC-042 | Spawning, despawning and mob caps | Category/biome/time/distance rules and deterministic tick ownership |
| VMC-043 | Passive/hostile/water/ambient mob families | Split into family tickets; every 26.3 entity behavior/loot/interaction tracked |
| VMC-044 | Villagers, POIs, trades and raids | Restocks, reputation, breeding, raid state and cross-region transfers |
| VMC-045 | Bosses and current special entities | Dragon/wither/End progression and 26.3 variants/archetypes with durable lifecycle |
| VMC-046 | Boats, minecarts, mounts and pushing | Rails/vehicle physics, passengers, collision, portals and handoff parity |
| VMC-047 | Redstone power and update order | Circuit fixtures, quasi-connectivity, update-sensitive builds and boundaries |
| VMC-048 | Repeaters, comparators, observers and pistons | Tick timing, moving blocks, sticky behavior and block-entity moves |
| VMC-049 | Hoppers, dispensers and droppers | Ordered inventory transfers; no duplication with parallel region ticks |
| VMC-050 | Explosions, TNT and falling blocks | Ray selection, damage/knockback/drops and consistent affected-state publication |
| VMC-051 | Maps, books, signs, sounds and game events | Bounded content, client metadata updates, banners and persistent data |
| VMC-052 | Advancements, statistics and scoreboards | Triggers/rewards/criteria, objectives, persistence and visibility |

### F — Operations, extensibility and qualification

| ID | Slice | Acceptance gate |
|---|---|---|
| VMC-053 | Vanilla command families | Parsers/selectors/permissions/suggestions, command blocks/functions and exact errors |
| VMC-054 | Resource packs, dialogs and custom payloads | Current negotiation/UI codecs and bounded processing |
| VMC-055 | Upgrades, backups, recovery and shutdown | Tested migration/rollback and durable acknowledged world/player state |
| VMC-056 | Metrics, tracing and tick profiling | Per-owner queues, reductions/GC, latency and reproducible workload records |
| VMC-057 | Malformed/abusive clients and load matrix | No cross-player failures, retry storms or unbounded work/allocation |
| VMC-058 | Supervised Elixir extension API | Versioned contracts, explicit authorized mutations, bounded callbacks and isolation |
| VMC-059 | Measured performance optimization | Matched feature coverage/workloads against vanilla, Paper/Folia and relevant rewrites |
| VMC-060 | Release and compatibility certification | Every block/item/entity/menu/mechanic/command/gamerule has a tested coverage status |

## Milestone gates and concurrency constraints

A: persistent synchronized player/inventory state and authenticated client
sessions. Until authentication is complete, default to loopback/offline testing.
B: mutations have authoritative owners and an explicit cross-region protocol;
replication snapshots do not substitute for gameplay truth.
C: vanilla worlds round-trip and selected seeds match terrain, structures, biomes
and light; a flat generator is not evidence of this gate.
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
