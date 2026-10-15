# VMC-036a — Owned hunger and regeneration

Status: Live clock/journal/HUD automated-verified; graphical gate pending. October 15, 2026.
Depends on owned health, the admitted player clock and durable player snapshots.

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
healing/starvation every80. Peaceful fractional saturation can overshoot20, so
bounded state permits that native value. Five boundary tests pass. Raw evidence:
`.local/player-food-{native,check,tests}.log`, `.local/player-food-cases.json`.
No live hunger or GUI claim at this foundation checkpoint.

Journal/HUD checkpoint: snapshot v12 stores food, saturation, exhaustion and timer
in11 bytes under the shared checksum. Versions1..11 default to a fresh food state;
invalid/nonfinite data is rejected. Login/damage replicate actual food and
saturation, reconnect retains them, and respawn resets them. Transfer preparation
and pending-close field merging retain current food without restoring spent items.
Seventy affected tests pass, including a real TCP saved-food/damage/reconnect/
death/respawn scenario. The expanded lifecycle oracle matches241 bidirectional
packets, including80 health/food/saturation combinations, plus eight command
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
Protection points:62,400 source/gear cases and245 bidirectional health/lifecycle
packets pass. Food arithmetic/default probes remain verified.

The131 affected tests pass, including eight food TCP scenarios covering exact
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
those fixture corrections. Frozen runtime `95a9d36` contains567 verified blobs,
no mismatches; later edits affect tests/evidence only. Manifest/build logs:
`.local/food-validation-checkpoint.json`, `.local/food-validation-production.log`.
Full native integration is running; matched preview measurements follow it.
The existing GUI server remains unchanged.

Client scenario: seed a damaged survival body and observe actual hearts recover
with full food; low food prevents healing, exhaustion spends saturation then food,
and a hungry body shows depleted drumsticks. Reconnect retains the state. Check
disabled regeneration and difficulty-specific starvation, including a fatal hard
case followed by actual Respawn. Delegate on a frozen release after prior gates.
