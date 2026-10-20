# VMC-029c — Blocks that lose their support break

Status: Done
Note: Live in play for in-region neighbours; client run passed on `248a539` (imported world).
Milestone: D blocks (VMC-029), needed by M2 imported worlds
Depends on: [VMC-066](VMC-066.md) (tick pipeline, shape-update hook),
[VMC-068](VMC-068.md) (block registry), [VMC-021](VMC-021.md) (imported worlds).

Before this slice nothing in ValiMC checked whether a block can stay where it is.
Mining the grass under short grass or a flower left the plant floating, torches
stayed on removed walls and sugar cane stood on air. Flat worlds rarely showed it;
imported vanilla terrain shows it everywhere (found in the VMC-021d client run).

Vanilla runs `updateShape` on the six neighbours of every changed block. A
dependent block that can no longer survive (`canSurvive`) returns air, which
`Block.updateOrDestroy` turns into `Level.destroyBlock` with drops: the block
leaves its fluid (a waterlogged block leaves water), drops its tool-less loot and
plays its break effect (level event 2001). Some classes check only the face they
hang on (torches, wall torches, lanterns, buttons), some schedule a tick that
breaks them (sugar cane, cactus, kelp), and two-block blocks break when their
other half goes (doors, beds, tall plants).

Scope: that survival behaviour for every block state whose rule the oracle can
derive from vanilla's code, applied after every block commit in a region.
Shape changes that are not breaks (fence connections, stair shapes, vine faces
falling off one at a time, snowy grass) belong to later VMC-029 slices.

Acceptance:

- Facts are generated, never hand-written: `SupportOracle` runs vanilla's
  `canSurvive` and `updateShape` for every state against a synthetic world that
  records each position read. It derives per state the offsets survival reads,
  a partition of all states at each offset into classes that behave alike, a
  survival table over the class combinations, the reaction per update direction
  (break, own tick with its delay, nothing) and neighbour overrides (a missing
  other half breaks; a few neighbours keep a block that cannot survive). Light
  reads are existential (survives if bright or dark light lets it) until ValiMC
  has lighting. A state whose model does not reproduce vanilla on random
  neighbourhoods is excluded and listed with its reason.
- Differential stage `support`: the facts regenerate byte-equal, and on random
  neighbourhoods of every dependent state (independent of the oracle's own
  validation) `Valimc.Block.Support` matches vanilla's survival and update
  outcome, and each state's remains equal `Valimc.Block.after_removal/1`.
- In a region: after any block commit (placement, mining, transfers, raw creative
  edits, tick edits) each in-region neighbour that the update breaks or ticks
  schedules its tick; at the tick it breaks if it still cannot survive. All breaks
  of one tick are one durable commit (the mining frame: cells plus items) with
  their deterministic tool-less drops, which pop and fall like vanilla
  `Block.popResource`, then the level event goes to players within 64 blocks. A cascade (cane column, tall plant, torch on a broken block)
  advances one block per tick; at most 4,096 breaks per tick, the rest wait.
- Breaks never block the owner: behind a planning transfer or a full write queue
  they retry on the next tick.
- Player-visible: in an imported world, mining grass under short grass and
  flowers, removing a torch's block and the base of sugar cane remove those
  plants and torches (with drops where loot is deterministic), and they stay gone
  after a reconnect.

Reference: Mojang 26.3 server jar (SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`):
`BlockBehaviour.updateShape/canSurvive`, `Block.updateOrDestroy`,
`Level.destroyBlock`, `LevelReader`, `ScheduledTickAccess`; classes observed
through the oracle rather than read: `VegetationBlock`, `TorchBlock`,
`WallTorchBlock`, `SugarCaneBlock`, `CactusBlock`, `DoublePlantBlock`,
`DoorBlock`, `BedBlock`, `MultifaceBlock`, `VineBlock`.

Design:

- `Valimc.Block.Support` loads `priv/physics/support.json`: partitions packed at
  the fewest bits per state, rules as bit tables, one 2-byte profile index per
  state. `update/4` (neighbours changed in some directions), `breaks?/3` (at the
  tick) and `survives?/3`. A neighbour outside the region is unknown and never
  breaks anything.
- `RegionData.shape_updates` (VMC-066's hook, now also after raw `set_block`)
  adds `support_updates`; `block_ticks` sends due dependent blocks that cannot
  survive to `support_breaks`, which commits through `Store.commit_mining` and the
  group-commit queue like a mining transfer. No new transaction mechanism.
- Vanilla breaks immediately; here a break waits for the next tick so the removal
  and its drops are one durable frame. Sugar cane and cactus use vanilla's own
  one-tick delay.

Limits:

- Drops come from the deterministic loot facts (`MiningLoot`, native-verified
  with an empty tool). Loot that is random or needs a tool or a location check
  (short grass and fern seeds, dead bush sticks, tall grass) drops nothing yet.
- Neighbours across a region border are neither updated nor read.
- Creative removal of one half of a door, bed or tall plant drops the other
  half's item; vanilla's `playerWillDestroy` suppresses that drop in creative.
- Rails, redstone wire, repeaters and comparators break in vanilla through
  `neighborChanged`, not `updateShape`; they are not covered.
- Excluded classes are listed in the facts (`excluded`) and below.
- Light is not modelled yet: a rule that reads light survives if either bright or
  dark light lets it (crops, mushrooms), so light never breaks a block.
- A region holds at most 256 items; drops beyond that are not created.

Progress (October 20, 2026):

- `SupportOracle` (oracle stage `support`, about 5 minutes on 10 cores):
  - It runs vanilla's own `canSurvive`, `updateShape` and, for tick reactions,
    `tick` against proxy `LevelReader`/`ScheduledTickAccess` worlds and a probe
    `ServerLevel`, with block and fluid tags bound from the vanilla data pack.
  - Per state it refines partitions of all 35,723 states at each read offset (by
    result and read trace, around a failing and a surviving context) until they
    are stable, then tabulates survival.
  - A tick reaction is kept only where vanilla's tick breaks the block exactly
    when it cannot survive. A block whose model fails self-validation on random
    neighbourhoods is excluded whole.
  - Result: 7,337 dependent states, 192 rules, 201 partitions, 348 profiles;
    `priv/physics/support.json` is 0.7 MB.
- Covered, among others: vegetation and flowers, saplings, crops, mushrooms,
  dead and dry bushes, tall plants and doors (both halves), beds, torches, wall
  torches, redstone torches, lanterns, bells, buttons, levers, pressure plates,
  ladders, signs, wall signs and banners, carpets, snow layers, sugar cane,
  cactus, kelp, seagrass, sea pickles, cave, weeping and twisting vines, bamboo,
  cocoa, chorus flowers, dripleaves, amethyst buds, repeaters and comparators,
  candle cakes, piston heads, faceless multiface blocks and vines.
- Excluded with reasons in the facts: living coral fans and plants (their
  updateShape also schedules the death tick), farmland and dirt paths (their tick
  turns them to dirt), scaffolding and bubble columns (their tick does more than
  break), chorus plants (more than eight offsets), attached stems, liquids,
  observers, part of pointed dripstone and sulfur spikes (they read scheduled
  ticks), nether portals, pale moss carpets (side faces are shape changes).
- Rails, multiface blocks that keep some faces and vines that keep some faces
  have rules but no break reaction (vanilla changes their shape or uses
  `neighborChanged`).
- Owner: `support_updates` and `support_breaks` in `RegionData`; the level event
  packet (`Packets.level_event/3`, 2001) reaches players within 64 blocks.
  Imported block entities whose data must be preserved (VMC-021e) keep their
  block; the other breaks of that tick go ahead.

Checks:

- Oracle stage `support` passes: regeneration is byte-equal, and 44,022 random
  vanilla neighbourhoods (survival and update outcome) plus the remains of all
  7,337 dependent states match `Valimc.Block.Support`.
- `test/block_support_test.exs` (8): rules for short grass, torches, wall torches,
  sugar cane, tall grass halves and unknown neighbours; in a stepped region a
  poppy and torches on removed blocks, a three-high cane column (one block per
  tick, three drops), a tall plant losing its upper half, and a break plus its drop
  surviving an owner kill.
- The unit tests found two oracle bugs the self-validation could not: fluid tags
  were unbound (water looked like air to sugar cane) and air counted as breaking.
- `mix test.fast` passes (1,084) after the drop fix. Earlier runs under load
  failed three timing-sensitive tests (cross-merge, placement receipts,
  container store) that passed alone. `scripts/audit_public_tree.py` and
  `mix format --check-formatted` pass.
- `bench/block_support.exs` (10,000 checks, random neighbourhoods): 3.69 ms for
  dependent states and 0.91 ms for plain states, about 0.37 µs and 0.09 µs per
  neighbour check.

Client run 1 (October 20, 2026; frozen `d537841`; imported world, creative;
`.local/client-tests/VMC-029c/`):

- PASS:
  - Short grass and both tall grass halves vanish when the grass block under
    them is mined.
  - A poppy and a dandelion break and drop themselves.
  - A three-high sugar cane column falls one block per tick (about 50 ms
    apart) and drops three canes.
  - A standing torch on a removed plank breaks and drops a torch.
  - Negatives: flowers, short grass and a torch beside (not on) a removed block
    stay.
  - Everything stays removed after a reconnect and after a server restart.
  - Server logs are clean.
- FAIL: every drop hovered motionless at the block centre. The records carried no
  motion, so the owner created them as stationary, no-gravity items. Fixed: drops
  now pop like `Block.popResource` (random offset, upward launch, 10-tick pickup
  delay), so the item simulation lets them fall. Covered by the owner test.

Client retest (October 20, 2026; frozen `248a539`; same dataset), all PASS:

- Two sugar canes on a removed block popped and fell: one came to rest on the
  hole floor about 1.6 s later, the other into nearby water, where it floated.
  Pickup delays counted down from 7–9.
- A poppy popped up, came to rest beside the hole and was picked up.
- A three-high column dropped its canes one per tick. Two merged; all lay on the
  ground and stayed there after a reconnect.
- The server log is clean. Earlier drops despawned after 6,000 ticks as in
  vanilla.

Next: random and tool-dependent no-tool loot (seeds from grass, sticks from dead
bushes), cross-region neighbour updates, shape changes that are not breaks
(multiface and vine faces, moss carpet sides), creative drop suppression for the
other half of doors, beds and tall plants, and `neighborChanged` removals (rails).
