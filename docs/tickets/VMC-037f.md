# VMC-037f — Speed and Slowness

Status: Native foundation `742a37e`, live composition `285d983`. Targeted/native
TCP/production and all focused actual-client groups pass. Larger-block native
integration remains running; keep this block local until it passes.

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

Owned composition: admit Speed/Slowness grants, saved state and complete stock
potions, including all Turtle Master variants. Publish movement-speed attributes
at join/respawn, actual consumption/removal, active amplifier changes and sprint
transitions. A two-head/sprint signature suppresses ordinary duration-only updates;
derive on changes, without persisting a second attribute authority or adding timers.
The existing server retains observed horizontal displacement; current fluid input
has no movement-speed-dependent Depth Strider acceleration. Full authoritative
ground acceleration and gear/custom movement modifiers remain follow-ups.

63 affected checks pass(seed340665): actual TCP drinking, modifier packets/sprint,
quiet countdown, hidden promotion/expiry, milk removal, complete Turtle Master
SlownessIV/ResistanceIII plus reduced fall, bottle and fresh reconnect. The old
unsupported mixed-potion negative now uses Resistance+Night Vision. Initial tests
attempted the second drink while the first atomic save was pending; waiting for
that acknowledged checkpoint fixes the fixture rather than changing admission.
Evidence: `.local/movement-effects-live-targeted-fixed.log`.

Frozen `285d983` production and both native TCP transports pass, including actual
Mojang-decoded movement attribute initialization, sprint composition/removal.
Evidence: `.local/movement-effects-live-{production,native-tcp}.log`. Dedicated
actual-client validation uses this immutable956-blob release and whole retained
source/receipt53 dataset `/tmp/valimc-movement-effects-live-client-20261016`.
The actual-client gate passes as recorded below.

Actual26.3 PASS; primary reviewed `.local/client-tests/VMC-037f/report.md` once.
Matched2000ms held-W gestures show normal8.63–9.06blocks, SpeedI11.13, SpeedII12.39,
SlownessIV3.62 and promoted SlownessI7.52. These are indicative actual actions,
not tick-accurate benchmark ratios. Actual stronger/weak drinks promote and expire;
milk clears both heads and restores normal walking. Actual long Turtle Master
shows both SlownessIV/ResistanceIII, slower walking and a real walked-off fall
reduced3→1.2HP damage, without armor/healing or synthetic damage calls. Both-hand
cancel/full drinks, Speed+Slowness, practical sprint and unsupported mixed
Speed+Night Vision refusal pass. Fresh Quick Play reconnect retains finite SpeedII,
one offhand bottle and changed walking; two offline snapshots23.534s apart retain
829ticks exactly. Final genuine expiry restores normal walking.

All three JVMs stopped; zero players/connections, four regions+clock flush:ok.
Primary server log review found no gameplay errors; server73547 stopped exit0.
Final whole dataset retains15.8HP, empty effects, one offhand bottle, food10,
source/receipt53 and outboxnil. Cleanup: `.local/movement-effects-live-cleanup.log`.
No claim for complete ground authority/custom gear/Depth Strider or every stock
variant. Larger-block `cc3dfa5` passes1,330 full tests/build; native integration is
still running independently.
