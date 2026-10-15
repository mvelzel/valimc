# VMC-036a — Owned hunger and regeneration

Status: Native transitions verified; owner composition in progress. October 15, 2026.
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

Client scenario: seed a damaged survival body and observe actual hearts recover
with full food; low food prevents healing, exhaustion spends saturation then food,
and a hungry body shows depleted drumsticks. Reconnect retains the state. Check
disabled regeneration and difficulty-specific starvation, including a fatal hard
case followed by actual Respawn. Delegate on a frozen release after prior gates.
