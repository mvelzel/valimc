# VMC-034n4c — Experience orb gaps

Status: Done
Milestone: M3
Depends on: [VMC-077i](VMC-077i.md) (orbs move in the Rust kernel),
[VMC-077h](VMC-077h.md) (one entity store).

Orbs already move live. The kernel's `orb.rs` applies currents, gravity, the
pull toward the nearest player, collision and the bounce, and `Entity.Store`
ages and expires orbs. This ticket closes the gaps against vanilla's
`ExperienceOrb`:

- **Merging:** nearby orbs merge (count and value), as vanilla's
  `scanForMerges` does.
- **Lava:** an orb in lava gets vanilla's random jump.
- **Furnace orbs:** they start at rest today (`ExperienceOrbs.award`);
  vanilla gives every new orb a random velocity.
- **Oracle check:** the live kernel matches oracle fixtures across falls,
  walls, slabs, ice, slime, honey, water and lava.

This used to be the supplied-kernel plan of VMC-034n4; VMC-077i replaced that
plan, so this ticket now lists only what remains.

Acceptance: merging, the lava jump and launch velocity match the oracle's
fixtures; furnace orbs scatter as in vanilla on the real client.

## Design

- **Lava jump.** `orb::step` takes four supplied `nextFloat` draws (24-bit
  integers). When the orb's block holds lava, its velocity becomes vanilla's
  `((f1 - f2) * 0.2F, 0.2F, (f3 - f4) * 0.2F)` after water or gravity and
  before the pull. `ItemStep.run_orbs` draws fresh ones per orb per tick;
  the oracle check supplies its own.
- **Kernel fixes the oracle found.** Gravity is `Vec3.add`, which turns a
  negative zero positive. Underwater movement is vanilla's
  `min(y + 5.0E-4F, 0.06F)`, not the item's rule. Underwater means the eye
  cell holds water above the eye (`fluid::eyes`), not water anywhere over
  the body above eye depth.
- **Spawning.** `ExperienceOrbs.orbs/2` serves furnace awards, block and mob
  drops and player deaths. `plan/3` is vanilla's `awardWithDirection`
  choice: each orb value joins the first earlier orb of its value whose id
  is congruent modulo 40 to a uniform pick below 40, else spawns with the
  next id. Every spawned orb gets the constructor's random launch velocity
  (`OrbMotion.launch`). Orbs already lying at the spot are not considered.
  Past 4,096 orbs of one value in one amount, with all 40 classes taken,
  they are shared out evenly and only the remainder is picked.
- **Merging.** `Store.age` merges before it ages, as vanilla scans before
  `age++`. An orb's `lived` counts its ticks in this VM (vanilla's
  `tickCount`, never saved). It scans on tick 1 and every twentieth after,
  catch-up ticks included; due orbs scan in id order. `ExperienceOrbs.merge/2`
  is `scanForMerges`: every other orb of its value, id congruent modulo 40,
  whose box meets its own grown by 0.5 joins it (counts add, the lower age
  stays). Absorbed orbs leave with the expired ones, through the owner's
  durable commit, so a busy write defers the merge to a later tick. Orbs
  merge only within one store.

## Evidence

- `OrbTravelOracle` / `check_orb_travel.exs` (stage `orb_travel`), on
  26.3 jar `33680f5f`:
  - 12,960 actual `ExperienceOrb.tick` + `Entity.move` steps. Floors: stone,
    ice, slime, honey, oak slab. Layouts: open, a wall, still and flowing
    water, lava, a ceiling. Each from three starts and three velocities,
    with and without a followed player, for 24 ticks. All are bit-exact
    through `ItemStep.run_orbs`, 448 of them lava jumps, with frame
    dependency coverage.
  - 600 `scanForMerges` scenes: boundary offsets at exactly 1.0, ids
    congruent or not, mixed values, and chains with every orb scanning.
  - 144 `awardWithDirection` runs with taped picks and three id bases,
    up to 100 orbs of one value.
- `OrbMotionOracle` keeps only its 56 bit-exact launches; its unchecked
  supplied-contact ticks are gone (the live check replaces them).
- `test/experience_orbs_test.exs`: an award scatters and joins by pick;
  store merging on tick 1, then nothing until tick 21.

Not covered: block effects on orbs (honey's slide, cobwebs). Burning in lava
and fire is [VMC-034n4d](VMC-034n4d.md).

## Client gate

Take a furnace's output after smelting a stack: the orbs scatter. Drop orbs
into lava: they hop. Several orbs lying together merge into fewer.

## Client run (October 23, 2026; M3 client run 3, frozen `e13509dd` (origin/main `df9441ec` and the mob-sound fix) release, fresh worlds; `.local/client-tests/M3-run-3/run-02` to `run-06`)

Orbs came from zombies shot with a bow from about 11 blocks into a pit in a
stone platform (seed 20261023), so they were not pulled to the player;
positions from `Valimc.World.entities(nil, [:orb])`. Passed:

- Each zombie's 5 experience came as three orbs (3, 1 and 1), which left
  with a random spread: some travelled 2 to 6 blocks sideways, and in a
  one-block pit they settled at different points.
- Six resting orbs plus four more kills left 14 entities, not 18: orbs of
  one value merged into counts of 2 and 3, and the absorbed ones were gone.
  Side-by-side orbs whose ids differ modulo 40 stayed apart, as vanilla's.
- Lava set under 14 resting orbs lifted them all from y 98.0 to 98.2, and
  they burned up within about 40 ms (seen in the server's entities).

A furnace's orbs come from taking its output at the player, who absorbs
them at once, as in vanilla. Breaking a furnace that holds items or stored
experience waits for [VMC-034f](VMC-034f.md).

Unconfirmed: twice, a zombie the player had shot and that died in lava 1.2
seconds later showed no orbs, even polling every 10 ms. Its player memory
(100 ticks) should give its experience, but orbs born in lava burn within
two ticks in vanilla too, so this may be a polling gap. Worth a fixture
when the lane next touches deaths.
