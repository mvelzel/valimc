# VMC-017a — Owned health and fall damage

Status: Owned health/login/save automated-verified; client gate pending. Fall
damage and death/respawn remain in progress. October 15, 2026.

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
Next: native fall calculation, owned health/protocol/save state and fatal lifecycle.

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
Next client checkpoint: visually verify survival hearts from seeded health7.25,
normal movement/inventory and a fresh direct reconnect. This validates health/save
plumbing only; damage, death/respawn and their full acceptance scenarios remain open.
