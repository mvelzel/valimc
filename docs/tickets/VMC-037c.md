# VMC-037c — Breathing effects and air ownership

Status: Predicate/owned composition verified locally; broader integration/build
and actual-client validation pending. Keep this slice local.

Acceptance: Water Breathing pauses oxygen loss and restores depleted air while
submerged, with expiry, existing defenses, natural drowning, drinks and reconnect.
Keep effects/air on the player owner and existing clock. Delayed geometry must
sample fresh eyes without replaying clocks or applying later effect state to an
earlier air step. Other supported breathing contexts must preserve their native
distinctions; catalog entries alone do not implement all their gameplay.

Client: drink Water Breathing, enter actual eye-deep water, check air/health,
expire into natural oxygen loss/drowning, surface, reconnect with depleted air and
effects. Include Fire Resistance's non-breathing negative and invulnerable air
recovery. Trusted fixtures are distinct from actual drinking/movement/UI evidence.

Pinned26.3: `LivingEntity.baseTick`, `MobEffectUtil.hasWaterBreathing` and
`shouldEffectsRefillAirsupply`. Native air work precedes effect expiry. Water
Breathing, Conduit Power and Breath of the Nautilus all prevent oxygen loss;
Nautilus alone suppresses underwater refill. Water Breathing/Conduit override that
hold. Native invulnerable underwater players also refill air unless Nautilus alone
prevents it; the previous five-argument air primitive held instead. Conduit
range/actions and Nautilus mounting remain separate gameplay systems. Private references:
`.local/status-air-MobEffectUtil.javap`, `.local/gravity-LivingEntity.javap`.

October16: original `StatusAirOracle` invokes both native predicates on the actual
`LivingEntity` effect map.433 contexts cover every40 catalog entries, zero/one/
finite/infinite/maximum durations, amplifier0/255 and all eight combinations of
the three relevant effects. `PlayerAirEffects` matches both predicates. Presence
includes zero-duration entries until the effect clock removes them. Eight affected
tests pass(seed838560), including that expiry/removal/refill boundary. Evidence:
`.local/status-air-{native,native-check,targeted}.log`. This probe does not execute
`baseTick`, mutate air or prove other actions/attributes/world ordering. Owned
composition and its remaining gates follow.

Owned composition: grants, login restoration and supported potion delivery now
admit Water Breathing alongside Fire Resistance. The owner captures a compact air
policy at the start of each admitted tick, before effect expiry. Existing fenced
eye geometry consumes only the latest pending air step; later grants cannot
retroactively change that step, and delayed samples do not replay expired policies.
Breathing refills four air up to300; Nautilus-only hold remains a pure future context.
Creative/spectator depleted underwater air now refills, matching native baseTick.
Respiration draws occur only when air can be spent. No extra timer/process/job.

60 affected tests pass(seed956482), including one-tick expiry/refill, natural
drowning after expiry, Fire Resistance negative, stalled geometry/latest policy,
grant-after-admission ordering, depleted air/effect reconnect, creative/spectator
recovery and actual TCP Water Breathing consumption/effect/bottle checkpoint.
Evidence: `.local/status-air-live-targeted.log` and
`.local/status-air-native-check-final.log`(433 native predicates/policies). Native
full-baseTick execution is not claimed; its ordering/refill rules use the pinned
bytecode and the existing native air primitives. GUI drinking/submersion/expiry/
drowning, finite reconnect and relevant negatives remain required before Done.
