# VMC-037a — Owned status-effect state

Status: Pure duration/replacement kernel verified locally; baseline pending.
No live effects yet.

Acceptance: bounded immutable effect state supports native stronger/weaker refresh,
hidden effects, finite/infinite durations and flags. Keep one effect map on the
player owner and advance it on the existing admitted clock; no process/timer per
effect. Later slices add source immunity, periodic actions, attributes, packets and
atomic persistence. Do not treat catalog data as implemented effects.

Client: kernel foundation uses a baseline join/walk/inventory smoke. Live Fire
Resistance must show the status icon, prevent actual fire/lava/campfire damage and
wear, expire correctly, survive reconnect and retain non-fire damage negatives.

Pinned26.3 reference: `MobEffectInstance.update/tickServer`, hidden-effect promotion,
`LivingEntity` effect ownership and source immunity. Private disassembly:
`.local/effects-MobEffectInstance.javap`. Probe real instance transitions before
choosing the immutable representation; scalar flags are not a live effect system.

October16: `StatusEffect` uses a compact immutable priority list, active first,
with strictly decreasing amplifiers and at most256 rungs. Suppressed durations
continue counting; finite/infinite refresh and promotion preserve native flags.
Refresh returns a separate notification flag: hidden state can change without an
active-effect notification. No process/timer or live state is added.
50,433 actual native traces match, including all flag combinations, zero/infinite/
maximum durations, mixed refresh/server ticks and the full256-level suppression
chain. Three boundary/invariant tests pass(seed495959). Original probe invokes
`MobEffectInstance.update/tickServer` with Fire Resistance and a controlled body,
so no periodic action is executed. Gameplay hooks, attributes, icons, persistence
and live immunity remain open. Evidence: `.local/status-effect-{native,native-check,
targeted}.log`; raw transitions are ignored. Next: owner state/codec and source
immunity, with baseline before publishing this unused foundation.
