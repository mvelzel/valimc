# VMC-078c — Complete milestone fixtures and quiesce test worlds

Status: In progress
Milestone: M3
Parent gate: [VMC-078](VMC-078.md).

The first complete milestone runs expose stale fixture assumptions and writers
outliving their temporary datasets. Correct the fixtures without changing
gameplay rules to satisfy them; retain failed runs and diagnose residual
checkpoint errors before calling the milestone clean.

Acceptance:

- Existing chest placement checks exercise joined states, item consumption,
  the six-row view and both durable physical entries.
- A villager's ordinary stroll stays within readable fixture chunks before
  it returns to its claimed bed. A portal-reuse fixture provides a nearby
  valid creation site, so arbitrary Nether terrain cannot place the first
  destination outside the original portal's scaled return search.
- Teardown stops every owner visited by a scenario and its detached writers
  before deleting the dataset. Diagnose checkpoint errors in the full run;
  do not suppress them or infer a production storage repair from log text.
- Affected checks and the full suite pass; retained diagnostics distinguish
  intentional fault injection from cleanup failures.

## Findings and corrections

The old chest socket expectation refused adjacent same-facing placement.
It now checks the implemented joined chest and its state through a fresh
login. Chest-view cleanup also used an obsolete bare registry key; the
existing canonical neighborhood helper now stops its actual owners.

The villager's one-chunk fixture intermittently parks at its unreadable edge:
the captured mind stays at tick 80 while the owner advances over 34,000
ticks. The existing scene now loads a larger floor around its POIs near
the section center, written together before admitting the owner. Its two
tests pass 31 repetitions, 62 checks, without changing AI, random or deadlines.
Evidence: `.local/m3-villager-diagnostic.log` and
`.local/m3-villager-loaded-fixture-tests.log`.

The portal-return failure arrived at (30889, 64, 5292) rather than the original
opening at X30760..30761/Z5160. New-portal creation may move within sixteen
Nether blocks, while the return searches only 128 overworld blocks; arbitrary
terrain can therefore invalidate this test's guaranteed-reuse premise.
The fixture now clears a small supported destination site without placing
a portal. The same actual flint-and-steel/travel/creation/return checks pass.
Creation and search rules remain those covered by the pinned portals stage.
Evidence: `.local/m3-portal-loaded-site-tests.log`.

Cleanup waits for checkpoint paths after its owners stop. The shared player
fixture accepts its visited radius; the handoff flight spans three regions
and now cleans all three rather than only its starting neighborhood.
The twenty-seven affected socket/live-owner tests pass without checkpoint
errors in `.local/m3-final-fixture-integration.log`. The full suite passes
all 778 checks (nine properties, 769 tests) in 110.8 seconds, retained in
`.local/m3-full-suite-fixture-boundaries.log`. Test-only changes select no
additional vanilla stages in `.local/m3-final-fixture-vanilla.log`.

Still open: that full run logs `:corrupt_frame` and later missing log files
under a removed `valimc-dragon-live-*` dataset. Waiting for registered
checkpoint paths alone does not resolve the full-run sequence. Three isolated
seven-test arena repetitions pass without reproducing it; the private
read-location tracer and raw captures live under
`.local/m3-checkpoint-diagnostic*`. Continue from these specific writers;
do not mark this cleanup slice or the M3 gate complete yet.
