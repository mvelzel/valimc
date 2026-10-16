# VMC-037e — Resistance damage reduction

Status: Native reduction foundation verified locally; no live grant/drink support.
Owner/gear composition and actual-client gates remain; keep it unpushed.

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
