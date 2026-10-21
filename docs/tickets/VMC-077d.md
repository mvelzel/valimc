# VMC-077d — One block fact table

Status: In progress
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) (the audit and plan), [VMC-068](VMC-068.md)
(the block registry).

Before: about fifteen per-state fact tables in `priv/physics` and
`priv/worldgen/blocks.json`, each with its own Java generator, encoding (nibbles,
bytes, id lists, triples, runs) and compile-time decoder with a copied
version-stamp check. `collision_shapes.json` was decoded three times and
`blocks.json` four times; air, bubble-column and other state ids were
hard-coded; sturdy faces, air, fences and the legacy support height existed
twice; Rust got per-state facts through three installs (storage flags, light,
the worldgen block table), each assembled differently. Damage sources were
hand-written atom lists in four modules.

Scope: one generated per-state table, one Elixir decoder, one Rust install;
damage types and enchantment effects from the generated registries, tags and
data pack definitions. Not here: physics algorithms (VMC-077l), light algorithms
(VMC-077c), `World.View` (VMC-077e), and merging the two survival engines
(VMC-077m, below).

Acceptance:

- `BlockFactsOracle` writes `priv/registry/block_facts.json` from vanilla's own
  methods with the jar's block tags bound; the `block_facts` stage compares it.
  Columns hold one value per state (one or two bytes, often an index into a
  palette): flags (51 named bits: decoration's 49, flammable, large collision),
  collision shape or its context, motion, fluid (with the state base removal
  leaves), fluid boundary, climb, inside behaviour (fire, soul fire, powder
  snow, cobweb, berry bush, with the inside shape), hazard, landing, mining,
  placement replaceability, heightmap predicates, sky-source edge classes and
  light (emission and dampening, six face occlusion classes with their pair
  tables). The oracle checks every class table state by state, the sturdy flags
  against an empty level at other positions, and the legacy support height
  against `getOnPosLegacy`.
- Every column equals the files it replaces state for state (checked once with a
  comparison script against the deleted files), except one correction: shulker
  boxes are `isExceptionForConnection` (vanilla tests the `shulker_boxes` tag;
  the old generator never bound tags), which only changes worldgen wall, pane and
  fence connections next to shulker boxes.
- `Valimc.Facts` (`use Valimc.Facts, "dir/file.json"`) loads a `priv` file once
  at compile time and checks its release stamps; `Valimc.Registry.BlockFacts`
  decodes the table and is the only reader. State ids are trusted: the table
  raises on an id outside it instead of returning `:unknown_block_state`.
- Scaffolding, shulker box and piston states, and the air states, come from the
  registry and the flags; the case oracles iterate vanilla's states themselves.
- Survival stays in its two files. The partitions are not the same: decoration
  reads survival before placement with the block's own cell as a neighbour under
  unlit-chunk light (`worldgen/survival.json`, 142 partitions), live updates read
  it after placement with `updateShape` reactions and overrides
  (`physics/support.json`, 201 partitions, 131 shared). One engine (VMC-077m)
  can derive both from one rule set; sharing the partitions before then would
  only move bytes.

Removed: the modules `Physics.{ClimbBlocks, FluidBlocks, HeightmapBlocks,
InsideBlocks, LandingBlocks, MotionBlocks, SkyBlocks, StuckBlocks}`; the decoding
in `BlockShapes`, `BlockScan`, `PistonShape`, `FluidBoundaries`, `BlockHazards`,
`Mining`, `Placement`, `World.Light`, `World.Blocks`, `World.Chunk`,
`SpawnSearch`, `Portal.Blocks` and `Portal.Gateway`; the files
`physics/{block_hazards, climb_blocks, collision_shapes, fluid_blocks,
fluid_boundaries, heightmap_blocks, inside_blocks, landing_blocks, light_blocks,
mining_blocks, motion_blocks, sky_blocks, stuck_blocks}.json`,
`worldgen/blocks.json` and placement's replaceability (14 files, 2.1 MB, for one
of 1.7 MB); the generators `BlockMotionMetadata`, `ClimbMetadata`,
`CollisionMetadata`, `FluidBoundaryMetadata`, `FluidMetadata`,
`InsideBlockMetadata`, `LightFactsOracle` and `WorldgenBlocksOracle`, the fact
outputs of `LandingOracle`, `StuckMotionOracle`, `BlockHazardOracle`,
`HeightmapOracle`, `SkyColumnOracle`, `MiningOracle` and `PlacementOracle`, and
the dense-dump checks `check_{climb,fluid,motion}_blocks.exs` and
`check_fluid_boundaries.exs`; `MotionBlocks.fluid_empty`. Stages `light_facts`,
`block_motion_metadata`, `fluid_metadata`, `fluid_boundary_metadata` and
`climb_metadata` merged into `block_facts`; `collision_metadata` is
`collision_shapes` and `inside_block_metadata` is `fire_geometry` (old names stay
as aliases). Net: lib −214 lines, Java −275, check scripts −126, tests −10.

Reference: Minecraft 26.3 (`Block.isExceptionForConnection`,
`BlockBehaviour.BlockStateBase` cache, `LightEngine.getOcclusionShape`,
`ChunkSkyLightSources.isEdgeOccluded`, `Heightmap.Types`, `FireBlock.canBurn`).

Checks: the comparison script (every column equal, the 102 shulker box states
apart); `block_facts --regen` passed; `mix test.fast` (the two failures were
item tests main had already fixed); `check_vanilla.py --changed`: 116 of 127
passed, every stage reading the facts among them; the 11 failures are check
scripts calling `Spawn.path/1`, `Generator.spec/1` or an unset `World.Spec` after
VMC-077a, reported to that session.

Next: data-driven damage types and enchantment effects; one Rust install of the
table's columns replacing `flags_init`, `light_facts_init` and the worldgen
block flags.
