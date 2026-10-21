# VMC-026a — Nether and End generation beyond terrain

Status: Foundation
Milestone: M2 real worlds
Depends on: [VMC-024](VMC-024.md) (Nether and End terrain), [VMC-025](VMC-025.md)
(the decoration pipeline, VMC-025a–c).

VMC-024 gives the Nether's and the End's terrain and VMC-025 decorates the
overworld. This slice decorates Nether and End chunks as vanilla's
`applyBiomeDecoration` does in those dimensions, without structures: the
Nether biome preset's 37 placed features and the End's 5, at the dimensions'
own heights. Live Nether and End worlds are VMC-026b (see the
[parent](VMC-026.md) for what they need).

Acceptance:

- For three seeds, areas near and far from the origin and one area per Nether
  biome and per kind of End area (the main island's ten spikes, the arrival
  platform, the outer islands' biomes, a gateway, an extra small island),
  decorated chunks equal vanilla's block for block, with post-processing
  marks, scheduled ticks, block entities (an end gateway's exit) and the
  entities features add (the spikes' crystals), when both decorate the same
  chunks in the same order. The oracle's loop equals vanilla's own
  `applyBiomeDecoration` on each dimension's first area.
- Fire, soul fire, chorus plant and chorus flower shape updates (which
  shapes.json leaves out) equal vanilla's on random neighbourhoods, so
  decoration no longer refuses them.
- Decoration per chunk is benchmarked against vanilla and Pumpkin on matched
  areas in both dimensions.

## Facts

- `dimensions.json` (`WorldgenFactsOracle`, stage `worldgen_facts`): the
  normal world preset's three dimensions, each with its dimension type's build
  bounds (bottom, height, logical height), noise settings and biome source.
  `Valimc.Worldgen` passes it to the native registry.
- `blocks.json` (`WorldgenBlocksOracle`) gains the states fire can burn
  (`FireBlock.canBurn`: ignite odds above zero, none while waterlogged), 3,031
  states as runs of ids.
- `shapes.json` also covers the iron bars the End spikes place (it analyzes
  the blocks ValiMC's worldgen code names): 2,055 states, 1,938 with rules
  (3,464 rules, 925 outcomes).
- Feature facts were already complete (VMC-025a): `feature_order.json` has
  the Nether preset's and the End's order, `features.json` and
  `placed_features.json` every entry they name.

## valimc_core::worldgen

- Dimensions: proto chunks, areas and the decoration region take their
  dimension's bounds instead of the overworld's constants. The registry
  builds one decoration per biome source of the preset's dimensions
  (`Registry.decorations`, keyed by biome source; survival, shape and template
  facts shared), each with vanilla's `WorldGenerationContext`: the dimension's
  bounds within the generator's (the Nether and the End decorate through 0 to
  128, the generator's depth) and the generator's sea level (32 and 0).
  Terrain fills the generator's 128 blocks of the 256-block chunk; chunk
  biomes cover the dimension's sections, as chunk generation fills them
  (Nether and End biomes do not vary with height, so terrain is unchanged);
  decoration starts at the level's bottom.
- `nether`: deltas (`withinBoxByManhattanDistance` in vanilla's order, rims
  and their offsets), stepped basalt column clusters (columns drawn as
  `randomBetweenClosed` hands them out, surfaces and air above them), single
  block pillars with their cap feature, projected random patchy squares, the
  netherrack replace blobs, random neighbour spreads (glowstone, the crimson
  forest's nether wart), huge fungi (stems, hats with decor blocks, weeping
  vines under nether wart hats; the generator's depth) and scattered ores
  (`Math.round` of the float offsets).
- `end`: end islands, the obsidian spikes (`getSpikesForLevel`: the shuffle
  from the world seed's thread-local random; their obsidian, the guarded
  spikes' iron bar cages, the crystal with its yaw draw, bedrock and fire),
  end gateways (the block entity's exit and exact teleport), the arrival
  platform and chorus plants (`ChorusFlowerBlock.generatePlant` with
  `getStateWithConnections`).
- `placement`: `count_on_every_layer`, its count sampled again for every
  column of every layer.
- `region`: entities features add (`addFreshEntity`: type, position, yaw) and
  an end gateway's exit in its block entity data.
- `fire` and `end`: the shape updates shapes.json left out, in code:
  `BaseFireBlock.getState` (soul fire on its base, fire burning toward
  flammable sides when what is below neither burns nor holds it), fire's and
  soul fire's survival and `updateShape`, the chorus plant's (survival over ten
  cells, connections) and the chorus flower's (a tick when it cannot survive).
  `Decoration::update_shape` dispatches to them before the facts.
- NIFs: `worldgen_decorate` reports added entities and gateway exits;
  `worldgen_shape_cases` evaluates shape update cases.

## Oracles and stages

- `DecorationOracle OUT TYPES [nether|end] [bench]`: the dimension's noise
  settings, biome source, dimension type, sea level and bounds; the noise fills
  the generator's bounds within the chunk's (`clampToHeightAccessor`); chunk
  biomes over the chunk's sections. Its level records `addFreshEntity` (the
  crystals) and its server answers the enabled features the crystals ask
  for. Areas: the overworld's as before; the Nether's per seed two near the
  origin, two within 32,000 blocks, one far out, and on the first seed one per
  biome (nether wastes, soul sand valley, crimson and warped forests, basalt
  deltas, their biome at y 64 in the centre chunk); the End's main island
  (its spikes over four areas and the platform's chunk on the first seed, one
  spike area on the others), three random areas per seed, and on the first
  seed the highlands, midlands and barrens, a small islands area where the
  extra island's rarity filter passes and a highlands area where the
  gateway's does.
- Stages `worldgen_decoration_nether` and `worldgen_decoration_end`
  (`check_decoration.exs` reads the dimension from the oracle's output):
  - Nether: all 37 placed features; 20 areas, 32,768,000 blocks, 894
    post-processing marks and 1,388 scheduled ticks equal vanilla's. The areas
    hold 322,101 basalt, 88,981 blackstone, 40,179 magma, 329 glowstone, 4,658
    crimson and 1,190 warped stems, 988 shroomlights, 2,549 weeping and 186
    twisting vine blocks, 3,511 roots and sprouts, 454 fungi, 233 fire, 28
    soul fire and 255 ancient debris; the Nether's mushrooms did not place.
  - End: all 5 placed features; 21 areas, 34,406,400 blocks, the gateway's
    block entity with its exit (100, 50, 0, exact) and 16 crystals (all ten
    spikes on the first seed, including vanilla's spike at (-42, -1) from the
    sine of -π) equal vanilla's, with 58,968 obsidian, 219 iron bars, 1,517
    chorus plant and 183 chorus flower blocks.
- `ShapeOracle code` and `check_shape_code.exs` (stage `worldgen_shapes`):
  3,000 cases each for fire, soul fire, chorus plants and flowers, a random
  state and direction among random neighbours (flammable and waterlogged
  blocks, sturdy tops, soul fire bases, chorus plants and their supports,
  fluids, fire), all 12,000 equal vanilla's (6,076 change the state, 4,642
  schedule ticks).

## Benchmark

`bench/worldgen_decoration.exs` with `DecorationOracle … nether|end bench`,
and a local Pumpkin harness as for VMC-025 (kept out of the tree; Pumpkin
b0c48b2, release profile, Rust 1.95 with `--ignore-rust-version`,
`RAYON_NUM_THREADS=1`): seed 20261020, one thread, 64 chunks decorated Z
outer, X inner in a 10 × 10 terrain area (the Nether's from chunk (0, 0), the
End's outer islands from chunk (100, 0)), terrain excluded; raw results in
ignored `bench/results/`. Five rounds back to back, ValiMC, vanilla, then
Pumpkin each. The last two ran on a quiet machine (load average 6 to 8);
median per chunk:

| Area | ValiMC | Vanilla | Pumpkin |
|---|---|---|---|
| Nether | 0.148, 0.165 ms | 0.395, 0.447 ms | 0.167, 0.166 ms |
| End | 0.005, 0.005 ms | 0.079, 0.038 ms | 0.020, 0.019 ms |

The first three ran while other sessions loaded the 10-core machine (load
average 24 to 51), so their medians varied up to eightfold (Nether ValiMC
0.22 to 0.56 ms, vanilla 0.56 to 4.3, Pumpkin 0.29 to 1.3); their order was
the same. ValiMC is level with Pumpkin in the Nether and below it in the
End's outer islands (chorus plants and extra islands; gateways are rare);
Pumpkin's stage also places structure pieces and its features are not
checked against vanilla here, so the comparison is a ballpark. A sample
profile of ValiMC's Nether decoration put about 40 % in ores (nine ore
features, as in the overworld), 15 % in block predicate filters reading
blocks and 10 % in `count_on_every_layer`; the new features themselves are
small. Before the third round, the ore placer stopped looking up the air
state by name on every call and the placer reserves its position lists (both
unchanged in output).

## Limits

- Not implemented, and an error if decoration reaches one:
  `void_start_platform` (the void biome of flat and single biome presets,
  VMC-028), planted huge fungi (bone meal) and the spike feature's dragon
  fight options (invulnerable crystals, beam targets; VMC-026b). Gateways
  without an exit (the dragon fight's) place as vanilla's do, their block
  entity left pending.
- Twisting and weeping vine plants draw from the level's random in
  `updateShape`; structures next to them (VMC-025e/f) need that in code.
- No structures (Nether fortresses, bastions, ruined portals, nether fossils,
  end cities: VMC-025e/f).

Reference: pinned 26.3 jar, Vineflower 1.12.0 decompilation (ignored
`research/disassembly/vmc023/src`, `src7`, `src11`, `src13`): `DeltaFeature`,
`SteppedColumnClusterFeature`, `SingleBlockPillarFeature`,
`ProjectedRandomPatchySquare`, `ReplaceBlobsFeature`,
`RandomNeighborSpreadFeature`, `HugeFungusFeature`, `ScatteredOreFeature`,
`AbstractOreFeature`, `SimpleBlockFeature`, `EndIslandFeature`,
`EndSpikeFeature`, `EndGatewayFeature`, `EndPlatformFeature`,
`ChorusPlantFeature`, `VoidStartPlatformFeature`, `CountOnEveryLayerPlacement`,
`PlacementContext`, `WorldGenerationContext`, `VerticalAnchor`,
`HeightRangePredicate`, `BlockPos` (`manhattanOrdered`, `randomBetweenClosed`,
`betweenClosed`), `Vec3i`, `ChorusFlowerBlock`, `ChorusPlantBlock`,
`FireBlock`, `BaseFireBlock`, `SoulFireBlock`, `Util.toShuffledList`,
`RandomSource`, `WorldGenRegion.addFreshEntity`, `ProtoChunk.addEntity`,
`WorldPreset`, `WorldDimensions`; `javap` of `LevelStem`, `DimensionType`,
`MinecraftServer`.

Checks (October 21, 2026): every worldgen stage of `check_vanilla.py --only
worldgen` passes; after rebasing on VMC-025d and VMC-025e, `worldgen_facts`,
`worldgen_shapes`, all three decoration stages (the overworld's 50 areas
unchanged), `worldgen_live` and `worldgen_structures` pass again (the
decoration and live stages once more on the final tree), with the worldgen,
proto and decorated world tests (26). `cargo test` (63), `cargo
clippy --all-targets`, `cargo fmt --check`, `scripts/audit_public_tree.py`.
`mix test.fast` passed 1,145 of 1,148 under a load average of 20 to 50 from
other sessions; the 3 failures (item handoff, imported sign, item merge
timing; earlier runs under heavier load failed 17 such deadline tests) pass
on rerun.

Next: VMC-026b (live Nether and End worlds).
