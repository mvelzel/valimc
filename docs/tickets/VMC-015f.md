# VMC-015f — Relative movement input

Status: In progress. October 15, 2026.

Acceptance: native direction cancellation/normalization and yaw rotation; float
acceleration rates for grounded/airborne/flight/water/lava contexts. Compose input
before climbing/collision with explicit ownership, frame bounds and input ordering.
Keep reported displacement distinct from simulation and avoid replaying stale input.

Reference: pinned Mojang 26.3 `Entity.getInputVector/moveRelative`,
`ServerPlayer.getLastClientMoveIntent`, `LivingEntity.getFrictionInfluencedSpeed`,
`travelInWater/travelInLava` and `Player.getFlyingSpeed`. Supplied attributes/contact
are not proof of complete live ownership or client movement prediction.

Client gate: walk/diagonal/opposed inputs, changing yaw, sprint/crouch, ground/ice,
air/flight, water/lava and ladder transitions; compare accepted motion, velocity,
corrections and reconnect. First build native kernels and establish the native
server input boundary; do not blindly apply client intent twice.

Kernel checkpoint: original `Physics.RelativeMotion` normalizes/rotates intent,
adds acceleration and selects supplied dry/flight/water/lava rates. `PlayerInput`
exposes reported world-space intent without granting movement authority. Native
probe matches 528 vector/acceleration cases, all 128 button combinations across
11 yaws (1,408 actual `ServerPlayer` intents) and 1,152 rate contexts bit-for-bit.
Cases cross the tiny-input threshold, diagonals, opposing keys, large/wrapped yaw,
float ground-friction threshold, sprint/flight and water efficiency rounding.
Ten affected tests pass. Evidence: `.local/relative-motion-{native,check,tests}.log`.

Live composition remains open. These helpers are not yet called by player travel;
native `getLastClientMoveIntent` is an observation, not proof that the server
replays those directions as acceleration. Resolve that ownership before wiring.
