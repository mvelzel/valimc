# VMC-037d — Periodic health effects

Status: Owned composition `5b123b1` passes automated checks/build and all actual
client groups. Full native integration is still running; keep this block unpushed.

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
damage/gear/cooldown/durability or graphical proofs. Owned composition follows.

Owned composition admits all three effects through the existing grant/login and
atomic potion-use lane. The player clock selects requests from pre-decrement
heads, folds independent effect kinds in ID order and stops actions at death.
It installs the final duration map before health can seal a death snapshot.
Infinite age is the admitted player clock wrapped to signed32; no catchup or
extra timer/process. Healing replicates hearts/metadata without food exhaustion;
damage uses the existing mode/load/cooldown/defense/death path. Magic/wither bypass
armor and wear, retain ordinary worn Protection and cause zero exhaustion.

Native proofs:20,800 magic/wither enchantment/slot/threshold contexts,32 native
death translations/256 independently encoded death/chat packets,265 lifecycle/
damage packets including both added sources, all native-decoded. Only two scalar
translation keys were added to public facts. Evidence:
`.local/periodic-damage-{protection,message}-*.log`,
`.local/periodic-player-life-{native,check,decode}.log`.

79 affected checks pass(seed827311); later47 owner/use/death-store checks pass
(seed915800), overlapping intentionally. Boundaries include countdown/infinite
phase, signed age wrap, hidden promotion, stale timers, poison's health threshold,
ten-tick hurt suppression, modes, worn/carried defenses, stalled geometry, finite
reconnect, stock main-hand regeneration/poison and custom offhand wither bottles.
Fatal wither seals decremented effects and one unchanged drop. A suspended potion
writer also permits one subsequent death, retaining the consumed bottle exactly
once through source/receipt completion. Raw logs:
`.local/periodic-live-targeted-final.log`, `.local/periodic-live-recovery-targeted.log`.
Initial tests exposed the missing packet-source allowlist and a test helper that
incorrectly required idle geometry to run; both corrected. The idle sample
optimization is unchanged. Actual-client evidence follows.

Frozen `5b123b1` passes1,302 full tests(seed458956) and production release. The
complete native integration script is running against that same immutable941-blob
checkpoint, independent of the client test. Logs:
`.local/periodic-live-{full-tests,production,full-native}.log`. The client tester
uses a whole25-file clone of the stopped source/receipt51 dataset at
`/tmp/valimc-periodic-live-client-20261016`; root owns server shutdown after testing.

Actual26.3 client PASS, tester report reviewed once:
`.local/client-tests/VMC-037d/report.md`. Actual drinks demonstrate regeneration
four+1HP/50tick events and expiry, poison25tick damage/floor/expiry, lethal
wither40tick damage/native translated death and actual Respawn. Two actual
regeneration drinks demonstrate stronger-head1250ms healing then weaker-head
2500ms promotion. Actual canceled poison and unsupported Night Vision remain
intact. Actual geared poison/wither bypass Fire Resistance, retain Protection
reduction and no armor wear; creative/spectator negatives use labeled fixtures.
Fresh reconnect preserves finite state/health/bottle without offline advancement
or replay. Exact intervals use read-only traces with scheduling tolerance;
infinite/high-amplifier/zero boundaries remain native/deterministic proofs.

Death52 and subsequent pickup53 are retained, source/receipt53 and outboxnil.
Final20HP/regen534ticks, seven bottles and retained canceled/unsupported potions.
Both owned client JVMs stopped, zero players/connections, five region flushes and
clock:ok. Primary reviewed the server session: no gameplay errors; server stopped
cleanly. Full native completion remains the only block integration gate.
