# VMC-037d — Periodic health effects

Status: Native action/timing foundation verified locally. No live grant/drink
support yet; its client gate remains open and this work stays unpushed.

Acceptance: Regeneration, poison and wither execute on the existing player clock
with native active-head timing, finite/infinite duration, amplifier shift behavior,
health thresholds and damage source. Suppressed effects must not act before
promotion. Preserve mode, defenses, cooldowns, durable health/effects/inventory,
death/respawn and reconnect. No per-effect process or timer.

Client: actual drinks heal/hurt at native intervals; canceled/unsupported use
remains intact. Poison stops near its native health floor; wither can kill. Check
expiry, higher-level/hidden promotion, mode/gear negatives and fresh reconnect.
Trusted setup is distinct from actual drinking, hearts/status and death evidence.

Pinned26.3 reference: `MobEffectInstance.tickServer`, `RegenerationMobEffect`,
`PoisonMobEffect`, `WitherMobEffect`. Actions precede duration decrement/promotion;
finite durations supply the countdown while infinite effects use entity tick age.
Native Java shifts mask amplifier to five bits, including amplifier32/64 wrapping.
Private disassembly: `.local/status-actions-*.javap` and
`.local/effects-MobEffectInstance.javap`. The initial probe will intercept native
heal/damage requests; downstream health, defenses and owner composition are
separate validation gates.

October16: original `PeriodicEffectOracle` executes actual native instance ticks
and intercepts heal/damage requests.124,596 cases match `PeriodicEffect` requests
plus the existing `StatusEffect` duration/promotion kernel: all256 amplifiers,
zero/finite/infinite duration, signed entity ages, native float health thresholds,
maximum1/20/128/1024 and continuous hidden promotion. Regeneration requests one
heal below maximum; poison requests one `magic` damage only above1HP; wither
requests one `wither` damage. A request alone neither revives nor commits health.
Only the active head acts, before decrement/promotion. Finite countdown phase
does not depend on entity age. Ten affected tests pass(seed763640). Evidence:
`.local/periodic-effects-{native,native-check,targeted}.log`. These are no live
damage/gear/cooldown/durability or graphical proofs. Owner composition follows.
