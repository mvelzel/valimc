# VMC-015g — Slowing block contacts

Status: Done
Note: Default live contacts validated/published; weaving lifecycle and damage remain follow-ups. October 15, 2026.

Acceptance: native player cobweb/weaving, berry bush and powder-snow contact
selection; reset fall on contact and retain the last ordered multiplier until its
next move consumes it. Scale requested displacement before collision, zero stored
velocity, and preserve native tiny-multiplier behavior. Keep packet movement,
logical ticks, swept contacts, teleport/reconnect and flight/spectator semantics
explicit and owner-fenced; no global owner or new timer.

Reference: pinned 26.3 `WebBlock/SweetBerryBushBlock/PowderSnowBlock.entityInside`,
`Entity.makeStuckInBlock/move/applyEffectsFromBlocks/checkInsideBlocks`. Contact
geometry/order and gameplay effects are separate from supplied vector arithmetic.

Client gate: enter/exit/drop through cobwebs and bushes, powder contact versus
feet outside, flight/spectator exclusion, fall reset and reconnect; brief dry,
fluid and climbing regressions. Retain collision/frame bounds and held input.
Damage, web generation and other block effects remain required follow-up work.

Kernel checkpoint: native player callbacks match 56 material/state/weaving/feet/
flight contexts, including all berry ages. Actual `Entity.move` prefixes match 96
supplied multiplier/vector cases (SELF/PLAYER), before edge/collision. The tiny
multiplier threshold preserves the original vector; active multipliers clear
velocity and consume once. Complete class lookup matches all 35,723 states;
the scalar catalog stores only the six relevant IDs. Two boundary tests pass.
Evidence: `.local/stuck-motion-{native,check,tests}.log`, original
`scripts/StuckMotionOracle.java`; no live wiring or graphical pass yet.

Next: bounded ordered/swept contact selection, pending-multiplier ownership,
collision/frame composition and a frozen client gate. Powder's 1.5 vertical
factor must be included in query admission. Do not replace last-contact ordering
with component-wise minima or clear unrelated movement on a mere observation.

Original `BodySweepOracle` records 1,809 actual ordered
`BlockGetter.forEachBlockIntersectedBetween` traces: standing/crouching/swimming,
tiny-motion threshold, axis ties, negative/remote positions, random directions,
long moves and visitor early stop. Original `Physics.BodySweep` matches every
trace/order/step and admitted frame coverage. Work is bounded by 512 visits,
4,096 candidate attempts, 256 grid steps, 64-block displacement per axis and
bounded body geometry; truncated results are explicit. Five affected tests pass.
Mixed subnormal/ordinary movement is rejected before reciprocal overflow on BEAM.
Evidence: `.local/body-sweep-{native,check,tests}.log`, ignored cases JSON.
This primitive is not yet a live contact detector or graphical result.

Compiled foundation baseline PASS on frozen `59de8fc`, October 15, 20:03–20:05:
direct actual join/render/daylight, dry walk/jump/crouch and brief ladder regression.
Report reviewed: `.local/client-tests/VMC-015fg-kernels/report.md`. Slowing helpers
remain unwired; the feature gate stays open. Owned client stopped, fixtures restored,
safe dry pose, unchanged inventory/journal, zero players and paused noon retained.

Temporal boundary: native listener `tickPlayer` runs `doTick` then restores the
accepted anchor. `LivingEntity.aiStep` applies block effects from recorded movement
segments; `handleMovePlayer` does not directly apply these callbacks. Live design
needs bounded transient accepted-path history plus the scratch step, current source
fences, native axis-dependent segment order and teleport retirement. One last
`known_movement` vector cannot preserve a whole tick's crossed-block effects.

Context checkpoint: `StuckContact` matches 1,680 actual native single-path scenes,
including last ordered contact, powder shape/feet selection, prior fall reset,
pose, flight/spectator and weaving. `Box` swept contact matches 788 native cases
and 12 strict segment entries; traversal still matches all 1,809 traces. Twenty-one
affected tests pass, including crossed-web endpoints and web-reset→powder geometry.
Evidence: `.local/{stuck-contact,swept-contact}-{native,check}.log`,
`.local/stuck-contact-tests.log`. Native scenes supply immutable blocks/healthy bare
players; queued damage/freezing and owner lifecycle are excluded.
Native `checkInsideBlocks(List, collector)` retains one hit-position set until the
whole batch finishes. Each movement has a 16-step budget shared by its axis
segments, with destination fallback when exhausted; this is not a 16-movement
queue cap.

Batch checkpoint: 3,456 actual native multi-path scenes match shared hit-position
deduplication, requested-vector axis order and the step-budget destination fallback.
The earlier 1,680 single-path scenes still pass; 22 affected tests pass. A regression
covers web → bush → the same web: the bush wins until the next tick. Each sample
accepts at most 101 paths and 4,096 visits; incomplete geometry fails explicitly.
Evidence: `.local/stuck-path-{native,check,tests}.log`, original
`scripts/StuckPathsOracle.java`. Native movement history retains 100 records by
coalescing its oldest two into a linear path; a final-position gap may add one.
Next: player-owned transient history, multiplier consumption and live composition;
the feature and graphical gates remain open.

Live checkpoint: player-owned `MovementPaths` uses an Erlang queue capped at 100,
matching 45 actual native coalescing/final-gap cases. Packets record admitted
physical travel; effects are selected after logical travel. A pending multiplier
scales the next move before collision and clears velocity once. Tick commit clears
history; observations do not. Worker signatures include both fields. Rejected
packets preserve committed history; explicit teleport/reconnect retire transient
state. Existing frame/source/worker/deadline bounds remain; admission encloses
retained paths and powder's vertical expansion. No new owner or timer.

Seventy-four affected tests pass: crossed endpoints, contact ordering/reset,
material changes, packet validation, powder expansion, flight/spectator, stale
results and transient snapshot exclusion. Native `Entity.move`'s tiny blocked-move
guard also controls physical positions; `Player.travel` flight damping retains
pre-travel Y, independently of consumed velocity. The 3,456 batch and 1,680
single-path contact checks still pass. Evidence:
`.local/stuck-live-{tests,query-tests,native-check}.log`,
`.local/movement-path-{native,check,tests}.log`. Weaving has a native-verified kernel;
live status-effect ownership and damage remain future work. Next: frozen actual
client scenarios, full block integration/build and comparable loads.

Client PASS on frozen `4ad8d0f`, October 15, 20:47–20:55 CEST. Report reviewed:
`.local/client-tests/VMC-015g/report.md`. Actual web/bush entry/exit (all bush ages),
complete four-high slowed web fall/landing, fall resets, powder feet versus body
contact, flight escape and fresh reconnect pass. Dry walk/jump/crouch, water,
ladder and dedicated SDL pointer use pass. All 162 fixture cells restored, both
owned clients stopped, zero players, safe dry state and paused noon retained.
Weaving/damage remain excluded from graphical coverage. Full suite: 622 tests;
separate production build succeeds. Initial full native run exposed missing game
mode in three probe fixtures; targeted repair passes 3,360 swim, 2,736 fluid and
1,920 climb/frame cases. Full native rerun uses immutable `bc4eb1e` (same live
implementation; fixture repair only), `.local/stuck-block-checkpoint.json`.

Published through `bc4eb1e`. Full native integration passes, including plaintext
and encrypted TCP (`.local/stuck-block-frozen-native.log`); 622 tests and production
build logs are `.local/stuck-block-{full-tests,production}.log`.
Controlled static-water loads pass on that frozen source: 512 spread players /
51,200 moves in 5.113s and 128 dense / 12,800 in 5.525s, zero corrections/disconnects,
all positions/swimming states verified. Previous `59de8fc` control: 512 / 51,200 /
5.153s, likewise clean. Raw results: `bench/results/slowing-*.json`; manifests,
hashes and exact source mapping: `.local/slowing-block-load-provenance.json`.
Native integration and GUI clients were closed before these runs. Scripted static
pools do not establish survival capacity or fastest-server status. Default contact
work needs no repeated gate; future status-effect ownership must supply weaving,
and health/damage remain VMC-017/VMC-037 work.
