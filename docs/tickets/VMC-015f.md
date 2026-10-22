# VMC-015f — Relative movement input

Status: Parked
Resolved (VMC-079): relative input is not live and vanilla does not replay it for players; mob movement control takes it up in VMC-015i.
Note: In progress. October 15, 2026.

Acceptance: native direction cancellation/normalization and yaw rotation; float
acceleration rates for grounded/airborne/flight/water/lava contexts. Compose input
before climbing/collision where that entity's simulation owns it, with explicit
frame bounds and input ordering.
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

Input boundary: `ServerGamePacketListenerImpl.handlePlayerInput` stores
`lastClientInput` and, once loaded, updates Shift; it does not assign simulated
axes/jumping. Native `setLastClientInput` preserves those fields in all 1,408
intent cases. `Player`/`Avatar` do not override inherited `applyInput`, which only
decays supplied axes. The pinned server jar's intent consumers are player
advancement predicates and old/new minecart behavior, not ordinary walking.
Private references: `.local/input-{ServerPacket,Avatar}.javap`,
`.local/gravity-{ServerPlayer,LivingEntity,Player}.javap`.

Therefore ordinary player travel must not blindly replay reported directions.
Keep these kernels for simulation-owned entity/vehicle input and future prediction;
live ownership/integration and the corresponding client gates remain open.

Foundation baseline PASS on frozen `59de8fc`, October 15, 20:03–20:05 CEST:
actual direct join/render, recovered daytime, walk/jump/crouch and ladder regression.
Dedicated report reviewed: `.local/client-tests/VMC-015fg-kernels/report.md`.
This checks compiled integration, not live input acceleration. Client stopped,
fixtures restored, inventory/journal unchanged and zero players.
