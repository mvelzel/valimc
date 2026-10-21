# VMC-077d — One block fact table

Status: Done
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
- Scaffolding, shulker box, piston and bubble column states, and the air
  states, come from the registry and the flags; no state id is hard-coded. The
  case oracles iterate vanilla's states themselves.
- One NIF, `block_facts_init`, installs the columns the Rust core reads (flags,
  heightmaps, fluid id and level, light and sky) once per VM
  (`BlockFacts.install!/0`); the storage flags, the light facts and worldgen's
  block table are built from it. It replaces `flags_init`, `light_facts_init`
  and the per-state arrays worldgen took as JSON (the two flag words, flammable,
  fluid, fluid level, heightmaps); worldgen's registry now passes only tags and
  block entity types. Terrain's own byte per state (air and fluid from the
  table, plus water, the `uncarvable` tag, grass and dirt) stays a derived
  table of the worldgen registry, since its tags come from the pack.
- Damage types are names with registry ids and tags (`Registry.DamageTypes`,
  from the generated registries and tags); the rules ask tags: armor applies
  unless `bypasses_armor`, Resistance and enchantments follow vanilla's
  `bypasses_effects`, `bypasses_resistance` and `bypasses_enchantments`,
  invulnerability yields to `bypasses_invulnerability`, fire-resistant gear
  resists `is_fire`. Enchantment protection and immunity come from the pinned
  data pack's enchantment definitions (`EnchantmentMetadata`,
  `priv/registry/enchantments.json`, the `enchantments` stage): each effect's
  level-based value, its damage-source tag requirements and the enchantment's
  slot groups, over every equipped slot as `EnchantmentHelper` visits them.
  Forms the pinned definitions do not use fail the build.
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

Then the damage slice removed the source lists of `PlayerDamageProtection`,
`ArmorDurability`, `PlayerEnchantmentImmunity` and `Packets.damage_event`, and
`PlayerResistance`'s own tag decoding (lib +80 net: the two registry modules
replace them); the Rust install removed `flags_init`, `light_facts_init`,
`World.Blocks.init!/flags`, the whole `World.Light` module, worldgen's six
per-state JSON arrays and their hex and run parsers (lib −55, native +117 with
the new `facts` modules and their test).

Reference: Minecraft 26.3 (`Block.isExceptionForConnection`,
`BlockBehaviour.BlockStateBase` cache, `LightEngine.getOcclusionShape`,
`ChunkSkyLightSources.isEdgeOccluded`, `Heightmap.Types`, `FireBlock.canBurn`,
`LivingEntity.getDamageAfterArmorAbsorb` and `getDamageAfterMagicAbsorb`,
`EnchantmentHelper.getDamageProtection` and `isImmuneToDamage`, the data pack's
`enchantment/*.json` and `tags/damage_type/*.json`).

Checks: the comparison script (every column equal, the 102 shulker box states
apart); `block_facts` and `enchantments` with `--regen`; `cargo test -p
valimc_core`, `cargo clippy --all-targets` (with and without `parity`), `cargo
fmt --check`; on the final base (after VMC-077a's and VMC-077b's runtime and NIF
changes) `mix test.fast` 502 passed and `check_vanilla.py --changed` passed all
133 selected stages, live generation, spawn, world settings and tcp among them.

Next: move the other ~70 modules that decode `priv` JSON onto `Valimc.Facts`
with one decoding module per file (tags, attributes, cooking and items are each
decoded more than once); one survival rule set for decoration and live updates
(VMC-077m); terrain's derived per-state byte could read the installed flags
once the worldgen registry has the pack's tags in Rust.
