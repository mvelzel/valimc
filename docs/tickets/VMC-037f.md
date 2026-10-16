# VMC-037f — Speed and Slowness

Status: Native attribute foundation verified locally; no live support claimed.

Acceptance: native movement-speed modifiers and clamping, active amplifiers,
expiry/promotion/removal, sprint composition and reconnect. Send authoritative
attributes to the client and use the same owned values for applicable simulation.
Admit complete Turtle Master drinks only once Slowness and Resistance both work.
No new process, timer or shared attribute owner; derive from bounded player state.

Client: actual Speed/Slowness and Turtle Master drinks change walking as expected,
including cancellation, expiry, milk removal, simultaneous effects and reconnect.
Distinguish supplied modifiers from actual movement/terrain evidence.

Pinned26.3 references: `MobEffects` Speed/Slowness declarations,
`MobEffect.createModifiers/addAttributeModifiers/removeAttributeModifiers`,
`AttributeInstance.calculateValue`, `Player.createAttributes` and
`LivingEntity.SPEED_MODIFIER_SPRINTING`. Private bytecode:
`.local/speed-{MobEffects,MobEffect,AttributeInstance,AttributeMap,Player}.javap`.
Native coefficients are promoted float constants; player base is the promoted
float0.1 rather than the generic movement-speed attribute default0.7.

First slice proves modifier identity/operation/amplifier, player-base calculation,
clamp and removal through original native probes. Gear/custom attributes, powder
snow/Soul Speed modifiers and complete movement rules remain explicit follow-ups.

October16: original `MovementEffectOracle` executes actual stock callbacks and
native player AttributeMap evaluation/removal for132,098 Speed/Slowness amplifier
pairs (absent and all256 levels), with/without sprint. Modifier identities,
coefficients, operations, player base, clamped double and float travel speed match
exactly. Native evaluation orders are independently observed; the first comparison
found a one-ULP difference from multiplying sprint last. The pure implementation
now uses the measured three-identity order without copying native hash tables.
Seven affected checks pass, including hidden promotion, zero-duration ownership,
high-amplifier non-wrapping/clamp and malformed-map refusal. Raw evidence:
`.local/movement-effects-{native,native-check-final,targeted-final}.log`.
These prove the derived attribute only; live admission/packets/movement remain.
