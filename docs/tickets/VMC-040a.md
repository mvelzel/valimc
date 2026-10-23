# VMC-040a — Beds, sleep and spawn points

Status: Awaiting client
Milestone: M3
Depends on: [VMC-029d](VMC-029d.md) (two-part beds), [VMC-050a](VMC-050a.md)
(bed explosions).

- **Sleeping:** players sleep in beds; the night skips when the
  `playersSleepingPercentage` share sleeps; monsters nearby forbid sleep, and
  phantoms count time since rest.
- **Spawn points:** a bed sets the respawn point, and respawning at a missing
  or blocked bed falls back as vanilla does.
- **Explosions:** beds explode in the Nether and the End.
- **Respawn anchors:** they charge with glowstone and explode outside the
  Nether.

## Design

- **Facts.** `SleepOracle facts` writes `priv/physics/sleep.json`
  (`Data.SleepFacts`): each dimension type's `gameplay/bed_rule` and
  `gameplay/straw_bed_rule` (can sleep, can set spawn, destroy on use or
  leave, the error message), whether anchors work there and whether its time
  is fixed (no biome overrides them, which the oracle checks); each bed
  block's rule and sleep heights (a straw bed's head lies on its foot); the
  entity types whose instances are `Monster` (they keep players from
  resting; the zombified piglin only when angry); and per state the inputs
  of `DismountHelper`: suffocating, dangerous to a player,
  `invalid_spawn_inside`, and the top of the non-climbable collision shape.
- **Stand-up.** `World.StandUp` ports `AbstractBedBlock.findStandUpPosition`
  (bunk beds included), `RespawnAnchorBlock.findStandUpPosition`,
  `findSafeDismountLocation` (the player's box through the kernel, the
  border) and the look-at yaw, and decides a respawn point as
  `findRespawnAndUseSpawnBlock` does (not forced).
- **Sleeping** (`Player.Sleep`, in the session): `startSleepInBed`'s checks
  in order (reach, obstruction, the spawn, the rule against the sky's
  darkening, monsters in the 16 × 10 box around the bed from the group's
  stores, unless creative), then the player lies on the bed: both halves
  occupied by a fenced write, the sleeping pose and sleeping position in its
  entity data (to itself and its trackers), a teleport onto the bed and the
  time since rest restarted. A sleeper's moves are ignored (more than a
  block away is sent back) and its pose is not sampled. It gets up when it
  leaves the bed (`STOP_SLEEPING`), its bed goes, the rule ends (daybreak),
  it is hurt, teleported, dies or disconnects, and when a saved sleeper
  joins: the wake animation, the bed freed (a straw bed goes in the
  overworld), and a teleport to the stand-up position facing the bed.
- **Night skip** (`World.SleepStatus`, kept by the environment owner): a
  session tells it when its player lies down, has slept 100 ticks and gets
  up, so nothing reaches it while nobody sleeps. While someone sleeps it
  counts each dimension's players that are not spectators from the player
  list each tick, announces changes as `announceSleepStatus` does, and when
  enough sleep and enough slept long enough it moves the dimension's clock
  to the `wake_up_from_sleep` marker (when time advances), clears the rain
  (`resetWeatherCycle`, when weather advances) and wakes the sleepers. The
  `players_sleeping_percentage` rule is read from `GameRules` (100).
- **Respawn points** (`Player.RespawnPoint`, saved with the player): set by a
  bed whose rule sets spawns and by a charged anchor in the Nether ("Respawn
  point set" once per new block). A respawn reads the point's block in its
  dimension (awaiting its chunks), stands the player up beside it facing
  it, and spends an anchor's charge by a fenced write at its owner (read
  again once when another change came first), playing the depletion to the
  player. A missing, spent or blocked point is forgotten: the world spawn,
  after the `NO_RESPAWN_BLOCK_AVAILABLE` game event. Leaving the End and
  returning after the credits use the point too, keeping an anchor's
  charge.
- **Bed and anchor use** (`Player.SpawnBlocks`, before menus and
  placement): a bed's other half must be there; where the rule destroys
  beds on use (the Nether, the End) a bed explodes at its head (power 5,
  fire, `bad_respawn_point`, block drop decay) and a straw bed breaks; an
  occupied bed says so. Glowstone charges an anchor below 4 (the off hand's
  glowstone takes over from a main hand without it); a charged anchor sets
  the spawn in the Nether and explodes elsewhere, breaking nothing when
  water would flow into its cell or stands on it (its cell then resists as
  water, which no ray outlasts). Explosions go to their section's owner as
  a message, so they run after the use's callback and hit every player of
  the group through its session. `Explosion` gained its damage `source` and
  `blocks: false`.
- **Counter.** `time_since_rest` counts the ticks a player is not asleep,
  restarts when it lies down or dies, and is saved; phantoms (VMC-043b) read
  it.
- Player files gained `respawn`, `sleeping` and `time_since_rest` (older
  files are refused, as other format changes).

Not here: forced respawn points (`/spawnpoint`, VMC-053n), villagers in beds
(`kickVillagerOutOfBed`), statistics and advancements, a zombified piglin's
anger, the comparator output of an anchor (VMC-048a), and sleeping in a
moving vehicle.

## Acceptance

- Sleep, skip and respawn fixtures match the oracle.
- With two clients, one sleeping alone does not skip the night under the
  default percentage.

## Results

- `sleep` stage (`SleepOracle`, `check_sleep.exs`): the facts regenerate
  byte for byte; over 240 seeded scenes of beds, straw beds, bunk beds and
  anchors among 31 kinds of obstacles, 1,440 stand-up searches and 1,440
  respawn points (beds, anchors of every charge, missing blocks, in all
  three dimensions, with the yaw and the spent charge) equal vanilla's;
  2,000 bed ranges, 200 obstructions and 324 `SleepStatus` counts too; the
  wake animation, sleeping position, missing-respawn-block, sleep status
  and spawn messages, and the bad respawn point's death message and
  exhaustion equal vanilla's.
- `test/sleep_connection_test.exs` (tcp): a zombie nearby keeps a player
  awake while the bed still sets the spawn; the player lies down at night
  (both halves occupied, on the bed), leaves the bed and wakes when hurt;
  one of two players asleep keeps the night, both asleep skip to morning
  and wake; a death respawns beside the bed and, without it, at the world
  spawn with the game event; glowstone charges an anchor that blows up in
  the overworld; a bed explodes in the Nether.

## Client scenario

In a fresh world with two clients A and B in survival, at night
(`/time set midnight`): `/give @s red_bed 2` to each, and A also
`/give @s glowstone 4` and `/give @s respawn_anchor`.

1. A places a bed and uses it: "Respawn point set" shows, the screen fades
   and A lies in the bed (B sees A lying in it). The night does not skip;
   the hotbar shows 1/2 players sleeping. B sleeps in its own bed: the night
   skips to morning and both wake beside their beds.
2. At night, with a zombie summoned five blocks from A's bed
   (`/summon zombie ~5 ~ ~`), A's use says "You may not rest now;
   there are monsters nearby". By day it says "You can sleep only at night".
3. A dies (`/kill`) and respawns beside the bed, facing it. A breaks the
   bed, dies again and respawns at the world spawn with "You have no home
   bed or charged respawn anchor, or it was obstructed".
4. A places the anchor and uses it with glowstone twice: it lights up two
   charges and one glowstone is left of each use. With an empty hand A uses
   it: it explodes with fire. In the Nether (`/execute in minecraft:the_nether
   run tp ~ ~ ~`), a bed used there explodes; an anchor charged there and used
   with an empty hand sets the spawn, and a death there respawns beside it,
   one charge fewer.
