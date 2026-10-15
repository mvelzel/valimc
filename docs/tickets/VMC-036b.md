# VMC-036b — Movement exhaustion

Status: Validated and complete within accepted movement-exhaustion scope. October 16, 2026.
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

`MovementFood` matches 3,584 actual `ServerPlayer.checkMovementStatistics`
exhaustion requests across 256 overlapping predicates and 14 movement/rounding
boundaries. Another 24 actual `Player.causeFoodExhaustion` executions verify all
mode ability gates and saturation of added exhaustion. Two actual ServerPlayer
jump callbacks (zero jump power/no-op stats) request0.2 sprinting or0.05 otherwise.
The listener invokes that callback on grounded-to-airborne upward movement; the
owner will bind it after acceptance rather than copy vanilla's pre-validation
ordering. World contacts/acceptance and stats persistence are excluded. Four
focused boundary tests pass. Logs `.local/movement-food-{native,check,tests}.log`.
Bubble columns still count as eye-water for travel even though they restore air.

Live: the existing movement worker resolves water/eye/climbing predicates from
its fenced frame and returns separate jump/travel requests. The owner checks
deadline/signature/owners before committing them to its current food state, with
the current ability gate. Jump precedes travel, preserving float32 addition order.
Ordinary walking/immune requests take a cheap zero path. No extra query, worker,
timer or global call. Eye-water and air-draining submersion share one sample.

Ninety-one affected tests pass, including 12 focused TCP scenarios: sprint food/HUD
depletion and reconnect, actual selected swimming/underwater/body-water/bubbles,
walking/scratch/held-jump negatives, accepted jumps, creative/spectator immunity,
ladder removal, speed/collision corrections and retired geometry. A blocked frame
retains socket ordering before stop-sprinting, and food ticks during a blocked
frame are retained at commit. The first blocked test incorrectly expected a later
wire command to overtake pending movement; the fixture now verifies wire order.
Raw `.local/movement-food-owner-affected-tests-complete.log` (seed550802).
Block checkpoint `c36d01f` passes 740 full tests, a separate production build and
both plaintext/encrypted native TCP integration. The prior food checkpoint's full
native run also passes; only changed movement/air sampling needed targeted checks
plus TCP here. Frozen manifest: `.local/movement-food-validation-checkpoint.json`,
573 blobs/no mismatches. Logs `.local/movement-food-block-full-tests.log`,
`.local/movement-food-native-tcp.log`, `.local/movement-food-validation-production.log`.

Six matched creative-water loads (ten schedulers), `ebb2874`→`c36d01f`: spread512
5.146→5.125s, login p95 153.43→73.55ms, final265.76→318.59MiB; dense128
5.593→5.751s, 132.64→66.39ms, 123.88→125.44MiB. Reverse spread order gave before
5.121s/77.19ms/253.87MiB, after5.122s/190.17ms/318.54MiB. Every position/swim flag
verified; zero corrections/disconnects. Login tails vary; the memory increase
motivates [idle food work](VMC-036a1.md). No survival capacity/speed claim.
Raw `.local/food-load-*.json/.log` and `.local/food-load-revisions.json`.

Sprint eligibility,
mining/combat exhaustion, effects and consuming items remain subsequent work.

Client scenario: actual survival sprint laps and swimming drain saturation then
drumsticks; ordinary walking and creative flight are negatives. Reconnect retains
the depleted state. Include grounded jump versus airborne held jump, correction
and stale-frame negatives. Sprint eligibility/consumables remain distinct slices.

October16 actual-client evidence — reviewed and accepted: immutable7337af6/
PID74315 release, disposable `/tmp/valimc-consumable-client-20261016`, Java26.3/
protocol777, five fresh small direct SDL/CUA clients. Actual W/Shift+W accepted
14.31m with exhaustion3.95 unchanged; Ctrl+W10sec accepted56.96m, saturation1→0
then food20→19/HUD9.5drumsticks. Grounded Space350ms added0.05 once; held-airborne
input/accepted ascent/descent added no further jump cost. Fresh direct reconnect
retained exact food19/sat0/ex3.536013126/timer0 and actual depleted HUD. Actual
Ctrl+W swimming in a bounded water corridor set swimmingtrue and spent exhaustion
through food19, underwater/bubble/HUD view; armed air watcher prevented drowning.
Fixed-x/z underwater Space cycles added four0.05 grounded jumps plus0.0956
vertical travel; dry-eye/body-water repetition added only four0.05 jumps, zero
vertical travel. Creative actual sprint/jump17.94m and spectator flight45.70m
horizontal/9.37m vertical retained exact food/exhaustion; invulnerable abilities
and released input0/flags0 traced. Sprint-jump0.2 is a CUA input-composition limit
(native callback covered); climbing/creative-flight and independent body-water
horizontal GUI assertions remain limits. No eligibility/stale/correction GUI claim.
All wrappers stopped/waited/zeroPlayers, temporary1000-cell pool restored exactly,
safe survival20HP/air300/food19/sat0/ex.673300385/timer0/empty snapshot; source10/
outboxnil/lastdeath unchanged. All29 prior item ID/stack/components unchanged,
counts17/8/4 and receipts10/6/9; initial difficulty1/unlocked/regenfalse unchanged.
No gameplay failure/release restart. Full actions, native-control limitation,
traces, conservation and cleanup: `.local/client-tests/VMC-036b/report.md`.
