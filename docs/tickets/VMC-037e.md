# VMC-037e — Resistance damage reduction

Status: Native foundation `b6c6fca` and owned damage/consumption composition
verified locally. Production/native TCP and actual-client gates remain; keep local.

Acceptance: Resistance reduces eligible damage after armor and before worn
enchantments, using the active amplifier and native exclusions. Preserve damage
cooldown, armor wear, health/death, effect expiry/promotion/removal and reconnect.
Keep computation on the existing player owner; no effect timer or shared owner.

Client: actual supported Resistance potion/drink, ordinary damage before/during/
after expiry, higher amplifier and worn Protection composition, source negatives,
milk removal and fresh reconnect. Fixtures may prepare status/damage conditions;
actual drink/acquisition, hearts and removal remain CUA evidence.

Pinned26.3: `LivingEntity.getDamageAfterMagicAbsorb`, `MobEffects.RESISTANCE`,
`DamageTypeTags.BYPASSES_EFFECTS/BYPASSES_RESISTANCE` and existing armor/enchantment
probes. Native float32 multiply then divide is observable; do not algebraically
reorder it. Private reference `.local/gravity-LivingEntity.javap`.
Native overflow/statistics and downstream composition need explicit scope.

October16: original `ResistanceOracle` invokes actual native magic reduction with
real effect maps and independently bound native damage tags, skipping worn
enchantments through a controlled non-server context.135,150 cases cover all51
sources,256 amplifiers, absent/zero/finite/infinite effects, subnormals, float32
rounding and overflow. `PlayerResistance` matches every finite result exactly.
The528 native positive-infinite results saturate to maximum finite float32 for
bounded owner health arithmetic; this retains lethal magnitude for implemented
health/Protection ranges. It is an explicit representation choice, not native
bit equality for infinity. Amplifier4+ yields zero eligible damage; source bypass
tags still take precedence. Hidden rungs cannot influence the active head.
Ten affected checks pass(seed81913). Evidence:
`.local/resistance-{native,native-check,targeted}.log`. No statistics, worn-gear
composition, live damage/clock ordering or actual-client result is claimed.
After removing new signed-zero test-pattern warnings, the two changed kernel
checks pass(seed739183); the full135,150 native comparison passes again with an
explicit module load before existing-atom lookup. Final evidence:
`.local/resistance-{targeted,native-check}-final.log`.

Owned composition: Resistance is now admitted through grant/login and custom
PotionContents drinking. Damage applies armor/wear, then Resistance, then worn
Protection; maximum-level mitigation still advances ordinary cooldown/wear.
Environmental burning/air/freezing retain only tick-start Resistance in one
bounded immutable owner field. Expiry or a later grant cannot change an already
admitted base step; delayed geometry consumes the latest policy without replay.
Direct contacts/falls use current owned state. Periodic effects use the documented
ID order, so Resistance expiry/promotion precedes poison/wither actions. Respawn
clears environmental policy. No new timer/process, mailbox lane or global owner.

Native composed proofs pass116,320 cases:33,120 armored campfire/cactus/berry,
62,400 fall/freeze/drown/void/starvation and20,800 magic/wither contexts, all43
enchantments/slot negatives/caps, real effect map and ResistanceII. Finite results
match exactly; native infinity uses the documented lethal bounded representation.
Armor callback order/exhaustion match. Evidence:
`.local/resistance-geared-{hazards,environment,periodic}-{native,check}.log`.

106 affected checks pass(seed710443): resisted health with ordinary armor wear/
cooldown, burning/air expiry, late grant versus admitted drowning, periodic hidden
promotion/expiry, atomic custom drink/bottle and damaged reconnect. Turtle Master
remains refused as a whole because its Slowness behavior is not implemented; the
new Resistance admission never partially applies that potion. Evidence:
`.local/resistance-live-targeted-final.log`. Baseline82 owner checks also pass;
the first added-test compile attempt had a helper arity error, fixed before tests.
Full combat, statistics/other attributes and complete Turtle Master stay open.

Frozen `d9e1b8a` passes1,321 full tests and a production release, plus both native
plaintext/continuous AES-CFB8 TCP integrations. Logs:
`.local/resistance-live-{full-tests,production,native-tcp}.log`.
Actual-client validation owns that immutable951-blob release and whole source/
receipt53 dataset `/tmp/valimc-resistance-live-client-20261016`. The client gate
remains pending; full native integration of the preceding block passed at5b123b1.
