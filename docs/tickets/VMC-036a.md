# VMC-036a — Owned hunger and regeneration

Status: Done
Note: Validated and complete within owned food-clock scope. October 16, 2026. Depends on owned health, the admitted player clock and durable player snapshots.

Acceptance: food, saturation, exhaustion and the regeneration timer belong to
the player process. Match native exhaustion thresholds, saturated/ordinary
regeneration, starvation difficulty limits and peaceful recovery. Preserve them
with health/inventory across reconnect; respawn creates a fresh body. Stale ticks
cannot advance them. Replicate actual food/saturation in the health packet and
honor the natural-regeneration rule through published world settings, with no
global gameplay call or extra player timer.

Scope: food clock/state and consequences first. Accepted movement/action
exhaustion, sprint eligibility, consuming items and effects are subsequent slices;
the preview does not yet provide a complete survival loop.

Reference: pinned Mojang 26.3 jar SHA1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`, `FoodData` arithmetic/tick/save,
`ServerPlayer.tickRegeneration` and health replication, `Player.isHurt`.
Private bytecode: `.local/FoodData.javap`, `.local/food-ServerPlayer.javap`.
Implement original Elixir transitions; native probes observe the real methods
with controlled player/world callbacks and explicitly exclude the damage pipeline.

`PlayerFood` matches 10,240 real `FoodData.tick` transitions, 1,296 actual peaceful
prefixes, 30 exhaustion additions and 144 absolute-saturation meal transitions;
save/load defaults also match. Health callbacks are recorded, not applied by
these probes; native `Player.isHurt` is retained. Native exhaustion spends once
per tick only above four; fast healing is saturation/6 every ten ticks, ordinary
healing/starvation every 80. Peaceful fractional saturation can overshoot 20, so
bounded state permits that native value. Five boundary tests pass. Raw evidence:
`.local/player-food-{native,check,tests}.log`, `.local/player-food-cases.json`.
No live hunger or GUI claim at this foundation checkpoint.

Journal/HUD checkpoint: snapshot v12 stores food, saturation, exhaustion and timer
in 11 bytes under the shared checksum. Versions 1..11 default to a fresh food state;
invalid/nonfinite data is rejected. Login/damage replicate actual food and
saturation, reconnect retains them, and respawn resets them. Transfer preparation
and pending-close field merging retain current food without restoring spent items.
Seventy affected tests pass, including a real TCP saved-food/damage/reconnect/
death/respawn scenario. The expanded lifecycle oracle matches 241 bidirectional
packets, including 80 health/food/saturation combinations, plus eight command
boundaries. Raw `.local/player-food-journal-tests.log`, `.local/player-food-life-*.log`.
At that checkpoint owner ticking remained open; the next checkpoint completes it below.

Live clock: admitted owner ticks advance food once, after void consequences.
Food and health observations are published together; health/food/zero-saturation
changes replicate without per-tick packets. Peaceful body phase is transient and
resets on reconnect/respawn. The world record v4 stores natural regeneration;
v1..3 retain the native true default. Difficulty and rule publish as one ETS pair,
so a stalled world owner cannot block food ticks. Dead/sealing bodies stop food.
Starvation uses ordinary loading/mode/cooldown rules and the durable death lane.
Native damage probes verify that starvation bypasses armor/effects despite worn
Protection points:62,400 source/gear cases and 245 bidirectional health/lifecycle
packets pass. Food arithmetic/default probes remain verified.

The 131 affected tests pass, including eight food TCP scenarios covering exact
fast/ordinary healing, exhaustion, stale/early ticks, peaceful fractional recovery,
disabled regeneration, published settings under a stalled world owner, difficulty
floors, protection bypass/shared cooldown, damaged reconnect and fatal hard-mode
starvation with two durable batches and fresh food on respawn. Other damage tests
use an explicit no-regeneration fixture; production defaults remain native true.
Two initial test failures found a ready-publication race in fixture lookup and an
expected health value that omitted worn fall protection; both fixtures were fixed.
Logs: `.local/player-food-owner-affected-tests.log`, `.local/food-survival-rules-tests.log`,
`.local/starvation-{protection,life}-*.log`. Actual client validation remains pending.
Accepted movement/action exhaustion and consuming items remain subsequent work.

Block:724 full tests pass (`.local/food-block-full-tests-final.log`, seed327342)
and a separate production release builds. The first full run exposed shared-spawn
item interference in two death fixtures; they now use an isolated region/dataset.
A replay assertion also compared asynchronous pose fields; it now checks only the
food/health/body phase and admitted tick. The same full-suite seed passes after
those fixture corrections. Frozen runtime `95a9d36` contains 567 verified blobs,
no mismatches; later edits affect tests/evidence only. Manifest/build logs:
`.local/food-validation-checkpoint.json`, `.local/food-validation-production.log`.
Full native integration on `95a9d36` passes, including both plaintext/encrypted TCP:
`.local/food-validation-full-native.log`. The newer movement checkpoint `c36d01f`
also passes 740 full tests, both native TCP transports and its production build;
see [movement exhaustion](VMC-036b.md). The GUI server remains unchanged.
The matched 512-player memory increase is tracked in [idle food work](VMC-036a1.md).

Client scenario: seed a damaged survival body and observe actual hearts recover
with full food; low food prevents healing, exhaustion spends saturation then food,
and a hungry body shows depleted drumsticks. Reconnect retains the state. Check
disabled regeneration and difficulty-specific starvation, including a fatal hard
case followed by actual Respawn. Delegate on a frozen release after prior gates.

October 16 actual-client evidence — reviewed and accepted: immutable7337af6
release/PID74315, disposable `/tmp/valimc-consumable-client-20261016`, Java26.3/
protocol 777, nine fresh small direct SDL/CUA clients. Legitimate disconnected
leases seeded supported survival bodies; actual owner clock spent saturation 2→0
before food 10→8 at exhaustion 20→4 (four-drumstick HUD), fast timer 9→0 healing
from8HP with saturation and native fractional/exhaustion changes, ordinary
79→0 healing 8→9 atfood 18/sat0 then food 17/noheal. Rulefalse held8HP with full
food/sat5. Easy 11→10HP and normal 2→1HP held through repeated80tick windows,
with actual five-heart/half-heart and empty hunger HUD. Fresh direct reconnect
restored exact HP10/food0/sat0/ex0/timer22 at load_ticks60, actual HUD/E.
Peaceful food 10/HP10/sat.5 recovered to 20/20 with native phase/saturation changes
and full HUD. Hard 2→1→0 showed actual “starved to death”; actual Respawn rendered
full10hearts/fullfood/E-empty, owner20HP/food20/sat5/ex0/timer0/air300.
Exactly one conserved stone 3 record 20162/source10 transfer, no repeated delivery;
all prior 28 ID/stack/components unchanged, final 17/8/4=29 records, receipts
latest 10/6/9 and outboxnil. All JVMs stopped/waited; zeroPlayers and safe fresh-body
snapshot, difficulty 1/unlocked and natural_regenerationfalse restored. No host
damage or release restart. Protection/stale/stalled/effect negatives remain native/
automated coverage; movement exhaustion is a later slice. Full factual report,
seeds, timer/cadence traces, reconnect and conservation proof:
`.local/client-tests/VMC-036a/report.md`.
