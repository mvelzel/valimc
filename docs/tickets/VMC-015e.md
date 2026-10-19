# VMC-015e — Player climbing

Status: Done
Note: Done within climbing scope. October 15, 2026. Validated `f83e8e7`.

Acceptance: complete climbable/scaffolding/trapdoor/ladder facts and fenced feet/
below observations select native climbing, including matching open trapdoors over
ladders. Flight/spectator exclude it; gliding respects the native glide-through
tag. Clamp dry pre-collision velocity, suppress ladder sliding on Shift while
preserving scaffolding descent, apply native climb boost after collision/input,
and reset fall accounting at the correct owner commit. Water climbing must compose
with the existing fluid branch. Keep the bounded player geometry lane and retire
stale jobs; no new gameplay process or timer.

Reference: pinned 26.3 `LivingEntity.onClimbable/trapdoorUsableAsLadder`,
`handleOnClimbable/handleRelativeFrictionAndCalculateMovement`, `Player.onClimbable`
and `Entity.resetFallDistance`. Separate original scalar facts from context; native
probes supply collision results, not a replacement graphical/world oracle.

Client gate: actual ladder/vine ascent/descent, Shift hold, scaffolding descent,
matching versus wrong-facing/closed trapdoor, water contact, flight and reconnect;
record vectors/fall, accepted positions and corrections. Native/targeted checks
precede a dedicated frozen GUI run. Swimming validation is complete in VMC-015d2/d3.

Kernel checkpoint: 1,920 actual native dry-player climb pipeline cases match
clamps, Shift/scaffolding descent, supplied collision responses, climb boost and
fall reset. Two focused boundary tests pass. Evidence:
`.local/climb-motion-{native,check,tests}.log`. The probe supplies climb contact
and collisions with zero relative input and stops before air drag; it does not
prove material selection, live movement, powder-snow boost or GUI behavior.
Complete/contextual block facts and live composition are next.

Material/contact checkpoint: all 35,723 states match pinned climbable/glide-through,
scaffolding and ladder/trapdoor facts (15 property sets, shared byte lookup).
The bounded detector matches 36,443 actual native player contacts: all states plus
representative below/direction/flight/spectator/gliding contexts. Open trapdoors
require matching ladders below; missing observations fail. Native queries fit the
existing standing frame. Five contact/motion tests pass. Evidence:
`.local/climb-{blocks,contact}-{native,check}.log`, `.local/climb-contact-tests.log`.

Live checkpoint: dry clamps/fall reset precede sampled collision; the post-move
feet select jump/horizontal boost before air drag. Water uses its own post-collision
climbing branch without dry caps. The existing fenced owner commit applies results;
no extra timer, owner or frame budget. Packet fall accounting keeps its ordering.
61 affected tests pass, including ladder versus scaffolding Shift, fall reset before
powder-snow collision, leaving a ladder during the step, waterlogged ladder boost,
flight/spectator exclusions and real TCP input/source changes. The 1,920 native
motion cases also enclose movement and feet/below lookups in acquired frames across
standing/crouching/swimming and fractional heights. Evidence:
`.local/climb-live-targeted.log`, `.local/climb-live-frame-check.log`.

Limits: live gliding, powder-snow walking boost, entity/vehicle input and survival consequences
remain separate work; supplied gliding contact is native-verified only.

Integration checkpoint `f83e8e7`: 600 full tests and separate production release
pass; full native integration, including plaintext/encrypted TCP, passes. Evidence:
`.local/climb-block-{full-tests,full-native,production}.log`.
First frozen 512-player spread-water load failed: all final positions/swimming
states matched and no disconnects, but
773 corrections (264 worker deadlines, 509 late results). Native integration and
the real graphical client were active on the same host. After integration ended,
controlled previous `3c99728` and climbing `f83e8e7` runs both passed 512 players /
51,200 moves / 5.143s with zero corrections/disconnects and all final positions/
swimming states verified. Climbing 128-player dense / 12,800 moves / 5.522s also
passes. The failure did not recur; these runs do not establish its cause or full
server capacity. Static pools/scripted positions exclude survival and propagation.
Raw:
`bench/results/climbing-512-spread-water-failed-concurrent-native.json`,
`bench/results/climbing-{control-3c99728-512,512-spread,128-dense}-water.json`.
`.local/climbing-block-load-provenance.json` verifies all 477 frozen source blobs
and records hashes/revisions; driver enclosing checkout revision differs from source.

Dedicated actual Java client gate PASS, October 15, 19:47–19:59 CEST, unchanged
PID77944, dataset `/tmp/valimc-live-motion-client-20261015`. Actual W climbs ladder/
vine and release descends; Shift holds ladder but descends scaffolding. Dry open
matching trapdoor holds/passes, wrong-facing falls, closed blocks ascent; dry IDs
8785/8789 avoid the initial waterlogged fixture mistake. Wet ladder, actual flight
toggle/exclusion, saved grounded contact/fresh direct reconnect, swimming and dry
jump/walk regressions pass without unexpected corrections/disconnects. Numerical
isolated branch parity comes from native/targeted tests, not these functional
observations. Report reviewed: `.local/client-tests/VMC-015e/report.md`.
All 162 fixture cells restored/reobserved; inventory unchanged, safe dry state,
zero players and both owned clients stopped. Requested paused noon retained.
