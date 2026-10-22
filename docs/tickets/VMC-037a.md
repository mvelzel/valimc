# VMC-037a — Owned status-effect state

Status: Done
Resolved (VMC-079): Living.Effects, its packets and persistence are live; potions arrived with VMC-037b.
Note: Duration, map, wire, immunity and persistence foundations **Done within their stated scopes**. [Owned Fire Resistance](VMC-037a1.md) and [supported potion drinking](VMC-037b.md) are accepted at `fa0b320`.

Acceptance: bounded immutable effect state supports native stronger/weaker refresh,
hidden effects, finite/infinite durations and flags. Keep one effect map on the
player owner and advance it on the existing admitted clock; no process/timer per
effect. Later slices add source immunity, periodic actions, attributes, packets and
atomic persistence. Do not treat catalog data as implemented effects.

Client: kernel foundation uses a baseline join/walk/inventory smoke. Live Fire
Resistance must show the status icon, prevent actual fire/lava/campfire damage and
wear, expire correctly, survive reconnect and retain non-fire damage negatives.

Pinned 26.3 reference: `MobEffectInstance.update/tickServer`, hidden-effect promotion,
`LivingEntity` effect ownership and source immunity. Private disassembly:
`.local/effects-MobEffectInstance.javap`. Probe real instance transitions before
choosing the immutable representation; scalar flags are not a live effect system.

October 16: `StatusEffect` uses a compact immutable priority list, active first,
with strictly decreasing amplifiers and at most 256 rungs. Suppressed durations
continue counting; finite/infinite refresh and promotion preserve native flags.
Refresh returns a separate notification flag: hidden state can change without an
active-effect notification. No process/timer or live state is added.
50,433 actual native traces match, including all flag combinations, zero/infinite/
maximum durations, mixed refresh/server ticks and the full 256-level suppression
chain. Three boundary/invariant tests pass(seed495959). Original probe invokes
`MobEffectInstance.update/tickServer` with Fire Resistance and a controlled body,
so no periodic action is executed. Gameplay hooks, attributes, icons, persistence
and live immunity remain open. Evidence: `.local/status-effect-{native,native-check,
targeted}.log`; raw transitions are ignored.

Wire foundation:40 native built-in effect names/IDs and 61,600 complete update/remove
packets match independently encoded bytes and Mojang decoding: all ambient/particle/
icon/blend flags, four entity IDs, four amplifiers and finite/infinite duration
boundaries. These are fixed built-in holders, not the synchronized dynamic registry
table. `EffectTypes` indexes their scalar identities; `Packets` validates IDs/state
before encoding. Eight affected checks cover malformed inputs and existing lifecycle
packets. Original `StatusEffectPacketOracle`; evidence:
`.local/status-effect-packets-{native,native-check,native-decode,targeted}.log`.
This wire checkpoint alone emits no live status packets.

October 16 baseline **PASS**, frozen `9fce29f`: actual join/terrain, walking, `/stats`,
inventory, death/Respawn and a fresh reconnect. Dedicated report reviewed:
`.local/client-tests/VMC-017b5-message/report.md`. This release contains both unused
foundations; no live effect icon/immunity is claimed.1,253 full tests(seed554870)
and production pass; native duration/packet checks above cover these additions
separately from the earlier `8fbe510` full native run. The map, persistence and live
composition below supersede that checkpoint's limited baseline.

Local map/immunity foundation: `PlayerEffects` keeps at most 40 catalog entries with
bounded suppression chains.129 actual `LivingEntity.addEffect/removeEffect/tickEffects`
traces match map state and per-effect callback order, including simultaneous promotion/
600-tick updates, zero-duration removal and suppressed refresh without notification.
The probe uses inert Fire Resistance/Water Breathing and controlled callbacks;
eligibility, periodic actions and attributes are excluded. `PlayerStatusImmunity`
matches 306 native `LivingEntity.hasEffect/hurtServer` cases across all 51 sources:
Fire Resistance presence(including zero duration until removed) blocks eight fire
sources before downstream health/wear; unrelated effects and non-fire sources do not.
Nine affected checks pass(seed108479), including full 40×256 bounds and malformed
maps. Evidence: `.local/player-effect-map-{native,native-check,targeted}.log`,
`.local/status-damage-{native,native-check,targeted}.log`. Live baseline and
integration acceptance are recorded in VMC-037a1, including actual source negatives.

Snapshot foundation: optional v18 wraps existing journals under one checksum, with
a canonical 61,561-byte maximum effect payload(40 IDs×256 rungs). Legacy snapshots
keep their encoding. Active/suppressed durations and flags survive ordinary death
transfers and typed mining/table, placement-refund and pickup-restart boundaries;
requests, counters and receipts are unchanged. Disconnect-close and transfer cleanup
also retain the newest effect state.62 affected checks pass(seed255828), including
the late-state close/rejection/death regression. Malformed counts,
IDs/chains/flags, truncation, recursive wrappers and wrong UUIDs refuse. Evidence:
`.local/player-effect-snapshot-targeted-final.log`. Owned restoration/clock/icon and
quiet-clock final-save acceptance are recorded in VMC-037a1/037b. These foundations
are complete; remaining effect behavior is separate work, not a pending gate here.
