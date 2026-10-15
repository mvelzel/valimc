# VMC-015e — Player climbing

Status: In progress. October 15, 2026.

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

Next: frozen client gate and coherent-block integration/build checks. Live gliding,
powder-snow walking boost, horizontal input acceleration and survival consequences
remain separate work; supplied gliding contact is native-verified only.
