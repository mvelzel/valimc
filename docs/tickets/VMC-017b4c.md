# VMC-017b4c — Rain exposure and column observations

Status: Native column/sky/climate foundations and fenced owner reads implemented
locally; live rain extinction and graphical/production gates remain open.

Acceptance: native rain extinguishes outdoor burning, roofs shield players and
removing the roof restores exposure. Use fenced column observations in the existing
bounded player geometry worker, with atomic owner updates/recovery. Do not scan384
blocks for every player tick. Native precipitation/biome and sky rules remain
explicit; the current flat-plains preview cannot establish full biome parity.

Client: ignite outdoors in rain, dry under a roof, remove/add shelter, clear-weather
negative and fresh reconnect. Preserve all existing natural-fire/lava behavior.

Reference: pinned26.3 `Entity.isInRain/applyEffectsFromBlocks`,
`Level.precipitationAt/isRainingAt`, `Heightmap.update/Types` and native block tags.
Initial column index uses a bounded384-bit occupancy integer with six native
predicate families. Tag binding is required: bootstrap alone leaves material/tag
predicates empty. Native traces include every stock state classification, top
removals, fluids/fire/leaves and random column changes. Generation, sky propagation,
biome precipitation and live ownership are not covered by that foundation.

October16: `ColumnHeight` uses bounded384-bit immutable occupancy; top removal
reveals the next occupied bit without a vertical block query. `HeightmapBlocks`
compresses all35,723 states into five masks/17,862 index bytes for all six native
predicate types. The original `HeightmapOracle` loads resolved tags from the jar,
asserts native stone/base heights, then executes3,360 real updates/20,160 height
observations including removals, fluids, leaves, fire and randomized states.
All match; three initial boundary/type tests pass(seed665309). Evidence:
`.local/heightmap-{native,native-check,targeted}.log`; raw traces remain ignored.
The native two-point rain predicate also matches6,048 Entity/Level cases across
six biomes, weather/sky/height boundaries, poses and altitude; biome precipitation
is an observed input, not an implemented climate/noise model. Evidence:
`.local/rain-contact-{native,native-check}.log`.

Sky sources: original `SkyColumnOracle` classifies35,723 states into74 vertical
edge classes, verifies5,287,004 directed native comparisons and6,312 incremental
source heights. Compact pair facts feed `SkyBlocks`; `ColumnIndex` updates two
height predicates and both neighboring sky edges per edit. Complete sparse rebuilds
match every native trace. Empty sky columns clamp to build minimum; native sources
extend below the world, but rain already requires motion height>=-64. This does not
implement lateral light propagation or client light packets. Evidence:
`.local/sky-column-{native,native-check}.log`.

`FlatClimate` supplies the current generator's plains/sea-level63 precipitation,
including fixed temperature noise and rain/snow altitude boundaries.9,342 native
temperatures and precipitation kinds match exactly, including distant coordinates.
The native probe clears its position cache between observations; cache-key aliases
are not gameplay requirements. Only numeric permutation/gradient facts are public;
no biome generation or other climate modifiers are implemented. Evidence:
`.local/flat-climate-{native,native-check}.log`.

The region owner restores the index from edits and updates it with direct,
batch and durable block proposals. Bounded column reads retain its incarnation and
block revision; stale/malformed/foreign reads fail.45 affected checks pass(seed531236),
including flush/replacement and existing mining/placement/store boundaries;
`.local/rain-columns-owner-targeted.log`. No live rain contact or chunk-header change
yet. Graphical and production gates remain open. The final47-test affected foundation
run passes(seed277433), `.local/rain-foundations-owner-final.log`.
`PlayerRainQuery` reads one indexed column at its prepared block revision in the
existing geometry worker. It combines native sky-source/motion heights and
flat-climate feet/head facts; dry weather skips the read.16 targeted checks pass
(seed702021), including stale roofs, roof removal/glass and altitude negatives;
`.local/rain-query-targeted.log`. Live player composition remains separate.

Next: compose the verified rain observation on the admitted player tick, correct
chunk heightmap predicates, then exercise the graphical gate. Keep pending work local.
