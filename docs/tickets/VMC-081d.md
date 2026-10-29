# VMC-081d — Native mobs

Status: In progress
Milestone: M3, at the user's request
Parent: [VMC-081](VMC-081.md).
Depends on: [081a](VMC-081a.md).

Mob simulation moves to Rust whole: state, AI, base tick, vitals, combat,
records and tracking. Elixir keeps processes, sockets, players, commands,
tickets, transfers and persistence orchestration. This replaces the earlier
081d/081e/081f split (entity sections with items first, then a mob core,
then families): a survey of the entity path showed items and the other
non-living kinds are a small share of a tick with many mobs, and a Rust turn
over Elixir state rebuilt each tick would keep the conversions that dominate
today.

## Baseline

`bench/tick_budget.exs` `mobs` at 922cdd57, two pinned cores of the
development Mac's Linux VM, 60 seconds:

| | Run 1 | Run 2 |
|---|---:|---:|
| TPS (mean / lowest second) | 20.0 / 19.0 | 20.0 / 18.7 |
| Tick mean / p95 | 18.7 / ≤50 ms | 19.0 / ≤50 ms |
| Entity phase (sampled) | 13.9 ms | 16.1 ms |
| Active mobs / loaded entities | 164 / 764 | 161 / 762 |

About 90 µs per active mob on these cores, about 300 on the VPS. Owner
profile (inclusive shares): mob turns 25% (AI thinking 8%, per-mob glue
around the physics kernel 12%), natural spawning 14% (mostly the native
kernel), entity save records 12 to 15%, tracking 6%.

## What moves

About 35,000 lines of Elixir: the AI core (`ai.ex`, `self.ex`, `world.ex`,
`selector.ex`, `goal.ex`, `mind.ex`), 27 goals, the brain machinery and four
brains, 30 mob families and the animal modules, navigation and its helpers
(`random_pos`, `shapes`, `look`, `smooth_swimming`, `leash`, `pickup`,
`daylight`, `neutral`, `consume`, `conversion`, `spawn`, `spawn_group`,
`pois`, `sensors`), the tick glue (`mob_ticks`, `mob_motion`, `mob_vitals`),
the body (`body`, `mob`, `living/*` for mobs, `combat`) and the dragon. The
physics kernel (`physics::mob`, the mob ticker) and path finding
(`valimc_core::path`) are Rust already and are called in process.

## Design

- **Ownership.** Each section's mobs live in a `MobSection` resource (NIF
  `mobs.rs`, core `valimc_core::mobs`) owned by the section's group, given
  with `region_give` on transfers. It holds every native mob whole: body,
  living state, equipment, attributes, mind (random, selectors with goal
  state, navigation, controls, brain), family data, in network-id order with
  a chunk index. Nothing is rebuilt per tick.
- **Types move whole.** A mob type is native or Elixir, never split. While
  families move, a section's turn runs every mob in id order: native mobs in
  Rust, an Elixir mob by yielding to `MobTicks` at its turn over the same
  physics ticker, then resuming. Native mobs appear to Elixir AI as sensed
  rows and Elixir mobs to native AI likewise, refreshed as each moves, as
  `AI.World.resense` does today. When the last family is native the yield
  and the Elixir path are deleted.
- **The world a native AI reads** (`Level`): block states through the
  published snapshots the ticker already holds, light, biome, sky, rain,
  the border, knots, POIs, game rules, time and difficulty, the group's
  players and items as sensed rows, path searches run synchronously in
  process (`valimc_core::path`), and the section's level random.
- **Effects** that leave a mob (attacks on players or other owners' mobs,
  sounds, particles, spawns, conversions, block edits, drops, item pickups,
  leads, alerts) come back as one typed list per tick, applied by the owner
  as today's effect tuples are. Mob-on-mob changes inside a section apply
  directly, in id order, as vanilla's do.
- **Outside actions** on a native mob (player hits, projectile and
  explosion hurts, effects, interactions: feeding, breeding, shearing,
  milking, buckets, leads, names; kills, teleports, portals, despawn,
  conversion, spawning and finalizeSpawn) are calls on the resource, on a
  normal scheduler, each bounded.
- **Records** are produced by the resource as the same terms `Body.record`
  writes (atom-keyed family data, `%MobMotion{}`, `%ItemStack{}`), so the
  log, checkpoints, handoff digests and exports are unchanged; only changed
  mobs are recorded at a cut, by dirty class. **Tracking** reads native
  views: position, rotations, metadata values and equipment changes, with
  the tracker's packets encoded natively.
- **Exactness.** Every draw in vanilla's order on the same streams (the
  mob's LegacyRandomSource, the section's level random); Java float and
  double typing per variable as the Elixir's `Float32` discipline encodes
  it; integer wrapping as Java's; id order everywhere order matters. The
  vanilla oracle stages that drive `MobTicks.steps` (`mob_ai`, `hostile_ai`,
  `animals`, `village`, `nether_mobs`, `turtle_growth`, `endermite_life`,
  `dolphin_*`, `combat`, `entity`, `bucket_mobs`, `aquatic_packs`,
  `natural_spawning`) run unchanged against the native turn, and a
  differential test runs Elixir and native turns on the same seeded scenes
  while both exist.

## Order

1. Core: random, Mth and facts, the mob data model and its record codec,
   `Level`, sensing, selector and goal trait, look and body rotation
   controls, navigation over the path crate, living base tick and vitals,
   combat for mobs, the turn loop over the ticker with the Elixir yield, the
   `MobSection` resource and its owner integration (store routing, effects,
   records, tracking, transfers).
2. Families by population: farm animals (cow, mooshroom, pig, sheep,
   chicken, rabbit) with their goals; then zombie (husk, zombie villager),
   skeleton (stray, bogged), creeper, spider (cave spider), enderman,
   witch, slime and magma cube, drowned; then water, Nether, village and
   brains, the rest, the dragon last.
3. Delete the Elixir mob path.

Each family: its oracle stages pass on the native turn, the differential
test passes, then its type switches to native.

## Core, built

Each piece is checked against the Elixir on the same inputs, random state
included, through parity NIFs and differential ExUnit tests.

- **Random and Mth** (`mobs::{random, mth}`): the mob's LegacyRandomSource
  and the float angle and table arithmetic; draws equal the Elixir's.
- **Model and records** (`mobs::{term, model, record}`): a native mob whole
  (body, living, equipment, attributes, motion, mind, family data) and the
  codec writing exactly `Store.body_record`'s terms: 37 types fresh, spawned
  and generated, every saved option, migrations, refusals, and 22 mobs ticked
  200 ticks, each tick equal as terms and as deterministic bytes
  (`native_mob_record_test`).
- **Facts, level and sensing** (`mobs::{facts, level, sensing}`): every fact
  table the AI reads, installed from Elixir at start; the AI's world (blocks
  through snapshots, light, sky, biome, rain, fits, the level random); sensed
  players, mobs and items, targeting conditions, visibility, nearest searches
  with the order-keeping grid and line of sight. About 3,000 cells, 602 lines
  of sight and 1,000 sensing queries over generated terrain equal the Elixir
  (`native_mob_facts_test`, `native_mob_level_test`).
- **Living rules and combat** (`mobs::{living, combat, vitals}`): health,
  effects, attributes, damage, armour, enchantments, burning, air, falls,
  melee, durability, difficulty, explosions, body timers and metadata
  values; hurts, knockback, deaths with drops and experience, mob hits; the
  base tick, post-move vitals and daylight. 13 differential tests; the
  vanilla `combat` stage's 400 player attacks and 240 zombie hits pass through
  the native hurt and hit (`native_mob_living_test`). Where the Elixir drew
  `:rand` (oxygen bonus, equipment experience, mind-less fallbacks, helmet
  wear in daylight) the native draws the stream vanilla uses.
- **AI machinery** (`mobs::ai`): the mind's transient state, the turn
  context, the goal selector, all 27 goals with targeting and neutral
  anger, look, body and smooth-swimming controls, navigation of every kind
  over the path crate (searches synchronous, as vanilla's and the oracles'),
  random positions and shapes. Nine differential scenes (zombies, cows,
  spider, skeleton, calf, golem target, cod) equal the Elixir every tick
  (`native_mob_ai_test`).

Acceptance:

- Every mob oracle stage passes with every type native.
- The `mobs` scenario's entity phase at least 15 times faster than the
  baseline on two cores, tick p95 well under 50 ms.

Checks: pending.
