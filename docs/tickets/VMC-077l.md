# VMC-077l — Physics kernel in Rust

Status: Foundation
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) (the audit and plan),
[VMC-077d](VMC-077d.md) (the one installed fact table),
[VMC-077e](VMC-077e.md) (`World.View` over published snapshots).
Note: Foundation until the milestone client run walks, swims, steps and drops
items with the kernel.

Before: entity physics was about 70 Elixir modules under `lib/valimc/physics/`.
Each move packet started a pooled task (`CollisionQuery`, a partitioned
collision worker pool) with a 250 ms admission deadline, signatures, retries on
a full pool and `motion_pending` socket gating; the connection matched results
by job kind (`:motion`, `:pose`) and corrected the player when a deadline
passed (the audit's correction classes C1/C2 and finding E5). A resting
player's pose and kinetics were a second pooled job per tick. Items moved in
owner-linked `ItemSimulation` jobs that fanned out to `ItemPhysicsQuery` tasks
in two global pools (`ItemSimulationWorkers`, `ItemGeometryWorkers`), with a
resting cache of section fences. The supporting block was computed three ways,
collider composition three ways, the collision context five, and every module
carried its own f32 helper. Placement checked obstruction only against the
placing player (audit finding E7).

Scope: the kernel crate and its NIF module, `lib/valimc/physics/**`, the
player's motion and pose queries and their connection handlers, item motion in
the region tick, the oracle checks that cover them, and moving non-physics
modules out of `physics/`. Not here: the player's travel rules around the
kernel's geometry (jump, fluid and climbing controls, sneak edges, swimming;
see Deferred), block-entity collision snapshots, `RegionData` beyond the
items-phase hook (VMC-077f/g), the block-rule engine (VMC-077m), living rules
(VMC-077k).

## Acceptance

- One kernel, `valimc_core::physics`, with a NIF module `physics`
  (`native/valimc_nif/src/physics.rs`) and the Elixir facade
  `Valimc.Physics.Kernel`:
  - **Block scan** in vanilla's `Cursor3D` order (x fastest, then y, then z)
    with halo types (one halo coordinate needs a large collision shape, two a
    moving piston, three are skipped). A halo cell is read only when its
    section may hold such a state: each decoded section knows from its palette
    (Moonrise's per-section special-collider counts). Rows are decoded only
    for the sections near the query (`y ± 2`).
  - **Shapes** from the installed fact table (VMC-077d builds the physics
    columns beside the flags and light): fixed shapes, horizontally offset
    shapes, and the context shapes of powder snow and scaffolding; a cached
    full-block shape short-circuits to a box test.
  - **Movement**: `Shapes.collide` per axis in `Direction.axisStepOrder`,
    `Entity.collide` with step-up (vanilla's candidate heights, f32 sorted),
    colliders in `collectColliders` order (entities, the stationary border,
    blocks); `noCollision` and `isEntityCollidingWithAnythingNew`.
  - **Body sweep** and inside-block visits (`forEachBlockIntersectedBetween`),
    powder snow's inside test along the movement.
  - **Fluids**: the contact scan (`updateFluidHeightAndDoFluidPushing`), eye
    tests, `FlowingFluid.getFlow`, player and item currents.
  - **Support**: `findSupportingBlock` (under the feet, else behind a
    horizontal movement), `getOnPos` for friction/bounce and for landing.
  - **Response**: `Entity.move` restitution and the landing block's bounce,
    with the nonfinite guard.
  - **Item tick**: `ItemEntity.tick`'s movement (currents, buoyancy or
    gravity, collision with blocks and the border, bounce, block speed and
    friction) for many items in one call.
- **Players**: one synchronous validation per move packet in the connection
  (`PlayerMotionQuery.run/3`), over a `World.View` of the published rows;
  vanilla's rules ("moved too quickly"; "moved wrongly" accepted unless the old
  box was clear, a new collision always rejected; a move before a pending
  teleport's acknowledgement is dropped). Each geometry step is one NIF call
  that reads the published section terms directly, decoding only the
  sections near its boxes: a whole call over a player's chunks costs about
  1 µs (below), so copy-on-write section resources (audit G3) would save
  nothing worth their upkeep. The resting player's pose and
  kinetics run synchronously on its tick (`PlayerPoseQuery.run/1`).
  Gone: the collision worker pool, the per-move task, admission deadlines,
  signatures, retries, `motion_pending` socket gating, the `:motion` and
  `:pose` job kinds and their handlers, the region read gates. Correction
  classes C1/C2 (deadline and pool-busy corrections) and E5 cannot occur.
- **Items**: the items phase of the region tick steps every ticking item in
  one kernel call (`Physics.ItemStep`) over the region's published rows and
  publishes the steps in the same tick. Region owners read their own published
  rows rather than their section resource: the data is the same durable state,
  a chunk not generated yet fails closed without the owner tracking absent
  chunks, and `RegionData` keeps a small hook. Gone: `ItemSimulation`,
  `ItemPhysicsQuery`, `ItemSimulationWorkers`, `ItemGeometryWorkers`, the
  resting cache and its section fences.
- **Placement** checks obstruction against every nearby living player that is
  not a spectator (E7), with the placement context, through the kernel.
- **Collapsed**: one supporting-block lookup (`Kernel.footing/5`), one collider
  composition, one player context (`CollisionContext.player/2`), one f32
  helper (`Kernel.f32/1`).
- **Deleted modules**: `BlockCollisions`, `BlockShapes`, `BlockOffset`,
  `BlockEntityContext`, `PistonShape`, `PistonSnapshot`, `ShulkerShape`,
  `Shape`, `VoxelOps`, `Collision`, `StepMovement`, `BodySweep`,
  `FluidBoundaries`, `FluidFlow`, `CollisionResponse`, `ItemTravel`,
  `ItemMotion`, `CollisionQuery`; `MovementValidation.new_collision?`,
  `BorderSnapshot`'s Elixir border collider, `OrbMotion`'s unwired tick
  arithmetic, `BlockFacts`' Elixir shape palette, `World.View`'s block-entity
  contexts. Stages `voxel_union`, `fluid_support` and `item_motion` and their
  oracles went with the code they checked; the kernel's behaviour stays
  covered by the collision, movement, step, fluid, sweep, support, border and
  item-travel stages.
- **Moved out of `physics/`**: `Mining`, `MiningTools`, `MiningLoot`,
  `RandomMiningLoot`, `ChestPlacement`, `CookingBlocks`, `CookingFuel`,
  `CookingItems` (now `Valimc.*`) and `FallDamage` (`Valimc.Living`).
- **Parity**: vanilla is the reference. Every kernel entry point is compared
  bit for bit with Mojang 26.3 through the oracle stages (`check_*.exs` call the
  kernel, or its `parity` NIFs over explicit shapes); no second Elixir
  implementation is kept, since an Elixir copy would only be checked against
  the same oracles.

## Measurements

`bench/physics_kernel.exs` (`MIX_ENV=bench`, full Rust profile; it replaces
`bench/player_motion.exs`, `player_pose.exs` and `item_travel.exs`, which
drove the pooled queries) runs the same
workloads on c50a4670 (the Elixir physics this ticket replaces) and on this
ticket. Moves: 2,000 per repetition over four outcomes (open floor, wall
correction, slab step, Shift under a slab), three repetitions; CPU is the VM's
`statistics(runtime)` over the run, so the old worker tasks count. Items: 256
items on a floor or in water, stepped over the region's published rows, 50
samples. Pairs 3 and 4 ran back to back in one heavy slot at load 11 on the
shared 10-core host; pairs 1 and 2 ran apart under other sessions' load
(27–40) and agree on the ratios. Raw results in the ignored `bench/results/`
(`vmc-077l-{before,after}-{1,2,3,4}.json`).

| Pairs 3–4 | Before (Elixir) | After (kernel) |
|---|---|---|
| CPU per move | 156–192 µs | 61.5–66 µs |
| Median move latency, one at a time | 155–164 µs | 60–63 µs |
| Wall per move, 16 in flight | 32–67 µs | 25–36 µs |
| Item tick on a floor (median per item) | 23.8–28.1 µs | 1.25 µs |
| Item tick in water (median per item) | 35.3–35.6 µs | 1.6 µs |

A kernel call's fixed cost (the rows of a player's chunks handed over and
their nearby sections decoded) is about 1 µs (median; p95 1–4 µs). Items
step about 20 times faster. A move costs about 2.6 times less CPU, not the
audit's 10–30 times: of a move (dev profile, one owner, 85 µs there), the
kernel's own calls take about 10 µs and the player's travel rules in Elixir the
rest (`PlayerKinetics.tick` 23 µs, `PlayerKinetics.packet` 10 µs, the query box
9 µs, two pose fits 16 µs). Porting those rules is the follow-up below.

An item tick scans at most 1,024 cells (the old query bound); the worst case
measured, items moving 5.5 blocks a tick through fences, walls and stairs,
costs about 110 µs each, so `Native.dispatch/3` sends a batch whose estimated
scan passes the 1 ms budget (120 ns per cell) to `physics_items_dirty`.

Checks: all 208 vanilla stages (the TCP stage found a placement crash in the
nearby-player check, fixed with a regression test); `mix test.fast` (481
tests); the socket and slow suites of movement, pose, items, landing, air,
fire, lifecycle, periodic effects, mining, placement, portals and spawn. Two
fire tests (`player_fire_connection_test.exs`, seeding fire at y 64 and 65)
fail in setup on c50a4670 as well, before this ticket.

## Deferred

- The player's travel rules still run in Elixir around the kernel's geometry
  (`PlayerKinetics`, fluid and climbing controls, sneak edges, swimming, pose
  fit): a move is about a dozen NIF calls, not one. Porting them makes a move
  one call and is the next step for per-move CPU.
- Experience orbs do not move after launch; their tick (gravity, water,
  following players, merging) belongs in the kernel's batch beside items.
- Block-entity collision shapes (opening shulker boxes, moving pistons) are
  not modelled: shulker boxes collide as closed, moving pistons as empty.
- Mobs use the same kernel when they arrive (M3).
