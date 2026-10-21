# Feature backlog

Implementation order is flexible. [Current priorities and pending gates](roadmap.md)
come first: milestone M1 (VMC-062..069) rebuilds the foundations before more features.


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
| VMC-004a | Optional stacks and scalar components | Both trusted and untrusted encodings; corrected unsupported creative edits, precise item defaults |
| VMC-004b | Structured components | Bounded NBT/text, collections, recursive items and registry holders; expanded vanilla oracle cases |
| VMC-004b1 | Network NBT/custom data | Modified UTF-8, all tag payloads and dense arrays; bounded independent oracle round trips |
| VMC-004b2 | Text, enchantments and effective components | Versioned schema validation, registry holders, equal-default patch normalization and tooltip/client preservation |
| VMC-005 | Authoritative inventory transactions | State IDs, slots, click/drag/shift/hotbar/drop, full inventory persistence and menus |
| VMC-005a | Session inventory foundation | Full player slots, startup synchronization, creative writes and carried selection are owner-local |
| VMC-005b | Inventory click transactions | Vanilla hashed prediction, authoritative click/drag/shift/hotbar/drop and corrections |
| VMC-005b1 | Basic inventory clicks | Bounded prediction parsing; pickup/split/merge/shift/swap conserve authoritative state |
| VMC-005b2 | Remaining click lifecycle | Drag, collection, close/return and item-entity drops match vanilla |
| VMC-005c | Inventory persistence | Validated components/slots survive reconnect and graceful restart; corrupt state stays isolated |
| VMC-006 | Play initialization and world defaults | Clocks, weather, difficulty and gamerules match the 26.3 packet/state model |
| VMC-007 | Session authentication and encryption | Official online-mode join, AES/compression interoperability, invalid sessions rejected |
| VMC-008 | Registry/data-pack negotiation and reload | Features, tags, components, known packs and reconfiguration; no stale caches |
| VMC-009 | Signed chat and command signatures | Vanilla validation/acknowledgments, argument suggestions, no fabricated signatures |
| VMC-010 | Configuration, administration and permissions | Console/RCON, operators, bans/whitelist; checks precede every mutation |

### B — Authoritative simulation and ownership

| ID | Slice | Acceptance gate |
|---|---|---|
| VMC-011 | Deterministic region ticks | Explicit tick phases/order; reproducible traces across scheduler counts |
| [VMC-011a](tickets/VMC-011a.md) | Authoritative ownership and phases | Connection/simulation separation, bounded owner-local work and explicit neighbor/transfer ordering |
| [VMC-011a3](tickets/VMC-011a3.md) | Owner-fenced block commits | Bounded atomic owner-local edits, shared native section updates and loaded-chunk filtering |
| [VMC-011a8](tickets/VMC-011a8.md) | Geometry admission at larger loads | Profile/fix the retained 512-player deadline finding; preserve validated movement and matched measurements |
| VMC-012 | Region boundary protocol and entity transfer | Tick-tagged inputs/snapshots, epochs/fencing, no duplicated or lost entities |
| VMC-013 | Chunk/entity tickets and unload lifecycle | Loaded dependency guarantees, bounded resident memory, safe save/unload |
| VMC-014 | Block shapes and movement validation | Vanilla collision/step/swim/climb/teleport fixtures, reconciliation under latency |
| [VMC-014a](tickets/VMC-014a.md) | Cached block collision geometry | Complete cached state catalog, explicit dynamic contexts, native grid clipping and actual client contact fixtures |
| VMC-014b | Contextual shapes and bounded owner queries | Entity/world-dependent geometry, fenced region reads and boundary consistency |
| [VMC-014b1](tickets/VMC-014b1.md) | Position-dependent shapes | Native offsets and all 52 bamboo/dripstone/sulfur-spike states |
| [VMC-014b2](tickets/VMC-014b2.md) | Scaffolding contexts | Native placement/descent/feet-height rules across all 32 states |
| [VMC-014b3](tickets/VMC-014b3.md) | Powder-snow contexts | Fall distance, falling-block identity, walkable tags and leather boots |
| [VMC-014b4](tickets/VMC-014b4.md) | Shulker-box snapshots | Native lid geometry; unavailable vs confirmed block-entity observations |
| VMC-014b5 | Moving-piston snapshots | Native movement state/shape unions and query direction context |
| [VMC-014b5a](tickets/VMC-014b5a.md) | Voxel unions | Native coordinate merging/optimization and bounded pure grid operations |
| [VMC-014b5b](tickets/VMC-014b5b.md) | Moving-piston geometry | Native displacement, source heads/base unions and query movement exclusion |
| [VMC-014b6a](tickets/VMC-014b6a.md) | Region block observations | Bounded state batches, owner incarnation and optimistic revision checks |
| [VMC-014b6b](tickets/VMC-014b6b.md) | Block scan candidates | Native epsilon bounds/cursor order and large-shape face/piston-edge rules |
| VMC-014b6c | Collider intersection and collection | Native strict/full-shape and voxel epsilon overlap; preserve missing context and snapshot fences |
| [VMC-014b6c1](tickets/VMC-014b6c1.md) | Voxel intersection | Native overlap-only coordinate mappings and occupied-grid AND |
| [VMC-014b6c2](tickets/VMC-014b6c2.md) | Supplied-observation collider collection | Ordered candidate filtering, strict full-block shortcut, explicit missing states/contexts and retained observation fences |
| [VMC-014b6d](tickets/VMC-014b6d.md) | Live collider observations | Bounded concurrent existing-owner queries, consistent per-region batches, height bounds and cancellation |
| VMC-014c | Movement and pose reconciliation | Native pose dimensions/eye heights, collision/step validation and actual client corrections |
| [VMC-014c1](tickets/VMC-014c1.md) | Axis-ordered clipping | Native supplied-shape movement, horizontal ties, corners and slides |
| [VMC-014c2](tickets/VMC-014c2.md) | Step-up selection | Native float32 height candidates, lowered start/query box and first improving movement |
| [VMC-014c3a](tickets/VMC-014c3a.md) | Input and shared flags | Native input/command/load semantics, bounded self/peer replication and actual held-key checks |
| VMC-014c3b | Pose selection and dimensions | Native pose precedence, fit checks and eye heights; separate intent from selected collision pose |
| [VMC-014c3b1](tickets/VMC-014c3b1.md) | Supplied-fit pose primitives | Native dimensions/boxes, precedence, fit-query order and explicit missing observations |
| VMC-014c3b2 | Live pose fitting and replication | Entity/block/border observations, fencing and metadata; update interactions only after authoritative selection |
| [VMC-014c3b2a](tickets/VMC-014c3b2a.md) | Entity collider collection | Native lookup margins/predicates and bounded complete supplied observations |
| VMC-014c3b2b | Live fitting and publication | Complete occupancy, owner-fenced reads, bounded connection jobs and selected-pose metadata |
| [VMC-014c3b2b1](tickets/VMC-014c3b2b1.md) | Supplied pose fitting | Compose block/entity/border predicates, lazy native selection and retained observation fences |
| VMC-014c3b2b2 | Live selection and publication | Consistent owner reads/commit fencing, bounded connection jobs and selected-pose metadata |
| VMC-015 | Gravity, velocity and grounded state | Authoritative fall distance, acceleration, knockback and prediction agreement |
| VMC-016 | Game modes and abilities | Survival/creative/adventure/spectator interaction and UI rules |
| [VMC-016a](tickets/VMC-016a.md) | Owned abilities and persistent creative flight | Native matrix/codecs, permission-gated client flight, journal/reconnect/restart and actual double-Space |
| VMC-016b | Mode transitions and interaction permissions | Persistent modes, client UI/peer transitions, spectator restrictions and survival/adventure gates |
| [VMC-016b1](tickets/VMC-016b1.md) | Saved mode and login foundations | All four native modes initialize consistently; persisted identity and existing interaction gates |
| VMC-016b2 | Live mode transitions and spectator visibility | Collision-aware flight, attributes, peer metadata, camera and item-use lifecycle |
| VMC-017 | Health, damage, death and respawn | Causes/cooldowns/drops, spawn points, persistent lifecycle |
| VMC-018 | Entity metadata, attributes and passengers | Current serializers, equipment, visibility transitions, spawn/change/despawn |
| [VMC-018c1](tickets/VMC-018c1.md) | Default player interaction ranges | Native attributes/codecs, strict block-box reach/hit bounds and actual client targeting |
| VMC-019 | Durable simulation recovery | No duplicate acknowledged transactions after player/region failures or restart |

### C — Vanilla worlds and storage

| ID | Slice | Acceptance gate |
|---|---|---|
| [VMC-020](tickets/VMC-020.md) | NBT and versioned world schemas | Bounded corrupt/malicious input; golden vanilla round trips |
| VMC-021 | Anvil chunk/entity/region storage | Import/export, sector reuse, negative coordinates, crash-safe writes |
| VMC-022 | Heightmaps and light propagation | Skylight/block light, emissive/opaque edits and chunk-boundary parity |
| VMC-023 | Biome/noise sampling and seed RNG | Same seed/settings/arithmetic match vanilla sample fixtures |
| VMC-024 | Terrain, carvers, aquifers and surfaces | Block-for-block differential chunks across seeds/dimensions |
| VMC-025 | Structures and decorations | Seed/order parity for structures, features, ores and bounded generation dependencies |
| VMC-026 | Nether, End and portals | Dimension lifecycle, coordinates/tickets, beds/anchors, entity/player transitions |
| [VMC-027](tickets/VMC-027.md) | World border and spawn search | Vanilla border ticks, packets, damage and commands; vanilla world spawn for several seeds |
| [VMC-027a](tickets/VMC-027a.md) | Supplied stationary border geometry | Native bounds/containment/proximity and collision planes; live synchronization/resizing remain |
| VMC-028 | Generation/data-pack configuration | Registry reload/version upgrade with deterministic generation caches |

### D — Blocks, items and survival economy

| ID | Slice | Acceptance gate |
|---|---|---|
| VMC-029 | Placement, use, mining and neighbor updates | Replaceable/oriented blocks, reach, tools/speeds/drops and authoritative acknowledgments; blocks that lose support (plants, torches) break as in vanilla |
| VMC-030 | Scheduled/random ticks and behavior catalog | Priority/order/RNG/chunk activation; every 26.3 block tracked in a coverage matrix |
| VMC-031 | Fluids, waterlogging and fire | Propagation, sources, mixing, spread/extinguishing, cross-region fixtures; generated chunks' fluid post-processing marks (VMC-024d) |
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
| [VMC-053](tickets/VMC-053.md) | Vanilla command families | Parsers/selectors/permissions/suggestions, command blocks/functions and exact errors |
| VMC-054 | Resource packs, dialogs and custom payloads | Current negotiation/UI codecs and bounded processing |
| VMC-055 | Upgrades, backups, recovery and shutdown | Tested migration/rollback and durable acknowledged world/player state |
| VMC-056 | Metrics, tracing and tick profiling | Per-owner queues, reductions/GC, latency and reproducible workload records |
| VMC-057 | Malformed/abusive clients and load matrix | No cross-player failures, retry storms or unbounded work/allocation |
| VMC-058 | Supervised Elixir extension API | Versioned contracts, explicit authorized mutations, bounded callbacks and isolation |
| VMC-059 | Measured performance optimization | Matched feature coverage/workloads against vanilla, Paper/Folia and relevant rewrites |
| VMC-060 | Release and compatibility certification | Every block/item/entity/menu/mechanic/command/gamerule has a tested coverage status |

### M1 — Foundations (precede C–F)

| ID | Slice | Acceptance gate |
|---|---|---|
| [VMC-062](tickets/VMC-062.md) | Rust NIF toolchain and paletted section storage | Edit map removed; byte-identical chunk packets; memory and encode benchmarks |
| VMC-063 | Region persistence v2 | Dirty-section deltas, group commit, directory fsync, no tick pauses on I/O |
| VMC-064 | Owner-transaction engine | One idempotent transaction/permit/outbox primitive replaces per-feature sets |
| VMC-065 | Published section snapshots | Collision and observation reads skip owner mailboxes; fences preserved |
| VMC-066 | Tick pipeline on game time | Steppable clock, scheduled/random ticks, deterministic tests |
| VMC-067 | Generic entity model | Items and XP orbs share one entity lifecycle and replication path |
| VMC-068 | Unified registry and block behaviours | One generated fact source and version module; behaviour callbacks |
| VMC-069 | Connection decomposition | Codec/login/job/replication modules; encode-once fan-out; slim peer views |

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

## Partial subsystem records

These parent entries are not completion claims; see their child tickets.

| Parent | Status |
|---|---|
| VMC-004b | Planned |
| VMC-004b2 | Partially implemented |
| VMC-006 | Partially implemented |
| VMC-007c | Partially implemented |
| VMC-005b | Planned |
| VMC-005b2 | Planned |
| VMC-005b2d | Partially implemented |
| VMC-005b2d2 | Partially implemented |
| VMC-005c | Partially implemented |
| VMC-019b | In progress foundations |
| VMC-019b3 | Partially implemented |
| VMC-019b3d | Connected preview validated |
