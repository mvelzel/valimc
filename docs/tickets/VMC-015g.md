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
