# Minecraft Java 26.3 implementation roadmap

Updated: October 14, 2026. Target: vanilla survival compatibility, protocol 777.
Runtime: Elixir 1.20.4 / OTP 29.1.1. Baseline: `4495775`.

Vanilla defines exact behavior; Paper contributes compatibility edge cases;
Pumpkin, SteelMC and other implementations contribute subsystem/design ideas.
See `research.md`, `development.md` and root `AGENTS.md`. Unchecked entries are
not implemented. Split large entries into bounded sub-tickets before starting;
keep IDs stable and append suffixes rather than renumbering.

## Current board

| Ticket | Status | Outcome / next gate |
|---|---|---|
| [VMC-001](tickets/VMC-001.md) | Done — `4f948be`, pushed | Workflow and 19-source survey; baseline tests/oracle/release/audit and actual-client smoke pass |
| [VMC-002](tickets/VMC-002.md) | Done — `b5a2c72`, pushed | Shared command catalog; oracle and actual-client completion, rejection and teleport pass |
| [VMC-003](tickets/VMC-003.md) | Done — validated | Reconnect, mouse rotation, restart and spawn pass; phase-transition failure repaired in VMC-003a |
| [VMC-003a](tickets/VMC-003a.md) | Done — validated | Preserve accepted state across rejected/exceptional frames; 60 tests, oracle, release and graphical recovery pass |
| [VMC-004a](tickets/VMC-004a.md) | Done — `6dc5dd3`, validated | Stack/scalar codecs, creative selection/placement/clearing, patched fixtures and rejection pass |
| VMC-004b | Planned | Names/lore/NBT and compound or registry-backed component codecs |
| [VMC-004b1](tickets/VMC-004b1.md) | Done — `2e75988`, validated | Bounded network NBT/custom data; 58 tests, Mojang codecs, release and actual-client positive/rejection/reconnect pass |
| VMC-004b2 | Partially implemented | Effective comparison, bounded names/lore and enchantment data exist; remaining text branches/events and further components remain |
| [VMC-004b2a](tickets/VMC-004b2a.md) | Done — effective identity validated, pushed | 226 tests/release/full oracle, 11,797 Mojang pairs and actual default/NBT merges, three distinct-component controls, overflow/reconnect/restart pass; raw journals preserved |
| [VMC-004b2b](tickets/VMC-004b2b.md) | Done — names/lore validated, pushed | 236 tests/release/full oracle; 15,113 stack pairs, 5,050 text pairs, 100 native name/lore round trips and actual tooltip/merge/drop/recovery/correction controls pass |
| [VMC-004b2c](tickets/VMC-004b2c.md) | Done — enchantment data validated, pushed | 245 tests/release/full oracle; native maps/defaults and actual tool/book tooltip, merge controls, active/stored drops, recovery and invalid input pass; gameplay effects remain |
| [VMC-004b2d](tickets/VMC-004b2d.md) | Done — tooltip controls validated, pushed | 254 tests/release/full oracle; all 122 types and native equality/round trips pass; actual selective/all/reset tooltips, merge controls, Q/Ctrl+Q, recovery and malformed-input preservation pass |
| [VMC-006a](tickets/VMC-006a.md) | Done — core clocks validated, pushed | 263 tests/release/full oracle; 3,600 native clock cases and actual day/night/day, command response, independent pause, reconnect/restart and resumed clocks pass |
| [VMC-006b](tickets/VMC-006b.md) | Done — weather cycle validated, pushed | 270 tests/release/full oracle; 480 native traces/50,400 ticks, migration and actual rain/storm/fade/automatic expiry, frozen-cycle /stats, reconnect/restart and cleanup pass |
| [VMC-006c](tickets/VMC-006c.md) | Done — difficulty state validated, pushed | 275 tests/release/full oracle; native default/64 lock-force cases/eight codecs and actual four labels, lock controls, /stats, reconnect/restart and cleanup pass |
| VMC-006 | Partially implemented | Core clocks, Overworld weather and difficulty synchronize/persist; complete gamerules, administration and dependent survival effects remain |
| [VMC-007a](tickets/VMC-007a.md) | Done — encrypted client validated, pushed | Native crypto probes plus VMC-007b actual encrypted login/render/input/reconnect/restart pass; online identities remain |
| [VMC-007b](tickets/VMC-007b.md) | Done — encrypted transport validated, pushed | 287 tests/release/full native plaintext+encrypted suites and actual CUA login/render/stats/input/reconnect/restart pass; online identity verification remains |
| [VMC-007c](tickets/VMC-007c.md) | Partially implemented | Real online identities/admission and discovery validated; signed chat, proxy policy and duplicate-session behavior remain |
| [VMC-007c1](tickets/VMC-007c1.md) | Done — foundation smoke validated, pushed | 298 tests/release/full oracle, 32 native profiles and CUA baseline/reconnect pass; online integration remains VMC-007c2 |
| [VMC-007c2](tickets/VMC-007c2.md) | Done — real account validated, pushed | 307 tests/release/full native suites/64 profile codecs and actual account/skin/input/reconnect/restart/outage/cleanup pass |
| [VMC-016b1](tickets/VMC-016b1.md) | Done — `6fa96ae`, pushed | 338 tests/release/full native oracle and actual four-mode UI/abilities/restart, spectator inventory corrections, non-creative world restrictions and creative placement/breaking pass |
| [VMC-018c1](tickets/VMC-018c1.md) | Done — `166633f`, pushed | 346 tests/release/full native oracle; 4,348 box distances/117 hit boundaries and actual creative range, distant rejection, restart and shorter survival targeting pass |
| [VMC-014a](tickets/VMC-014a.md) | Done — `b213a05`, pushed | 352 tests/release/full native oracle; 104,394 exact clipping cases and actual stone/slab/stair/fence contacts pass; dynamic contexts and movement enforcement remain |
| [VMC-014b1](tickets/VMC-014b1.md) | Done — pushed `83cc714` | 356 tests/release/full native oracle, three exact client contacts and fresh restarted-client log/reconnect pass |
| [VMC-014b2](tickets/VMC-014b2.md) | Done — pushed `275929e` | 361 tests/release/full native oracle; all 32 scaffolding states, 9,408 contexts/56,448 exact clips and six actual landing/descent contacts pass; movement enforcement remains future work |
| [VMC-014b3](tickets/VMC-014b3.md) | Done — pushed `f9d0e95` | 366 tests/release/full native suite, 7,062 native contexts/42,372 clips and actual bare/leather/descent/diamond contacts pass |
| [VMC-014b4](tickets/VMC-014b4.md) | Done — pushed `1602207` | 371 tests/release/full native suite, 10,710 native snapshots/64,260 clips and actual closed/open/Space/closed contacts, commands and reconnect pass |
| [VMC-014b5a](tickets/VMC-014b5a.md) | Done — client contacts verified | 376 tests/release/full native suite; 1,959 native operations/70,524 exact clips and actual stone/slab seam traversal/reconnect/restart pass; piston integration remains |
| [VMC-016a](tickets/VMC-016a.md) | Done — creative flight validated, pushed | 326 tests/release/full oracle, native ability matrix and actual double-Space/hover/reconnect/restart/flight-off/cleanup pass; full mode transitions remain |
| [VMC-007c3](tickets/VMC-007c3.md) | Done — discovery/recovery validated, pushed | 317 tests/release/full oracle, 31 native discovery facts and actual cached reconnect/offline rejection/owner recovery/restart/cleanup pass |
| [VMC-005a](tickets/VMC-005a.md) | Done — `123d1d0`, validated | Owner-local 46-slot menu; actual selection/offhand/swap/resync and automated/oracle checks pass |
| VMC-005b | Planned | Hashed click codec, authoritative pickup/swap/shift/drag transactions |
| [VMC-005b1](tickets/VMC-005b1.md) | Done — `67c34ad`, validated | Actual half pickup/place/merge/shift/number/offhand/rejection pass; 65 tests/full oracle/release pass |
| VMC-005b2 | Planned | Drag/collect, cursor return on close, crafting-slot constraints and drops |
| [VMC-005b2a](tickets/VMC-005b2a.md) | Awaiting sustained client gesture validation | Bounded transactions pass 65 tests/oracle/release and graphical fixture replication; CUA sustained drag input remains pending |
| [VMC-005b2b](tickets/VMC-005b2b.md) | Done — validated | Two-pass collection; 71 tests, actual Mojang algorithm/TCP, release and CUA double-click/caps/patch/rejection pass |
| [VMC-005b2c](tickets/VMC-005b2c.md) | Awaiting client-generated clone/fill validation | Owner permission and atomic limits pass 77 tests, actual Mojang algorithm/TCP, release and graphical fixture replication; actual creative middle-click uses a different packet path |
| VMC-005b2d | Partially implemented | Actual pickup/return and connected overflow/disconnect cleanup validated; item physics and other removal/transfer lifecycle remain |
| [VMC-005b2d1](tickets/VMC-005b2d1.md) | Done — actual mouse pickup/return validated, pushed | Current 275-test/oracle/release baseline; actual patched pickup/empty-hotbar return and selected/offhand/storage/grid order pass; earlier overflow rejection superseded by durable drops |
| VMC-005b2d2 | Partially implemented | Stationary items, durable Q/menu effects, close overflow and disconnect disposal exist; menu mouse gates, physics and other removal/transfer lifecycle remain |
| [VMC-005b2d2a](tickets/VMC-005b2d2a.md) | Done — connected close overflow validated, pushed | 187 tests, release/oracle and actual close/repeat/reconnect/restart, disabled-source correction and stalled retry pass |
| [VMC-005b2d2b](tickets/VMC-005b2d2b.md) | Done — disconnected cleanup validated, pushed | 216 tests/release/Mojang oracle and actual offline drop, disconnect/rejoin/restart, pending-intent takeover/replay and orphan cleanup pass; other removal/transfer/physics remain |
| [VMC-018a](tickets/VMC-018a.md) | Done — validated, pushed | 92 tests, 272 Mojang velocity/25 packet fixtures, release and actual item render/update/remove pass; gameplay ownership remains VMC-005b2d2 |
| [VMC-018b](tickets/VMC-018b.md) | Done — stationary foundation validated, pushed | Region CAS/ETS ownership, bounded paced replication, late joins/visibility/owner loss; automated and actual Minecraft render/update/reconnect/remove/failure checks pass |
| VMC-005c | Partially implemented | Supported preview inventories and journaled disconnect cleanup persist; full components/player state, other lifecycles and vanilla NBT/data fixing remain |
| [VMC-005c1](tickets/VMC-005c1.md) | Done — supported preview recovery validated, pushed | 111 tests, release/oracle and actual inventory/selection reconnect/restart, carried/grid recovery and corrupt-save rejection/repair pass |
| [VMC-019a](tickets/VMC-019a.md) | Done — stationary record recovery validated, pushed | 122 tests, release/oracle and actual region/full restart recovery plus durable removal pass; matching writer acknowledgment precedes publication/reply |
| VMC-019b | In progress foundations | Durable player outbox/region receipts and crash/retry reconciliation before inventory consumption; physics/cross-region simulation remain required |
| [VMC-019b1](tickets/VMC-019b1.md) | Done — destination retry foundation validated, pushed | 136 tests, release/oracle and actual fixture render/retry/removal/full restart/retry pass; gameplay integration remains |
| [VMC-019b2](tickets/VMC-019b2.md) | Done — source API recovery validated, pushed | 155 tests, release/oracle and actual pending-login preservation/API recovery/inventory+item restart pass; connected drop controls remain |
| VMC-019b3 | Partially implemented | Automatic recovery and connected world/menu/creative drops validated; complete simulation physics and other lifecycle behavior remain |
| [VMC-019b3a](tickets/VMC-019b3a.md) | Done — automatic login recovery validated, pushed | 163 tests, release/oracle and actual automatic pending recovery/restart/removed-item retry pass; connected drop controls remain |
| [VMC-019b3b](tickets/VMC-019b3b.md) | Done — keyboard drops validated, pushed | 170 tests, release/oracle and actual Q/held Ctrl+Q, empty/selected slot, frozen corrections, reconnect/restart pass; stationary physics gap remains |
| [VMC-019b3c](tickets/VMC-019b3c.md) | Done — actual menu drops validated, pushed | Current 275-test/oracle/release baseline; actual menu Q/Control-Q, pickup/right/left outside drops, empty no-ops, stall correction and exact reconnect/restart recovery pass; cleanup retains source/receipt 34 |
| VMC-019b3d | Connected preview validated | Authorized creation and ordered keyboard pairs work; simulation tick clock, physics and complete item/game-mode behavior remain |
| [VMC-019b3d1](tickets/VMC-019b3d1.md) | Done — creative source API recovery validated, pushed | 194 tests/release/oracle and actual retained inventory/item recovery, reconnect/restart/removal/retry pass; creative controls remain VMC-019b3d2 |
| [VMC-019b3d2](tickets/VMC-019b3d2.md) | Done — creative keyboard drops validated, pushed | 207 tests/release/Mojang oracle and actual Q/held Ctrl+Q, empty, stalled burst, reconnect/restart/removal pass; earlier mouse gates remain |

Only one implementation ticket is active; checkpoints awaiting client validation
are parked so implementation can continue. Records retain acceptance criteria,
checks, manual evidence and commit subject; Git history supplies checkpoint SHAs.
Development and normal pushes use `main`, as requested by the user. VMC-005b2a
was published at `fe194c1` with its sustained-gesture gate pending. Pushing a
ticket does not declare a milestone or the whole server complete.

Publication: normal push to `main` through `61e6677` completed October 14.
VMC-005b2c remains published with its client clone/fill gate pending; publication
does not mark it Done. The latest user instruction retains the AGENTS.md workflow
for subsequent checkpoints.

## Existing foundation

Implemented preview: bounded TCP sessions, status/offline login/compression,
vanilla core-pack registries/tags, flat chunk streaming, creative movement,
nearby entity replication, simple creative block edits, custom block snapshots
and `/help`, `/stats`, `/spawn`. Region tick deadlines contain no survival
simulation. The initial 17 tests, Mojang oracle and limited load benchmarks cover
this preview only. Online authentication and supported inventory components now exist. Complete
authentication policy, physics, remaining components, Anvil, generation, lighting,
AI, redstone, fluids and full survival remain unimplemented.

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
| VMC-014c | Movement and pose reconciliation | Native pose dimensions/eye heights, collision/step validation and actual client corrections |
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
| [VMC-061](tickets/VMC-061.md) | Concise docs and targeted retrieval — deferred | Short README, focused evidence, selective agent entry point and quick roadmap updates; requested October 14, not active |

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
