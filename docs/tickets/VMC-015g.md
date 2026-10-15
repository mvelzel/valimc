# VMC-015g — Slowing block contacts

Status: In progress. October 15, 2026.

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
players; queued damage/freezing and owner lifecycle are excluded. Next: a shared
visited set across tick paths, axis-dependent ordering and owner integration.
Native `checkInsideBlocks(List, collector)` retains one hit-position set until the
whole batch finishes. Each movement has a 16-step budget shared by its axis
segments, with destination fallback when exhausted; this is not a 16-movement
queue cap. The current contact oracle uses linear single-movement records.
