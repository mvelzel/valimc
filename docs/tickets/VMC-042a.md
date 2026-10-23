# VMC-042a — Natural spawning and despawning

Status: Done
Milestone: M3
Depends on: [VMC-015i](VMC-015i.md), [VMC-043a](VMC-043a.md).

Spawning follows vanilla's `NaturalSpawner`:

- mob categories and their per-player local caps (26.x);
- biome spawn lists from the data reports and spawn placement rules;
- light and the spawnable surface;
- pack sizes and the spawn tick cadence;
- the spawns made with a chunk when it generates.

Despawning follows the instant and random distances, persistence (name tags
and picked-up items) and the peaceful-difficulty rules. Spawning runs in each
group over its simulated chunks. A cap counts what the group sees near its
players, so no global process counts mobs.

Acceptance:

- In fixed seeds and positions, spawn attempts choose the oracle's mobs,
  positions and packs.
- Caps hold with several players in one group and in separate groups.
- Mobs despawn at vanilla's distances.

## Implementation (October 23, 2026)

- **Facts.** `NaturalSpawnOracle facts` writes `priv/registry/spawn_facts.json`
  (stage `spawn_facts`): every biome's natural spawns (type, weight, count
  provider) from its `gameplay/natural_mob_spawns` attribute, its spawn
  costs and creature probability at generation; each dimension's monster
  light test, block light limit, ambient light and the timeline tracks of
  the sky light level and the surface slime chance; each spawning type's
  spawn box, the block tag it is immune to, `getMaxSpawnClusterSize`, a
  school's size, whether it is a `PathfinderMob` and breathes under water;
  and per block state its `isValidSpawn` kind (none, every type, ocelots and
  parrots, polar bears, fire-immune types) and a word of the rules' block
  tests (spawnable-on tags, leaves, sand, `isPathfindable`, burning and
  dangerous blocks, light dampening, the single blocks the rules name).
  `Data.SpawnFacts` joins it with the entity facts for the kernel.
- **Kernel.** `valimc_core::spawning` is `NaturalSpawner`: `createState`
  (counts, potential charges, per-player local caps), the filtered
  categories (the global cap over the chunks within eight of a player, the
  persistent categories every 400 ticks), the shuffled spawning chunks,
  `getRandomPosWithin`, `spawnCategoryForPosition` with its three packs, the
  24-block player and world-spawn rings, the weighted pick (water ambient
  reduced in its biomes), `isValidSpawnPostitionForType` and
  `isValidPositionForMob`, the placement types, every registered spawn
  predicate of the biome lists' types (monsters' darkness with thunder's
  brightness, animals' brightness, bats, slimes in slime chunks and by the
  moon, drowned, guardians, strays under powder snow, striders, turtles,
  fish and their schools, ...), a fresh mob's walk target and obstruction,
  the spawn box's block collisions (the physics kernel's), then
  `spawnMobsForChunkGeneration` with `getTopNonCollidingPos`, and
  `Mob.checkDespawn`. It reads blocks, light, heightmaps and zoomed biomes
  from the group's stores (`Live`) or an oracle scene (`Scene`).
- **Group.** Each group runs `World.Spawning.plan/1` once a tick before its
  sections' entities tick: one `natural_spawn` call (dirty past about 1 ms
  of work) with its players, its mobs (persistent, in a simulated chunk,
  idle and lived ticks), its living bodies' boxes and simulated chunks, the
  world spawn, the published clock, weather (sky darkening by vanilla's
  environment attributes), difficulty and border, and the `spawn_mobs` and
  `spawn_monsters` rules. Sections adopt the new mobs (plain bodies of their
  type) and drop the despawned ones in the group's next commit. A group
  without players skips the tick. The caps count what the group holds;
  groups' loaded chunks are 24 chunks apart, so no global process counts.
- **Generation.** A chunk installed from generation gets its biome's
  creatures in the same commit, drawn from its decoration seed.
- **Despawning.** Instant past the category's distance, randomly past 32
  blocks after 600 idle ticks, never for persistent mobs (a name tag:
  `interact` with a named name tag names a mob, makes it persistent and is
  used up outside creative), every monster in peaceful. Idle and lived ticks
  are counters on the store entry, saved by neither ValiMC nor vanilla.
- **Plain mobs.** Every living type of a spawning category is modelled as a
  plain body (its own entity data at vanilla's defaults) until its family
  models it; water mobs keep their air (`canBreatheUnderwater`).

Not here: what `finalizeSpawn` decides (variants, sizes, equipment, babies,
jockeys) is the families' (VMC-043b–e), and it draws from a random of its
own; structure spawn overrides and the fortress's enemies need structure
starts at runtime and moved to [VMC-042b](VMC-042b.md); the custom spawners
(phantoms, patrols, cats, wandering traders) come with their mobs; a group
without players does not despawn its mobs (vanilla's nearest player may be
anywhere in the dimension); a hurt does not restart a mob's idle time yet;
a generated chunk's creatures spawn once its neighbours decorated it.

Reference: 26.3 `NaturalSpawner`, `LocalMobCapCalculator`,
`PotentialCalculator`, `MobCategory`, `SpawnPlacements`,
`SpawnPlacementTypes`, `ServerChunkCache.tickChunks`,
`ChunkMap.collectSpawningChunks`/`getPlayersCloseForSpawning`,
`NoiseBasedChunkGenerator.spawnOriginalMobs`, `Mob.checkDespawn`/
`checkSpawnRules`/`checkSpawnObstruction`, the predicates of `Monster`,
`Animal`, `Bat`, `Slime`, `Drowned`, `Guardian`, `Stray`, `Strider`,
`Turtle`, `WaterAnimal`, `TropicalFish` and the rest, `EnvironmentAttributes`,
`WeatherAttributes`, `KeyframeTrackSampler`, `Level.updateSkyBrightness`,
`NameTagItem`; decompiled privately with Vineflower 1.12.0
(`research/decompiled/vmc-042a`).

Checks: stage `natural_spawning` (`NaturalSpawnOracle fixtures`, a probe
level over 42 scenes — plains by night and day, caves, lush caves, deep
lakes, four oceans, deserts, snow, ice spikes, swamps, slime chunks,
jungles, mushroom fields, forests and mountains, five Nether biomes with
their spawn costs, the End, peaceful and thunder): 44,000
`spawnForChunk` ticks from seeded level randoms give vanilla's 10,255 mobs
with their positions, yaws and packs and leave the random where vanilla's
is; 138 creatures of 1,280 generated chunks equal vanilla's; 512 despawn
checks and 120,000 sky darkenings (a day in five weathers) match.
`check_vanilla.py --only spawn_facts --regen` equals the committed facts.
`test/natural_spawning_test.exs`: one player's monsters stop at 70, two
players in one group and players in separate groups each keep their own
caps, a spectator spawns nothing, mobs despawn past 128 blocks and in
peaceful while cows and named mobs stay, a name tag survives a record,
generated chunks get their creatures. `cargo test -p valimc_core spawning`;
`mix test.fast` 465/466 after the rebase, the one failure a block-query
timeout under host load that passes alone; `check_vanilla.py --changed`
111/111 before it, its spawning, entity, mob travel and TCP stages after.

Bench (`bench/natural_spawning.exs`, `MIX_ENV=bench`, October 23 at host
load about 8 on 10 cores): nine sections of stone with three cave layers
under grass, one player at night, the spawned mobs joining the counts: the
whole tick (mob list, kernel call, records) takes a median 0.26 ms while
the caps fill and 0.25 ms at the caps (99th percentile 0.47 ms); with 600
zombies placed across the sections (most despawn) 0.29 ms (0.6% of a 50 ms
tick).

Client scenario (phase-end handoff): in a fresh vanilla world, the animals
of the biome stand around the spawn (generated with their chunks). At
night (`/time set night`) in survival, monsters appear in the dark at least
24 blocks away and stand (no AI before VMC-041a); `/difficulty peaceful`
removes them at once, animals stay. Back on normal, fly 130 blocks away and
back: the monsters near the start are gone. `/give @s
name_tag[custom_name="Bob"]`, use it on a zombie: it shows "Bob", the tag is
used up in survival, and the zombie stays when you go 130 blocks away and
return.

## Client run (October 23, 2026; frozen `1b72b467` release, fresh worlds; `.local/client-tests/M3-run-2/run-04` to `run-06`)

Passed in a vanilla world (seed 932992301210947215, old-growth spruce taiga):

- Sheep stood around the spawn on joining.
- At night in survival on normal, zombies, skeletons, creepers and spiders
  spawned; the nearest zombie was about 45 blocks away.
- `/difficulty peaceful` removed them and the sheep stayed. Spiders were
  gone at once; a zombie, a skeleton and a creeper were still selectable a
  second or two later and gone by 5 s (vanilla discards them the next tick).
- A summoned zombie stayed while the player was near; after 8 s 165 blocks
  away it was gone.
- A name tag "Bob" used in survival named a zombie and was used up; Bob
  stayed through 12 s 165 blocks away (its record: custom name, persistent).
