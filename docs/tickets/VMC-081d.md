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

## Native plain mobs

The plain mobs (living types of a spawning category without Elixir AI:
wolf, fox, goat, horse and the other horses, llama, camel, panda, parrot,
polar bear, frog, armadillo, sniffer, bee, allay, the illagers, ravager,
breeze, warden and the rest `Body`'s plain list holds, the dragon apart) are
simulated whole in Rust, behind `config :valimc, :native_mob_types` (type
names and `:plain`). The farm animals (cow, mooshroom, pig, sheep, chicken,
rabbit) are native too, by name; see below.

- **Section** (`mobs::section`, NIF `mob_section`): a section's native mobs
  in network-id order with a uuid and a chunk index, owned by the group
  beside the Region resource and handed on with it (`mob_section_give` in
  `Region.transfer`). A load inserts the records its log holds; spawns,
  summons, handoffs and adoptions insert theirs; a sibling section of the
  group receives a mob whole (a parcel, so its unsaved state survives the
  move).
- **Records** come from the section and are `Store.record/1`'s terms. A
  cut writes a mob whose record differs (as Elixir's `==` compares) from
  the one its last frame wrote, and lets one that only travelled wait for
  the motion pass, as `RegionStorage` settles an Elixir record; the section
  keeps hashes of what was written instead of the terms. Checkpoints take
  every record; a gone mob's record is deleted once.
- **The store** keeps for a native mob its routing and publication (ids,
  position, revisions, events, view) with a `NativeBody` row: type,
  rotations, motion, dimensions, what observers are shown (`Body.shown/1`'s
  projection), what other mobs sense and what pushes and explosions read.
  Its physical fields follow each move; the others change only when the
  section reports a new row (see "Resident ticks" below). Every change is a
  call on the section: hits (`Combat.resolve/2`), explosions and falling
  anvils, effects and ignition, names, `/kill`, pushes, pistons and lids,
  teleports, portals, timers and deaths' drops.
- **The tick** (`mobs::tick`): one ticker per section tick holds every mob
  in id order (`mob_section_tick`, see "Resident ticks"). At an Elixir
  mob's index it returns `{:yield, ...}`; its `MobTicks` turn runs over the
  same ticker before `mob_section_resume` goes on after it, so the order
  across both kinds is id order; the level random, the pushes native steps
  gave Elixir mobs and the sensed rows of native mobs that moved cross with
  each yield. Elixir melee and lid
  pushes on a native mob mid-tick are section calls with the ticker
  (`mob_section_hit`, `mob_section_displace`). A native turn is
  `MobTicks.ordered_step`'s: fluids sensed, `base_tick`, the think step
  (`Thinker`: a pending `finalizeSpawn` today, the family AI's hook), the
  kernel's step from `MobMotion.kernel`'s input, `MobMotion.apply`, the
  splash, farmland and turtle eggs, `settle`, `MobVitals.apply` and
  daylight. The think step is the family AI's (next section); a plain
  mob has none. The tick's end settles every mob's motion; a mob the kernel
  refused keeps its state from before the tick, and one whose move out of
  the section its owner cannot carry out yet takes it back
  (`mob_section_settle`, after the outgoing handoff's plan when one carries
  it).
- **Plans** run on a store copy in a worker, which reads native records but
  never changes the section: mobs a plan withdraws leave, and mobs it adopts
  join, when its owner adopts the plan (`Store.sync_native/1`).

Where the Elixir draws `:rand` for a mind-less mob (hurt sounds, death
drops, the sun's roll) or skips the draw (a splash, the hiss of a fire put
out), the native mob draws its own random, as vanilla's entity random.

Tests: `native_plain_mobs_test` runs three scenes (falls, water, lava,
fire, effects, pushes and a death for 200 ticks; mind-less mobs pushed by a
player for 120; plain mobs among zombies, a husk and a cow, whose turns
yield, for 120) through an Elixir store and a native one, with the owner's
ageing between ticks, and compares every record after every tick, random
states included where neither side draws, and the level random;
`native_mob_section_test` covers the region paths (fall and landing
damage, hit, name, `/kill` and removal, reload from the log, a teleport to
a sibling section, a push across the section line, a handoff to another
group, an explosion). The entity, region, storage, handoff, portal,
explosion, spawning and native mob suites pass (157 tests), with the
`entity`, `natural_spawning`, `mob_travel` and `combat` stages.

Measured (`mobs` scenario, two pinned cores of the development Mac's Linux
VM, 60 s, `before` at 40f34a8c; raw results in `.local/tick-budget/results/
docker-{preplain,nativeplain}-*-mobs.json`):

| | before 1 | before 2 | native 5 | native 6 |
|---|---:|---:|---:|---:|
| TPS (mean / lowest) | 19.98 / 18.92 | 20.00 / 18.98 | 20.01 / 18.79 | 19.99 / 18.94 |
| Entity phase (sampled) | 13.19 ms | 13.09 ms | 13.91 ms | 14.09 ms |
| Tick mean / p95 (last 100) | 17.2 / 20.1 ms | 17.2 / 20.0 ms | 18.3 / 29.9 ms | 18.0 / 29.9 ms |
| Active mobs / loaded entities | 162 / 762 | 161 / 762 | 161 / 761 | 162 / 763 |

The scenario's population is nearly all farm animals and hostiles, so few
plain mobs take native turns: the change is in the noise for the mean.
Every fifth or sixth tick the group's owner collects its 70 to 120 MB heap
(8 to 10 million words reclaimed) inside its mob phase, about 11 ms, which
the p95 shows; the collection count and total (about 107 major ones, 1.1 s
a minute) equal the run before, which places them outside the measured
ticks. On a scene of 200 plain mobs (`MobTicks` over a supplied view) a
native turn takes 7 µs, the Elixir one 29 µs.

## Native farm animals

The section's tick drives the family AI (`mobs::ai::think::SectionAi`): each
tick builds a `Level` (`mob_section_level`: the owner's clock, difficulty,
weather, rules, light and biomes read from the Region resource, the knots)
and begins the AI with the players, items, native mobs in id order and the
sensed rows of the Elixir ones. A native turn calls `think` (with an
`Outside` for goal positions on the ticker and melee on the section's mobs
mid-tick), `change_other` for the native mobs its AI changed, then after
the kernel step `move_sounds` (a family's splash), `settle` with the
turn's `Moves` and `moved`; an Elixir mob's turn `resense`s it. Families
come from `kinds::Registry` (`mob_facts::kinds()`); their `MotionHooks`
(kernel motion, climbing, the jump, falls) feed the kernel's input. A type
the registry has not ported yields to Elixir. The AI's effects reach the
owner in the Elixir step's shapes (offspring and orbs, eggs laid, grazing,
dropped leads, knots freed or made, a companion's record).

The owner's player paths call the section: an interaction
(`mob_section_interact`, `kinds::interact`: the lead part, then the
family's; the owner rolls the shearing tables and adds sound seeds) applies
as `RegionData.interacted/6` applies an Elixir one, a conversion (a sheared
mooshroom) creating its record; a fence's bind and a knot's use or snip go
through `Leashes` over the native rows' leads (`NativeBody.leash`) and
`mob_section_leash`.

`scripts/check_animals.exs --native` (a second check of the `animals`
stage) runs the farm animals of each oracle scene in a native section
through `MobTicks.native_steps/7`, cats staying Elixir, and compares every
tick with vanilla's as the Elixir run does.

## Native hostiles

The zombie family (zombie, husk, zombie villager, drowned), the skeletons
(skeleton, stray, bogged), creeper, spider, cave spider, enderman, witch,
slime and magma cube are native too. The owner's paths that read a mob's
own state call the section for a native one: its melee hit on a player
(`mob_section_mob_hit`, `Combat.mob_hit/3`), a conversion's new record
(`mob_section_convert`, `kinds::convert`), a dead cube's halves as it is
removed (`mob_section_split`, `Kind::split`), a family field the owner sets
(`mob_section_data`: a chicken jockey's chicken, an enderman's block it
could not put down); arrows, potions, tridents and projectiles take the
shooter's type from its row, and a companion made whole (a spider
jockey's skeleton) arrives as its record. Family death drops (an
enderman's block) ride the death's equipment, as `combat::died` adds them.
A cube's jump reads its lava power (`Kind::jump`), so magma cubes leap out
of lava.

`scripts/check_mob_ai.exs --native` (a second check of the `hostile_ai`
stage) runs the native families' mobs of each scene in a native section:
the AI reads the scene's light (full sky light above each column's top)
and air beyond its blocks, as the oracle's level holds them, and the blocks
mobs took or put down; its mind (goals by registration index, targets,
path, ambient and idle times, a cube's move control) comes from
`mob_section_oracle_mind`. `hostile_spawns` checks `Valimc.AI.Spawn`; the
native `finalizeSpawn`s equal the Elixir ones in `native_mob_hostile_test`.

Region tests read a native mob's body through `Valimc.TestBodies` (its
record restored, with its live health and lead, its mind's goals and
target from the section); the four that set an Elixir body's own fields
(a mind's marker, a motion's wanted position) keep their mobs in Elixir
(`@tag :elixir_mobs`). Revisions stay in step when a sibling's copy of a
store already took a native mob's death (`Store.take_deaths/1`).

## Native dragon

The ender dragon's actor is native (`mobs::boss::dragon`): its phases
(holding, strafing, landing approach, landing, the three perched phases,
takeoff, charging, dying, hovering), the flight with its 64-sample history
and eight parts, the arena graph's A* (the heap's tie order and the
closest-node fallback), the crystal scan and healing, a destroyed crystal's
head hit and the strafe after it, wall breaking, wing and head contacts,
fireballs, the breath's cloud and the 200-tick death with its experience
bursts. Its state stays the `%Valimc.AI.Dragon.Actor{}` term in the body's
`brain` (`codec`), so records and handoffs are unchanged. The family
(`Kind`) gives the living rules its multipart damage: `Hit::dragon_part`,
`Family::damage_result` with the health before the hurt (sitting damage, the
killing blow in flight), `Family::ambient_interval` (a hurt restarts the
clock its actor keeps), `ignites` for arrows on the podium. The dragon's
facts join the native facts (`dragon`).

`native_mob_dragon_test` runs one dragon per scene on both sides over
generated terrain (`mob_parity_dragon`: the tick's outside actions, its
timers, `Actor.environment/3` and `Actor.tick/3`) and compares its record,
position, events, effects and the actions' events every tick: holding and
strafing two moving players with fireballs (600 ticks), the approach,
landing, perching, breath, attack and takeoff over an empty arena (900),
scanning into a charge (500), scanning out into a takeoff, hovering with its
AI off and on, healing from a crystal that is then destroyed by a player,
part hits in flight and perched (head, neck, body, wing, rootless, arrows,
fire, unattributed and tiny hits, sitting damage into a takeoff), a killing
blow through the whole death on a first and a repeat kill and without drops,
wall breaking with and without griefing, and contacts with players and mobs
in flight and perched. The Elixir actor takes the breath's uuid from its
environment where the owner gives one.

The dragon is native in play (`:native_mob_types`). Its section turn
(`Tick::dragon_turn`) skips everything of an ordinary mob's turn: where a
handoff brought it within a tick it already took (`actor::ticked_at`) its
mind is made again, else its actor ticks over an `Arena` built at its turn
(the podium and graph heights from the section's level,
`MOTION_BLOCKING_NO_LEAVES` scanned down as `Arena.height/4`; the section's
mobs where they are now, the group's other native mobs and the owner's
Elixir ones where the tick began; the owner's crystal count, end crystals
and `previous_kill` as the tick's `dragon` extra; a fresh breath uuid), and
the ticker takes its velocity, which the tick's end leaves alone. Its wings
and head land at once on the section's mobs of the tick (pushed, hit as a
`mob_attack` from it at its new position unless a wing meets one hurt within
two ticks, timers run for one still to tick); the rest leave as the Elixir
actor's terms (`DragonEffect::value`, `DragonEvent::value`), which
`RegionData.dragon_effect/2`, the block edits and the sound paths apply
unchanged. Its timers age once a game tick (`dragon::timers`, the tick kept
in `aged_tick` as the Elixir's). A destroyed crystal calls
`mob_section_dragon_crystal` (its head hit and a holding dragon's strafe,
over the group's level); `mob_section_hit` reads `dragon_part`; `/kill`
removes it. The owner reads its phase, part boxes (`Dragon.boxes/1` of its
row, whose data holds its actor) and health (the row's data, for the boss
bar) from its row. `MobTicks.dragon_step` is gone.

Acceptance:

- Every mob oracle stage passes with every type native.
- The `mobs` scenario's entity phase at least 15 times faster than the
  baseline on two cores, tick p95 well under 50 ms.

Checks: pending.

## Resident ticks, changes out

A survey of the `mobs` scenario's entity phase (below) found native turns
a ninth of it: the rest built inputs in Elixir every tick, decoded them,
cloned every mob as a fallback, and encoded and merged a 29-key row for
nearly every mob. The boundary now carries changes, not state.

- **Resident inputs.** The group's `MobWorld` (`mob_tick`, owned by the
  group process) holds the level, set once per group tick
  (`RegionData.native_level/2`), the sensed players and their push boxes
  (set when they change), the loot registry, and the group's sections: each
  Region resource and mob section. A Region keeps the chunk snapshots it last
  published (`snapshot_publish` records them beside the ETS rows); a
  section's resident view holds those of its own and its neighbouring
  regions and resyncs a region only when its publication counter moved.
  Groups keep their loaded chunks 24 apart, so the group's regions are every
  chunk a mob can read. Light and biomes come from the section's own Region
  as before. Kernel inputs (travel attributes shared per type), the turn
  order, solid colliders (the group's native shulkers, from sections that
  count one) and the POI claims (each section keeps its villagers' as of its
  last tick) come from the sections' mobs. The owner names per tick only the
  game tick, its simulated chunks as a 64-bit mask, the level random, its
  Elixir mobs with their kernel maps and rare extras: items, knots, scoped
  goals, anger events, Elixir POI claims, an answered structure query.
- **One call.** `mob_section_tick` runs every turn when the section has no
  Elixir mob; with one (the dragon, test scopes) it yields at its index with
  a ticker and `mob_section_resume` goes on. The group's phases run section
  by section (blocks, events, entities, pistons, hoppers, cooking for each),
  so one call per group tick would reorder mob turns against other
  sections' block ticks; a section's call carries no state, so the call
  count costs microseconds.
- **Changes out.** The tick reports the moved mobs' physical states
  (position, rotations, motion, ground) as one packed binary, which
  `Store.native_tick/3` mirrors into each entry, row and view without
  rebuilding the view; a chunk change updates the index. A mob with a new
  row (its fields beside the physical ones, `publish::RowKey`, or what
  observers see), events, effects or a move out of the section comes back
  as a change; only those rows are encoded. Gone: the per-tick row build and
  encode, `NativeBody.merge` and `Store.advance` for native turns, the
  reject pass, and the Elixir order, external and collider lists.
- **No clone per tick.** A mob keeps its state before the tick only where
  its turn may leave the section or meet a chunk the view cannot read (its
  box widened by 8 blocks and its speed, or a teleporting family); the
  others keep only where they began, which a refused move out restores.
- **Ageing, spawning, portals, redstone.** Ageing is one call
  (`mob_section_age_tick`); idle and lived counts live on the slot.
  Natural spawning reads the native mobs' rows and boxes from their
  sections and resets their idle times there. A turn's portal sweep reads
  the section's own blocks: a touch renews the cooldown or, off cooldown,
  comes back as `{:portal, kind, cell}`. Redstone's contacts take the
  native mobs' boxes as one binary their section packs.
- **Records.** A cut builds a touched mob's stationary record (its record
  without travel fields and mind) to learn whether its change waits for the
  motion pass; only a changed stationary part builds the whole record.
- **Locks.** A tick holds its own section and only tries its siblings'
  locks: one a group took since the world's list was set is left out
  rather than risk two owners waiting on each other.

The brain wiring rides the same tick: the level random reaches the AI's
start and keeps its draws; the level carries the dimension, its fixed
time, the players' anger events, the POI claims, answered queries and the
loot registry; the AI's block finder reads the tick's snapshots; a
villager gets up where `StandUp.bed` puts it (native, with the sleep facts
from `SleepFacts`; `native_mob_stand_up_test` compares 400 scenes); a
piglin's barter is rolled from its seed and thrown by the owner.

Every family `mobs::kinds` ports is native, the dragon too
(`:native_mob_types`). The oracle stages' native modes run every family;
see "Native oracle coverage".

## Measurements

The `mobs` scenario (`bench/tick_budget.exs`, two pinned cores of the
development Mac's Linux VM, 60 s, about 160 active mobs in 11 of 79
sections). Probe of the boundary at cc304f37 (`docker-probe-{1,2,3}`,
ms per tick): entity phase 13.5; native turns (think, kernel, settle)
1.49; building NIF inputs in Elixir 1.67 (view cells, AI world, native
env, kernel inputs, colliders, region; about 8.5 KB a section);
`mob_section_begin` 1.62 (view 0.54, env decode 0.40, the fallback clone
0.36, kernel inputs 0.21); the Elixir mobs' yields 1.85;
`mob_section_finish` 1.17 (rows 0.37, encode 0.57, compare 0.13);
`Store.advance` and the effect scans 0.82; portal contacts 0.61; ageing
0.60; redstone contacts 0.41; tracking 2.25; the native cut 0.66 (of 0.89);
`SpawnInputs.prepare` 0.32; collections about 2.1 with 30 ms spikes every
7 to 8 ticks.

Before (aadfe6c4, the boundary above) and after (4e4426d3), matched
workloads:

| | before 1 | before 2 | after 1 | after 2 |
|---|---:|---:|---:|---:|
| TPS (mean / lowest second) | 19.99 / 18.79 | 20.00 / 18.81 | 19.99 / 18.98 | 19.99 / 18.98 |
| Entity phase (sampled) | 12.94 ms | 12.87 ms | 7.75 ms | 7.35 ms |
| Spawning phase | 1.84 ms | 1.56 ms | 1.83 ms | 1.96 ms |
| Tick mean / p95 (last 100) | 16.9 / 30.8 ms | 16.6 / 30.4 ms | 12.2 / 16.1 ms | 12.6 / 14.9 ms |
| Active mobs / loaded entities | 163 / 763 | 160 / 761 | 162 / 763 | 162 / 763 |

The p95 lost the collection spikes. The spawning phase now reads the
native mobs from their sections where it built rows in Elixir (its inputs
0.32 to 0.11 ms); the phase stays within its noise.

Probe after (`docker-resident3probe-1`, ms per tick): entity phase 7.45;
the tick call 3.16, of it native turns 1.18, kernel inputs and order 0.22,
solids 0.60 (since counted per section), fallbacks and the tick's start
0.21, the AI's start 0.12, row checks 0.25, the report 0.28, portal
sweeps 0.09; the owner's extras 0.18, applying the report 0.11; ageing
0.09 natively plus 0.03; redstone contacts 0.34; tracking 2.41 (made
native and change-driven in [081i](VMC-081i.md)); the native cut 0.54 plus 0.25 encoding (20 cuts a tick);
spawning inputs 0.11. Raw results in `.local/tick-budget/results/
docker-{before081d,after081d}-*-mobs.json` and `docker-resident3probe-1`.

Checks: the region, entity, combat, projectile, portal, explosion,
spawning, travel, redstone and native mob suites (364 tests, connection suites
included); `cargo test` of the core; the 26 mob stages: mob_ai (16,263 of
18,263 ticks native), nether_mobs (5,000 of 7,940), dolphin_treasure,
animals and hostile_ai (all native), village, entity, combat,
natural_spawning, mob_travel, hostile_spawns, aquatic_packs, bucket_mobs,
water_age, the shulker, puffer, turtle, endermite, guardian and dolphin
breath stages.

Left: a cheaper test than the stationary record for a touched mob's
persistent change.

## Native oracle coverage

Every mob stage runs a second check against vanilla with its mobs native
(`--native`), before the Elixir mob path goes.

- **Brain mobs.** The harnesses seed a native brain as the oracle seeds
  one: `mob_section_oracle_brain` sets its mind's random, its gates'
  randoms and its sensors' countdowns; `mob_section_oracle_villager`
  builds a villager's brain with the oracle's gates, activity order
  (vanilla's hash order, `Brain::ordered`) and the gates each remade brain
  takes (`Brain.refresh`), started by its schedule. The checks read
  behaviours, activity, gates and memories through
  `mob_section_oracle_brain_view`. A scene's supplied blocks answer block
  searches (a piglin's repellents) and stand villagers up; native pickups
  leave the scene's items and barters are rolled and thrown as the owner
  does.
- **The dragon stages** drive the native dragon over their hand-built
  envs (`dragon_oracle_flight`, `_paths`, `_phases`, `_actor`): its
  flight, part boxes, graph and paths; phase sequences with their
  players, sight, ground and collisions; whole actor runs in a native
  section (timers, tick, a destroyed crystal); multipart damage and
  arrow ignition; the phase metadata. `end_crystal` takes a dragon's hits
  from a native dragon and `dragon_arena` the bar's progress from a native
  dragon's row.
- **Fixes the native runs found:** a native melee hit on a section's mob
  now takes what its attacker's family adds (an iron golem's damage and
  throw), as the Elixir tick merged it; the phases retarget on a
  collision as vanilla's do; a NoAI mob's structure answer stays with its
  section until it takes it; native villagers' POI tickets reach the
  owner's claims (trader and cat spawners, siblings).

Native checks per stage (every one native): mob_ai 18,263 ticks, nether_mobs
7,940, hostile_ai 10,182, animals 11,948, village 6,069, dolphin_treasure 720;
dragon_actor 15,585 ticks, dragon_phases 56,184, dragon_flight 5,280 ticks and
10,368 paths, dragon_damage 12,320 hits, end_crystal 48 damage cases,
dragon_arena 54 boss packets; endermite_life 10, turtle_growth 32 and
guardian_hurt 36 traces. The 33 mob stages pass (entity, combat,
natural_spawning, mob_travel and the others start owners, whose mobs are all
native).

The region tests that read brains or set body fields run native mobs
(villager, piglin, hoglin, iron golem, cat, wandering trader, guardian,
zombie, husk, dolphin): `Valimc.TestBodies` reads activity, memories and
paths and changes NoAI, cooldowns and move targets through the section
(`mob_section_oracle_set`, `_put`). No test keeps `:elixir_mobs`.

Still on the Elixir mob path, to retire with it: the parity suites
(`native_mob_*_test`, `native_plain_mobs_test`, `NativeMobScene`) and the
unit tests of Elixir AI modules (`ai_move_sink`, `ai_spatial`,
`aquatic_age`, `dolphin_treasure`, `enderman`, `item_step`, `mob_sense`,
`puffer_resize`, `silverfish`, `shulker_mob_collision`); tests building a
dragon's brain as Elixir structs for its record (`dragon_actor`,
`dragon`, `group_projectile`); and the stages' Elixir modes beside their
native ones.
