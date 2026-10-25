# VMC-080h — Simulation audit and refactoring plan

Status: Planned
Milestone: M3
Parent: [VMC-080](VMC-080.md).

Audit completed October 25, 2026. The first follow-up is complete owner timing
observations ([080i](VMC-080i.md)); larger simulation refactors have not started.
The user requested this review before further fixes or deployment. They explicitly
asked for the strengths and costs of both BEAM/Elixir and Rust to be considered,
without a preference that forces the wrong execution or state model.

## Conclusion

Refactor the unit of simulation before choosing a different language for AI.
ValiMC owns interacting sections together, but still simulates their mobs as
separate section batches. Repeated preparation, incomplete cross-section entity
queries, broad housekeeping and persistence preparation accumulate inside one
process. More processes around the existing section API would distribute some
work but retain those costs and introduce ordering problems.

The recommended direction is one simulation frame for the group's active
entities, with shared spatial queries, ordered effects and incremental
publication/durability. Elixir retains ownership, admission, transactions and
coordination. Dense state and computation can live in an owner-held Rust resource;
the frame's semantics do not require its hot representation to be Elixir terms.
Preserve the existing native block/physics/path kernels. Compare a compact Elixir
mob path with a resource-owned native slice before committing to the next entity
representation. These profiles establish the architectural problems, but do not
establish the winning language for the remaining AI work. Neither retaining all
AI in Elixir nor porting all families to Rust is a requirement.

## Evidence and scope

Runtime reference: deployed `95051f1755c8b7fdef0a0f43f6639db43d6e901d`.
Local HEAD `24c47562` adds deployment documentation. Earlier uncommitted 080f/g
prototypes are distinguished below; they have not been deployed. Runtime work
paused for this audit. Following the user's clarification to take the appropriate
Elixir/Rust direction, 080i begins the measurement step. Nothing new was deployed.

The review follows the world/owner clocks, regionizer, tick pipeline, tickets,
entity ageing, mob AI, goals/brains, sensing, navigation, native ticker, movement
adoption, publication, durability, worker admission and generation/light adoption.
It is a source and profile audit, not a new maximum-capacity benchmark or proof
that every gameplay family is correct. No Minecraft client or hosting stress
tester was run.

| One-minute capture | Loaded-area movement/combat (6) | Spectator exploration (7) |
|---|---:|---:|
| Simulation TPS, trailing-minute window | 7.41 | 4.76 |
| Final pooled MSPT ring median | 117.6 ms | 92.2 ms |
| Final pooled MSPT ring p95 | 166.3 ms | 284.7 ms |
| Normal scheduler utilization, minute window | 48.2% | 50.0% |
| Dirty CPU scheduler utilization, minute window | 16.9% | 58.5% |
| Region reductions / all recorded reductions | 747.5M / 844.5M | 533.9M / 754.2M |
| Region share of recorded reductions | 88.5% | 70.8% |
| Region stack observations | 1,244 | 943 |
| Observations including `move_mobs` | 457 | 149 |
| Final player RTT | 17 ms | 46 ms |

There are two normal schedulers. Their average utilization is consistent with
a substantial serial bottleneck; it is not a measurement of CPU steal, available
host capacity or exact per-process CPU time. The two captures change movement,
game mode, active mobs and terrain as well as generation demand. Their difference
cannot be assigned entirely to terrain generation. Loaded-area gameplay already
fails badly without exploration.

Stack counts overlap, truncate at eight frames and may observe a caller waiting
for native work. In capture 6, `MobTicks.steps` appears in 389 observations,
`AI.think_mob` in 153, fluid sensing in 59, owner tracking in 72 and spawning in
90. Mob ticking is the largest identifiable sampled component; that does not
mean goal selection alone consumes 37% or 89% of CPU.

History includes server uptime before each capture. The analysis filters it by
capture timestamps. Counters are lifetime totals, not capture deltas. Owner
maximum tick duration is also a lifetime maximum. The exploration median includes
very cheap ticks of other/new owners, so its smaller value does not demonstrate
that the busy player's simulation got faster. Current reports lack active entity
counts and complete owner phase timings.

Reaching 20 TPS needs about 2.7 times the loaded-area tick completion throughput,
and 4.2 times the exploration throughput. These are throughput gaps, not measured
CPU speedups achievable by a particular change.

Private evidence: `.local/wide-view-perf/profile6-7/comparison.json`, the original
captures, and `.local/simulation-audit/{manifest.json,probes.exs,probes.json}`.
The manifest pins the capture hashes, deployed source hashes and the untouched
pending runtime diff. Probes are tiny local functional checks, not load tests.

## What one tick currently does

1. `World.Clock` advances independently and publishes `GameTick`.
2. A group's timer advances `TickClock`; `Region.next_tick` selects at least the
   current global game tick. A single callback runs the group tick.
3. Hosted players are tracked, spawning/despawning is planned over the group,
   and the End arena runs when present.
4. For each storage section in sorted key order, run blocks, block events,
   entities, moving pistons, hoppers and cooking. Apply sibling effects after
   each section phase.
5. In an entity phase, age the section's entities, tick special bodies, prepare
   that section's mobs, run them through AI and the native ticker in id order,
   route effects/moves, move items/orbs, evaluate redstone contacts and publish.
6. After the measured tick body, expire tickets, consider unloads/transfers,
   prepare/send group commit frames and schedule the next timer. Separate commit
   timer and player/generation/light callbacks use the same owner mailbox.

Core entry points: `Region.handle_info({:tick, ...})`, `run_tick`, `lifecycle`,
`commit_frames`; `TickPipeline.phases/run`; `RegionData.item_tick`,
`simulate_items`, `move_mobs`, `track_entities`; `MobTicks.steps/ordinary_step`.
The concrete files are `lib/valimc/world/{region,region_data,tick_pipeline}.ex`
and `lib/valimc/entity/mob_ticks.ex`.

## Findings

### 1. Ownership is shared, but the simulation frame is still section-local

**Confirmed architecture and a reproduced behavior gap; highest refactoring
priority.** `Region.run_tick` nests phases inside sections. `move_mobs` selects
only one section's active mobs, and `AI.prepare` constructs sensing/indexes from
that list. Group peers are available for some effects, but ordinary AI entity
queries are section-local. This can miss a nearby mob across a 128-block storage
boundary. The native ticker's external rows include solid-family colliders;
ordinary adjacent-section mobs do not join its normal push grid.

A local probe using deployed `MobTicks` code places two cows at x=127.8 and
x=128.2. Ticking the first with the second supplied as an external row produces
zero horizontal velocity; ticking them in the same batch produces x velocity
-0.06447. Preparing AI for the first section senses one entity, not both. This
does not prove every cross-border feature fails, but confirms that the ordinary
batch paths differ at the storage boundary.

The section-major phase loop also permits section A's entities/hoppers to run
before section B's block phase. Vanilla's world loop completes block/chunk/event
phases before its entity pass. Establish an explicit group phase order and one
active entity frame; route the resulting mutations back to section stores for
storage. Preserve interleaved melee, pushes, shulker movement, deaths and RNG.
Simply parallelizing existing section ticks would make these dependencies harder.

### 2. Simulation eligibility is inconsistent inside a partially active section

**Confirmed work and behavior leakage.** Block ticks, mob movement, items,
projectiles, moving pistons and hoppers have chunk-level simulation checks.
However, `item_tick` enters `simulate_items` if any chunk in the section simulates,
and `Store.age` ages all entries of that section. Cooking is also entered by an
any-chunk check and its selection is not simulation-chunk-filtered. Knot lifetime
checks do not independently filter chunks.

A probe gives one chunk active membership and two cows in different chunks of
the same section. The movement selection contains one cow, but the same ageing
call decreases both hurt cooldowns from 10 to 9. This is not a claim that all
render-distance mobs run full AI: `move_mobs` already filters correctly.

Use maintained per-chunk work sets, with distinct loading, block-ticking and
entity-ticking eligibility where vanilla requires them. Apply the same eligibility
to timers, special entities and block entities. Preserve passive targets that an
active entity may affect across a boundary; filtering the whole world to only
active entities would break collisions, sensing and transactions.

### 3. Render-loaded sections inflate a serial owner's housekeeping

**Confirmed structure; production cost needs phase timings.** Regionizer merges
groups based on loaded sections within its three-section reach, including
render-only sections. One player therefore has one large serial owner. The owner
walks all its sections for tick phases, player tracking and lifecycle, even when
only a subset simulates. Frozen entities still advance replication trackers.

Before the pending 080g prototype, every section mob-world preparation scans the
group's entities for knots and dragons. Rule/comparator contexts also walk peer
state. For S active section callbacks and N loaded entities, repeated group
searches can add O(S*N) preparation. The existing per-chunk publication and
spatial caches help; they do not create one shared simulation frame.

Maintain active work lists, shared immutable environment/fact inputs and
incremental group indexes. Change them when tickets, membership, entities or
relevant blocks change. Do not cache an authoritative mutation decision across
an ownership or revision change. A rendering view should not determine the cost
of every mob's think.

### 4. Mob turns repeatedly change representation at the Elixir/native boundary

**Confirmed allocation and conversion paths; exact cost unresolved.** Every
section builds sensed maps, type maps, a spatial grid, id/index maps, travel
inputs and a native ticker. A mob becomes entry/body, sensed record, AI `Self`,
kernel input map, native body, result map and store/view again. A movement input
is prepared at ticker creation and again after AI. Pre-AI fluid/eye reads in the
deployed code build additional views and repeat contact scans.

BEAM immutable updates share unchanged subterms within a process: these are not
full deep copies on every update. They still allocate new map/tuple paths, repeat
lookups and create garbage. Process messages and ETS publication add different
copying costs. Increasing heap size would not remove this work.

Use one group frame and separate hot fields from cold equipment, persisted AI and
metadata. Keep native facts, chunk handles and unchanged travel attributes in the
existing resource for the phase. Pass changed controls/fields and return compact
results. Compare compact Elixir records with retained native hot state and a
batched interface on a representative mob turn. If retaining the AI state and
its related queries in Rust removes costly repeated conversions, moving that
coherent slice can be better than optimizing each Elixir map in isolation.

### 5. The profiler excludes work that delays the next simulation tick

**Confirmed measurement gap.** Tick MSPT measures `run_tick` and stops before
`lifecycle`, player transfer handling and `commit_frames`. Commit-timer callbacks,
chunk installs, light propagation and input callbacks also delay the same owner.
The global MSPT ring mixes owners; a new cheap owner can lower the median while
the player's owner falls behind. TPS already uses simulation-owner progress,
which is why the bad TPS in these captures is real.

Add bounded sampled timings for the complete owner cycle: spawning, block work,
entity preparation, goals/brains, physics, effects, tracking, commit preparation,
adoption/light work, GC and mailbox delay. Include active/loaded entity and chunk
counts, native call counts/time and path queue/result age. Associate samples with
an owner and interval, and retain explicit timestamps. Do not add every phase's
overlapping stack counts as if they were exclusive CPU percentages.

### 6. Durability is batched, but expensive record preparation remains in the owner

**Confirmed source cost and sampled activity.** Disk writes already run outside
the owner and group commit avoids per-action fsync. The remaining issue is CPU:
`RegionStorage.diff_parts/fields/keyed_changes` builds old/new persistent records
for changed entities. That invokes body/mob/living/AI serialization and validation
before deciding whether a change can wait. Motion/AI-only changes can wait for
the one-second motion pass, but their preparation is still repeated.

Use mutation-time dirty classes and an ordered journal of changed identities,
so the owner does not rediscover semantic differences by serializing both sides.
Batch immutable data for encoding/checkpoint workers, retaining sequence numbers,
atomic player/world frames and handoff fences. Specify recovery and backpressure;
moving a giant store to a worker on every tick would exchange computation for
copying, retention and stale results. Do not quietly weaken durability to resemble
vanilla autosave.

### 7. Tick deadlines and logical time need a coherent overload policy

**Confirmed scheduling differences; contribution to this capture not measured.**
`TickClock.advance` computes a relative delay before the callback; that delay is
scheduled after simulation and lifecycle finish. In a simple clock probe, a tick
starting at 50 ms with deadline 100 ms and 80 ms of work schedules at 180 ms,
rather than being eligible immediately at 130 ms. Under sustained overload the
clock clamps the next deadline close to the start, so this is not an extra
50 ms on every slow tick. Recompute waiting from the absolute deadline after work.

Separately, `next_tick = max(previous + 1, GameTick.current())` can jump owner
tick labels while only one entity update is executed. The independent environment
clock can remain near 20 TPS while entities run near seven. Absolute due times,
per-entity counters and schedules then advance differently. Vanilla skips wall
deadlines when overloaded; that does not execute skipped entity turns or jump
world game time through unexecuted turns.

Define logical simulation progress, environment time and merge/rebase semantics
together. Fixing a timer does not solve an over-budget mob phase; changing clocks
alone can also invalidate the handoff and scheduled-tick assumptions.

### 8. Exploration competes for both CPU and owner callback time

**Confirmed paths, with increased native utilization in capture 7.** Terrain,
decoration and paths already run on bounded workers. Generated columns still
enter owners, publish snapshots/entities and trigger lighting, rules and encoding.
Delivery is bounded by chunk count, not by elapsed owner work. Dirty schedulers
and normal schedulers share the same physical CPUs; reserving dirty slots does
not reserve a physical core for gameplay.

Use a shared CPU admission budget across generation, path searches, compression
and simulation helpers, with nearest/player-required work ahead of speculative
generation. Prepare adoption inputs away from sensitive callbacks; keep atomic
ownership changes small and bound adoption by measured work. Do not increase
generation concurrency to hide slow chunk loading on a two-vCPU machine.

`Jobs.spawn_slot` also checks then increments a `:counters` value separately;
concurrent owners can over-admit its nominal limit. The generation pool uses an
atomic reservation instead. This is a bounded-worker correctness concern, not
evidence that it caused these captures. Fold admission into one shared primitive.

### 9. Pathfinding is already native; its pipeline still has latency risks

**Confirmed design; not identified as the largest capture cost.** Each section
queues newest-per-mob requests and runs batches of up to 32. Results wait for a
later tick and are fenced by whole snapshot-handle equality. Concurrent terrain
or light publication can reject a result even if its traversability stayed valid.
Queueing behind other CPU work can make mobs stand or repeatedly request paths.

Measure request-to-use latency, queue size, cancellation and stale-result reasons.
Consider immutable query batches and traversability-relevant revision fences,
with target/request generations preserved. Do not weaken fences without proving
that the omitted changes cannot alter path validity. More Rust A* code is not
the first intervention.

### 10. Goal and sensor query preparation needs its own cost accounting

**Confirmed implementations; not the largest measured loaded-area component.**
`MoveToBlock.find` allocates the complete ordered candidate list before an early
success can stop the search. The owner's `find_blocks` asks native snapshots for
matching cells of whole chunks, then filters the requested height/box in Elixir.
`Brain.sensors` repeatedly uses indexed list access and replacement, making that
small selector loop quadratic in sensor count. These are candidates for lazy
ordered iteration, bounded box queries, revision-aware static indexes and compact
sensor tuples. Their actual impact depends on mob families and query sizes.

AI already staggers full goal selection by id/tick parity, and brain sensors have
their own scan countdowns. Do not count another blanket reduction of AI frequency
as a free optimization. Preserve selector priority/insertion order, sensing
visibility, random consumption and the family's actual vanilla cadence. Count
queries, visited candidates, block reads and allocations before choosing kernels.

## Vanilla and Pumpkin comparison

Vanilla reference: official Java 26.3 outer jar SHA-1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`; bundled runtime jar SHA-1
`cc3964451a3b32a0488110d5e3e6ad8d75fe6a66`. Existing private decompilation
inputs for `ServerLevel`, `Mob` and `EntityTickList` were byte-hash-matched against
the bundled jar during this audit. Referenced classes also include
`MinecraftServer`, `EntitySectionStorage`, `PersistentEntitySectionManager` and
`GoalSelector`. Upstream source is not included in this ticket.

Pumpkin reference: the repository's existing pinned checkout
`b0c48b2d7688bbfa09956adf530b8bc56dcc0c56`, not a claim about an uninspected newer
release. Its inspected production files are unmodified; an unrelated untracked
example directory was left untouched. The current checkout uses
`crates/pumpkin-core`, despite older paths in some web documentation.

| Aspect | Vanilla 26.3 | Pinned Pumpkin | ValiMC deployed |
|---|---|---|---|
| Main tick | Deadline-driven server loop; world time advances with executed world ticks | Dedicated ticker thread with monotonic deadlines and catch-up | Independent clock and owner timers; owner labels catch up to global clock |
| Entity membership | Maintained tick list and section visibility/range checks | Active chunk tracker and loaded-chunk filter before ticking | Chunk membership index for mob movement; coarse checks remain for some other work |
| Nearby entities | Queries accessible nonempty spatial sections | Several inspected query helpers scan a world entity vector | Spatial grids for local mob sensing/physics, but section-local AI membership |
| Mob turns | Ordered world entity traversal with direct state mutation | Rayon entity batches of 16; mutable entity fields guarded by atomics/mutexes | Serial turns within each section; immutable Elixir state around native physics |
| Goal cadence | Full selectors on alternating id/tick turns; selected running goals on other turns | Same alternating cadence in `server_ai_step` | Already implements that cadence; halving it again would change behavior |
| Goal storage | Reused selector/goal instances | Reused vector and four control slots; in-place goal updates | Goal tuples/maps, nested immutable `Self`/mind updates |
| Physics/state | Direct calls on persistent entity objects | Native state remains in Rust structs; synchronous per-mob calls | Native ticker holds physics state; repeated conversion around Elixir AI |
| Persistence | Entity saving through autosave/unload paths | Serialization on save/unload paths; configured autosave | Stronger atomic journal/commit semantics; owner-side semantic diff preparation |

Pumpkin's [`World::tick`](https://github.com/Pumpkin-MC/Pumpkin/blob/b0c48b2d7688bbfa09956adf530b8bc56dcc0c56/crates/pumpkin-core/src/world/mod.rs#L1523)
filters tickable entities and runs Rayon batches. This is genuine within-world
CPU parallelism, unlike our single owner's serial mob phase. Parallel batches
can interleave interacting mobs; the source is not proof of vanilla-equivalent
combat, push or RNG ordering. Its shared mutable state and lock model cannot
simply be transplanted into BEAM ownership.

Its [mob AI step](https://github.com/Pumpkin-MC/Pumpkin/blob/b0c48b2d7688bbfa09956adf530b8bc56dcc0c56/crates/pumpkin-core/src/entity/mob/mod.rs#L238)
and [goal selector](https://github.com/Pumpkin-MC/Pumpkin/blob/b0c48b2d7688bbfa09956adf530b8bc56dcc0c56/crates/pumpkin-core/src/entity/ai/goal/goal_selector.rs)
show useful data reuse and compact control bookkeeping. Conversely, the
world's `get_nearby_entities` is a full vector scan; copying that algorithm would
discard a spatial-index advantage we already have. Rust and Rayon do not make
every Pumpkin algorithm preferable. Its mob code also contains explicit NoAI
ordering TODOs. No matched Pumpkin-versus-ValiMC survival result is established.

The [Pumpkin ticker](https://github.com/Pumpkin-MC/Pumpkin/blob/b0c48b2d7688bbfa09956adf530b8bc56dcc0c56/crates/pumpkin-core/src/server/ticker.rs)
waits against an absolute deadline after work. Its
[active chunk tracker](https://github.com/Pumpkin-MC/Pumpkin/blob/b0c48b2d7688bbfa09956adf530b8bc56dcc0c56/crates/pumpkin-core/src/world/active_chunks.rs)
incrementally updates membership as players move, rather than rebuilding all
activity from scratch. These are useful designs independent of implementation
language; their coordination belongs naturally with the Elixir owner.

## How to use BEAM better

**Keep one writer for state that interacts.** That is a strength, not the part to
discard first. BEAM gives independently scheduled processes, isolated GC,
supervision and cheap lifecycle boundaries. It does not parallelize one
`GenServer` callback or allow that callback to process gameplay messages while
it is in a long dirty NIF. See the official
[NIF documentation](https://www.erlang.org/doc/apps/erts/erl_nif.html).

**Make owners small in work, not numerous by entity count.** Maintain an active
entity frame and persistent indexes; stop deriving the same view for every
storage section. Keep cold state and encoding away from the active loop. Use
compact immutable results, binaries and snapshot handles for worker messages.
Ordinary terms sent between processes are copied, while reference-counted
binaries and literals have different sharing rules; a task per mob carrying its
world map is a poor default. See the official
[process efficiency guide](https://www.erlang.org/doc/system/eff_guide_processes.html).

**Parallelize independent work first.** Existing pathfinding, generation, encoding
and I/O are appropriate worker domains. Extend that to bounded read-only static
environment queries, serialization and other preparation with explicit revisions.
Keep mutations and interacting AI turns ordered. Joining tasks synchronously in
the owner still blocks it; asynchronous results need a defined tick/input cut,
failure handling and fencing. Stale retries must not become an unbounded tax.

**Consider simulation ownership islands later.** Loading/rendering does not
necessarily require shared simulation authority. An ownership graph based on
active interactions plus a proven halo could keep distant players independent
even when their rendering views overlap. Dormant storage can remain separately
owned and publish immutable observations. Activating a boundary must merge or
transfer before mutation, using the existing transaction/fencing machinery.
Projectiles, explosions, redstone, leads, portals and dragon extents make a
naive fixed-radius split unsafe.

This helps multiple distant players scale across schedulers and isolates GC.
It does not make one dense interacting mob population use two cores for free.
For that case, first reduce the serial work; then evaluate deterministic
read-only parallel preparation or a native kernel. A process per entity, blind
`Task.async_stream` over mob turns, and a globally mutable ETS world are not
recommended.

## Language and refactoring decisions

The ownership boundary and the computation boundary are separate decisions.
An Elixir process can own a dense Rust resource without representing every hot
field as an Elixir map or allowing shared mutable world access. Choose the
representation before a broad rewrite, using a small representative slice.

| Proposed work | Recommended boundary | Reason and decision gate |
|---|---|---|
| Active work admission, ticket eligibility, clock policy | Elixir/OTP coordination | Already coupled to owner lifecycle, transfers and timers; native membership indexes can support it |
| Group entity frame, sensing and ordered effects | Elixir authority; compare compact terms and resource-owned native hot state | Correct cross-section visibility is required in either language; include conversion and publication cost in the comparison |
| Spatial/type indexes and shared environment inputs | Keep each hot index beside the state its queries traverse | An Elixir index can avoid a crossing; a Rust index can avoid repeated term decoding and reuse dense storage |
| Goals/brains and selector bookkeeping | Retain current behavior while benchmarking a coherent AI/query slice | Elixir has easier inspection and lower migration cost; Rust offers retained mutable state and cheaper dense loops, with larger parity and integration obligations |
| Geometry, fluids, path search, large block scans | Rust kernels | Existing dense/native data makes these appropriate; improve batching and interfaces |
| Dirty mutation journal and encoding/checkpoints | Elixir transaction ordering; bounded encoding workers | Ordered identities and fences belong with authority; bulk binary encoding can be Rust when complete-path cost improves |
| Generation/encoding/path admission and simulation islands | BEAM processes and shared bounded primitives | Scheduling and ownership topology require coordination; their worker computations can remain native |

Three execution choices need explicit comparison:

- **Compact Elixir mob turns:** avoid a new AI bridge, preserve current inspection
  and parity machinery, and share unchanged terms inside the owner. Repeated
  immutable updates, boxed data and GC can still dominate a dense serial turn.
- **Resource-owned Rust entity slices:** reuse hot state, spatial indexes,
  controls and selector storage across turns. This can remove allocations and
  conversions that a small standalone NIF cannot. Costs include migration,
  parity coverage, native crash risk and explicit recovery/publication formats.
  Bound each slice and its effects; a dirty NIF still occupies its calling owner
  until it returns. Preserve interleaved turn semantics when choosing batch cuts.
- **BEAM workers for independent preparation:** use available schedulers without
  moving all gameplay into native code. Message copying, synchronization,
  snapshot retention and stale results can outweigh the work saved. This suits
  substantial independent queries or encoding, not arbitrary interacting turns.

An Elixir design can beat a Rust design by doing less work, using indexes and
avoiding global locks. A retained native representation can also beat Elixir by
removing repeated term allocation and conversion. Compare complete owner cost,
memory, copying and latency, not just time inside a candidate NIF. Avoid per-goal
NIFs that serialize a whole mob/world on every call. Do not require an Elixir
rewrite to fail before considering a native representation, or assume native
parallelism preserves the required gameplay order.

## Recommended sequence and gates

1. **Measure the complete owner and define time/order.** Add sampled timings and
   active counts; specify phase ordering and overload/rebase behavior. Capture
   realistic immutable replay inputs, with no production client load generator.
2. **Make activity consistent.** Maintain chunk/entity/block-entity work sets;
   freeze outside-ticket timers correctly. Test partial sections and activation,
   including interactions with inactive neighbours.
3. **Choose and build the group entity frame.** Use a representative replay slice
   to compare compact Elixir and resource-owned native state before a broad data
   rewrite. Share the sensed world/index and physics view; retain explicit stable
   turn order, effects and section routing. Test
   ordinary AI/pushing/melee across storage boundaries, handoffs, conversions,
   shulkers, schools and the End fight. Retain per-mob RNG consumption.
4. **Remove persistence rediscovery and redundant projections.** Mutation-time
   dirty classes, incremental tracker inputs and immutable worker batches;
   prove atomic recovery, bounded retention and transfer durability.
5. **Extend the winning boundaries to remaining hot paths.** Measure selectors,
   sensing and representation churn on the same captured workload. Move coherent
   kernels/state together where the complete-path benefit justifies the parity
   and migration cost; retain Elixir where native crossings erase that benefit.
6. **Budget background work.** Shared atomic admission, callback/adoption work
   budgets, nearest-chunk priority and path latency observability on two vCPUs.
7. **Evaluate ownership islands when multi-player scaling needs them.** Keep
   this behind a proof of interaction bounds and fenced activation. Do not use
   it to defer fixing the single-player serial cost.

Each stage should become a separate bounded implementation ticket with acceptance
criteria, a coherent checkpoint and its affected vanilla/owner tests. Measurement
and correctness gates determine the next boundary; the sequence does not assume
that every speculative refactor will be necessary.

For performance gates, hold seed, active entity types/counts/distribution, game
mode, actions, simulation distance, loaded view and generated terrain constant.
Measure steady loaded gameplay and exploration separately on comparable hardware,
including complete owner work and native/RSS memory. Compare vanilla/Pumpkin only
where behavior and workloads match. Aim for sustained 20 completed simulation
ticks/s with headroom within the 50 ms budget, bounded queues, accurate tail
latency and no dropped gameplay or reduced simulation distance. The user's own
gameplay/profile remains the live check. No speedup is promised by this audit.

## Pending prototypes and verification status

080f/g were started before the audit request and remain uncommitted and
undeployed. Their already-running verification finished: 126 Rust tests,
641 fast checks, 45 owner/mob/dragon checks and 120 selected vanilla stages pass.
The unchanged world-settings extraction has no cached regeneration and remains
unverified. These results validate those prototypes, not the proposed refactors.

The combined fluid read saves about 2% in the matched 100/300-mob phase fixture;
complete mob-step results match the deployed implementation with identical seeded bodies
in one VM. The earlier separately built fixtures had different hashes and are
not used as a matched result. The absent-type guard reduces a 77-section,
32-entities-per-section empty-query fixture from 5.857 to 0.127 ms for 77 pairs
of queries. That fixture isolates preparation and is not an overall TPS result.
These limited wins are insufficient evidence for closing the throughput gap.

The audit's local probes reproduce section-wide ageing, cross-section sensing/
pushing differences and relative-timer scheduling. Source provenance, probe
results and the pending runtime patch hash are retained in ignored
`.local/simulation-audit/`. Runtime prototypes were left intact for later review;
the deployed host and world were not changed during this audit.
