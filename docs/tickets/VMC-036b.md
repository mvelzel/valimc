# VMC-036b — Movement exhaustion

Status: Native travel/jump foundations verified; owner composition pending. October 16, 2026.
Depends on [owned food](VMC-036a.md) and fenced accepted movement.

Acceptance: accepted survival sprint/swim travel and grounded jumps add native
exhaustion once. Respect native movement precedence and float32 centimeter
rounding; ordinary walking/crouching/climbing/flight must not consume food.
Creative/spectator abilities suppress exhaustion. Stale, rejected, replayed and
predicted movement cannot spend food. Persist the resulting food state and show
depletion through the existing HUD. Keep calculation local; use the accepted
frame for fluid/climbing facts, without a new geometry query or global process.

Reference: pinned 26.3 jar SHA1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`,
`ServerPlayer.checkMovementStatistics`, `Player.causeFoodExhaustion`, grounded jump
callbacks and `FoodConstants`. Private `.local/food-ServerPlayer.javap`.
Swimming/underwater distance uses three axes; body-only water and grounded sprint
use horizontal distance. Native precedence matters when predicates overlap.

`MovementFood` matches3,584 actual `ServerPlayer.checkMovementStatistics`
exhaustion requests across256 overlapping predicates and14 movement/rounding
boundaries. Another24 actual `Player.causeFoodExhaustion` executions verify all
mode ability gates and saturation of added exhaustion. Two actual ServerPlayer
jump callbacks (zero jump power/no-op stats) request0.2 sprinting or0.05 otherwise.
The listener invokes that callback on grounded-to-airborne upward movement; the
owner will bind it after acceptance rather than copy vanilla's pre-validation
ordering. World contacts/acceptance and stats persistence are excluded. Four
focused boundary tests pass. Logs `.local/movement-food-{native,check,tests}.log`.
Next: bind both requests to fresh accepted owner movement and current abilities.
Bubble columns still count as eye-water for travel even though they restore air.
This is not live food depletion or a GUI pass.

Client scenario: actual survival sprint laps and swimming drain saturation then
drumsticks; ordinary walking and creative flight are negatives. Reconnect retains
the depleted state. Include grounded jump versus airborne held jump, correction
and stale-frame negatives. Sprint eligibility/consumables remain distinct slices.
