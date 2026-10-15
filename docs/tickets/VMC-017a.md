# VMC-017a — Owned health and fall damage

Status: Owned health/login/save validated (`18028cd`). Fall damage and
death/respawn remain in progress. October 15, 2026.

Acceptance: player-owned finite health, persistent save/reconnect, current health
packets and fall damage from authoritative accepted landing distance. Preserve
creative/spectator immunity, material/attribute factors, fall resets and damage
cooldowns. Fatal damage requires a consistent death/respawn lifecycle before live
publication; no half-dead player state. Keep inventory/transfer durability intact.
Other damage sources, armor, food and effects remain parent VMC-017/VMC-037 work.

Reference: pinned Mojang 26.3 `LivingEntity.calculateFallDamage/calculateFallPower/
setHealth/hurtServer`, `Player.causeFallDamage`, current attribute facts and health/
damage/death/respawn codecs. Reuse the player owner and fenced geometry lane.
Native 26.3 calculation floors `(distance + 1e-6 - safe_fall) * material_float *
attribute_multiplier`; do not substitute remembered older-version rounding.

Client gate: survival falls below/at/above the threshold, visible health loss,
protected water/web/slime/honey landing, creative flight immunity, damaged
reconnect, fatal landing/death UI and respawn. Verify inventory consistency and
repeat damage/cooldown negatives. Helpers alone do not complete this ticket.
Next: death/respawn lifecycle, then fenced landing damage and its full client gate.

Calculation checkpoint: original `Physics.FallDamage` matches 2,600 actual native
`calculateFallDamage` cases, including epsilon/floor thresholds, float32 material
factors, safe-fall and multiplier attribute limits, immunity and positive int
saturation. Two affected tests pass. Attribute limits come from the existing pinned
`priv/protocol/attributes.json`. Evidence: `.local/fall-damage-{native,check,tests}.log`;
original `scripts/FallDamageOracle.java`. The fall calculation remains unwired.

Health foundation checkpoint: `PlayerHealth` matches 40 native setter/save/load
cases and 336 actual `LivingEntity.hurtServer` cooldown prefixes (blocking,
armor/absorption, events and death excluded). Stronger protected hits select only
the increase before defenses. Health metadata is accessor9/float serializer3;
native codecs verify health updates and metadata among 62 packets and 272 packed
velocities. Snapshot v9 stores float32 health plus saved hurt/death timers alongside
velocity, inventory and the transfer journal; older versions remain readable.
Cooldown/last-hit state is transient. Transfer preparation and pending disconnect
retain health without restoring spent items; 42 affected tests pass. Evidence:
`.local/player-health-{native,check,tests}.log`, `.local/health-entity-{native,check,verify}.log`.
This foundation alone did not enable live damage or complete the client gate.

Owner checkpoint: login restores snapshot health (legacy/new players default to
max health), sends it through `set_health`, and captures it on saves/disconnect.
Hurt/cooldown decrement once per admitted owner tick, independent of the geometry
lane, following `LivingEntity.baseTick` and `ServerPlayer.tick`. Death timers await
the death lifecycle. Seventy-five affected tests pass, including two TCP sessions
at health7.25 with exact inventory retention, legacy migration, pending-teleport
timer progression and stale/early tick rejection. Tests synchronize initial packet
checks with the socket owner. Evidence: `.local/player-health-live-tests.log`.
Frozen `18028cd`, `.local/health-live-checkpoint` (520 verified blobs), passed actual
Java 26.3 checks at 21:24–21:28 CEST: seeded health7.25 displayed four filled hearts,
dry movement/jump and `/stats`, real seven-stone hotbar move, durable snapshot and
fresh direct reconnect with the same health/inventory. Both clients stopped/waited;
leased cleanup restored a safe preview state. Tester report reviewed:
`.local/client-tests/VMC-017a/health-report.md`. The health/login/save checkpoint is
complete; fall damage, regeneration, peer health, hurt events and death/respawn
remain unimplemented and are not covered by this gate.

Local protocol checkpoint: 100 native round trips cover fall damage events,
death animation/messages and overworld respawn across current/previous modes and
death positions. Eight client-command enum boundaries and malformed/trailing
request tests pass; requests are parsed without gameplay authorization. The shared
spawn payload retains all 20 native login mode cases; 22 affected tests pass.
Evidence: `.local/player-life-{native,check,verify,tests}.log` and
`.local/player-life-login-{native,check,verify}.log`. These primitives are unwired
and remain local pending lifecycle/client validation.

Next slice: fence pending movement when health reaches zero; retain dead health
and inventory while conserved death drops drain through bounded existing outbox
batches. Reconnect must resume pending delivery before publishing inventory;
respawn requests must wait for cleanup and reject living players. Then reset
motion/input/health, synchronize the client world and verify fatal UI/respawn,
reconnect and inventory conservation before enabling landing damage.
