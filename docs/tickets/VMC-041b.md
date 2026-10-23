# VMC-041b — Pathfinding and navigation

Status: Done
Milestone: M3
Depends on: [VMC-041a](VMC-041a.md).

Vanilla's `PathFinder` with its node evaluators (walk, swim, fly, amphibious)
and path types from block facts (doors, fences, fluids, danger), then
`PathNavigation` following, stuck detection and recomputation.

- Run the search in Rust as a bounded job over published chunk snapshots, so
  it never runs inside the owner.
- The owner rejects a result made from snapshots older than its fence.
- Node types come from one generated source (`ai_facts.json`'s path type of
  every state, VMC-041a1), so 029d's states path correctly.
- Replace VMC-041a1's straight one-node path (`Valimc.AI.Navigation`, and
  `MobAiOracle`'s matching path finder) with the search; the following,
  stuck detection and timeouts there stay.

Acceptance:

- Mobs path around walls, through doors where vanilla lets them, across
  section and group lines and into water.
- Paths match the oracle's fixtures for the four evaluators.
- No owner waits on a search.

## Implementation (October 23, 2026)

**Search** (`valimc_core::path`, NIF `path`): `PathFinder.findPath` with its
binary heap, targets in `HashMap` order and the reached or closest path, and
the evaluators `WalkNodeEvaluator` (start, neighbours, jumps, drops, water
below, partial-collision sweeps, doors, rails, fences, big-mob malus),
`AmphibiousNodeEvaluator` (its malus overrides, water borders, vertical
water neighbours, shallow preference), `SwimNodeEvaluator` (breaching) and
`FlyNodeEvaluator` (its 26 neighbours and a small flier's random start
candidates, drawn from the mob's random). It reads blocks as
`PathNavigationRegion` does: chunks outside the region or not published are
void air, heights outside the world air. Path types per state are the
generated `path_type_states`; `MobAiOracle facts` now also writes
`path_flags` (`isPathfindable` for land, water and air, and the water
block); shapes, fluids and air come from the kernel's installed facts.

**Navigation** (`Valimc.AI.Navigation`, `Valimc.AI.Paths`): requests are
`createPath`'s (region of `max(followRange, 16)` plus 8 or 16, visited-node
limit, reach, the mob's malus, step height, fall limit and door and fence
abilities; a piglin opens doors). Following gained vanilla's corner cutting
(`shouldTargetNextNodeInDirection`, `canCutCorner`), the full cauldron trim
and `recomputePath`; the navigation kinds (ground, water-bound, flying,
amphibious) differ where vanilla's do (`canUpdatePath`, `getTempMobPos`,
`getGroundY`, `canMoveDirectly` with a collider ray, the flier's tick).
`Physics.Clip` gained the `:any` fluid mode for fliers.

**Owner** (`World.MobPaths`): where a search runs is the AI world's
(`World.search/2`): oracles and tests answer at once; a region owner defers.
A mob's request leaves its tick as an effect; the section keeps the newest
per mob and runs at most 32 as one `:paths` job (slot pool), which takes
the published snapshot of every chunk the regions cover through the
Directory, whatever section or group owns it, and searches in Rust (dirty
past about 1 ms of estimated work). Each result carries the snapshots of
the chunks it read (its fence); when the job reports, a result is kept only
while each of those chunks is still published as it read it, else it is
stale. The mob's next tick installs a result before its goals run
(`Navigation.receive/1`); a stale one is dropped and recomputed (at most
once in 20 ticks), and a pending path nothing answers within 40 ticks is
given up. While a path is pending the goals see a path (it reaches, for
`MoveToTargetSink`) and the mob holds still for that tick or two.

Checks: stage `mob_ai` with vanilla's own `GroundPathNavigation` and
`PathFinder` in `MobAiOracle` (its probe level's chunks now read the
scene) and searches at once on ours: 2980 mob ticks of 9 scenes equal bit
for bit, paths included. New stage `paths` (`MobAiOracle paths`,
`scripts/check_paths.exs`): 25 single searches equal vanilla's nodes, node
types, target, reach and the mob's random after: zombies around a wall's
gap and stopped by a closed one, a closed wooden door (a zombie stops, a
piglin opens it), an iron door, an open door, a pig at a fence line, a
closed and an open gate, a water channel and a target in it, steps up, a
drop, a wall on the x 128 section line, negative coordinates; a cod around
a pillar, a dolphin breaching; a parrot over a fence and one starting in
leaves (its start drawn from its random); an axolotl into a pool, to its
edge, out of it, and a shallow-preferring swimmer. `ai_facts` regenerates
equal. `cargo test -p valimc_core` (5 path tests), `cargo clippy` clean for
the new code. `test/mob_path_region_test.exs`: in an owner a piglin sees
gold between a fence line's posts, walks around the line's end by a
deferred path and takes it; the section's path job searches across the
section line through the next section's snapshot, its result is current,
then stale once that chunk is published again; a pending path installs,
recomputes when stale and is given up unanswered. `mob_ai_connection`,
`mob_brain_region`, `mob_travel_region`, `combat_connection`, entity body,
falling block and explosion suites pass. A dev-build sample of the fixtures'
searches: a zombie's search that visits all 560 nodes took 0.86 ms, most
take 0.06 to 0.3 ms.

Not modelled yet: vanilla's `shouldRecomputePath` on a block update near a
path (a path is recomputed when its result is stale, and stuck detection
ends a path a change blocked), a deferred search's random draws (a small
flier's start candidates draw from a copy; at once they draw from the mob's
own), the amphibious evaluator's lasting water malus, `canStandOnFluid`
(striders), riding, the frog's evaluator (VMC-043c), opening the doors a
piglin's paths go through (`InteractWithDoor`, VMC-043d), the zombie's door
breaking, mobs sensing other sections' items
(a piglin in the next section loses the gold it walks to), and following
fixtures for the water-bound, flying and amphibious navigations (their
families, VMC-043b–e).

Reference: 26.3 `PathFinder`, `BinaryHeap`, `Node`, `Target`, `Path`,
`PathType`, `PathTypeCache`, `PathfindingContext`, `NodeEvaluator`,
`WalkNodeEvaluator`, `AmphibiousNodeEvaluator`, `SwimNodeEvaluator`,
`FlyNodeEvaluator`, `PathComputationType`, `PathNavigationRegion`,
`CollisionGetter.noCollision`, `BlockBehaviour.isPathfindable`,
`PathNavigation`, `GroundPathNavigation`, `WaterBoundPathNavigation`,
`FlyingPathNavigation`, `AmphibiousPathNavigation`, `MoveToTargetSink`,
`MeleeAttackGoal`, `Mob.getMaxFallDistance`, `Mob.onAttributeUpdated`,
`AbstractPiglin.applyOpenDoorsAbility`, `Parrot`, `Dolphin`, `Axolotl`,
`AbstractFish` (`createNavigation`), `BlockPos.randomBetweenClosed`.

Client scenario (phase-end handoff): survival, normal difficulty, on a
flat stone area. Build a two-high wall with a one-block gap; stand behind
it and `/summon zombie` on the other side: it walks to the gap, through
it and to you, rather than into the wall. Put an oak door in the gap,
closed: the zombie cannot reach you; open the door: it comes through. Dig a
two-wide water channel between you: it wades or swims across. `/summon
piglin` in the Nether beside a fence line and drop a gold ingot on the
other side where it sees it between the posts: it walks around the line's
end to fetch it.

Next: VMC-043b (zombie family), with VMC-043c–e alongside.

## Client run (October 23, 2026; M3 client run 3, frozen `dff984cb` (origin/main `abc89857` and the stand-up fix) and `e13509dd` (origin/main `df9441ec` and the mob-sound fix) release, fresh worlds; `.local/client-tests/M3-run-3/run-01`, `run-04`)

Passed in survival on normal (positions from `Valimc.World.entities`):

- Superflat: a zombie that saw the player through a two-high wall's gap
  walked into the gap and on to the player; without a sightline it went
  around the wall's end, also a valid path.
- A closed oak door in the gap stopped it at the door's face; an open door
  let a fresh zombie through.
- A zombie waded through a two-wide, one-deep water channel to the player.
- Nether (seed 20261023): a piglin walked around the end of six unconnected
  oak fence posts to a gold ingot it saw between them and took it. Two
  earlier tries went to a gold nugget lying nearby first, as a piglin wants
  any gold item.

Seen in passing: a summoned husk never moved (the zombie family, VMC-043b).
