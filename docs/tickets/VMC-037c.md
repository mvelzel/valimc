# VMC-037c — Breathing effects and air ownership

Status: Done
Note: **Done within owned Water Breathing/air scope**, `1fd6287`, published October 16. Automated integration/build and all six actual-client groups pass.

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

Pinned 26.3: `LivingEntity.baseTick`, `MobEffectUtil.hasWaterBreathing` and
`shouldEffectsRefillAirsupply`. Native air work precedes effect expiry. Water
Breathing, Conduit Power and Breath of the Nautilus all prevent oxygen loss;
Nautilus alone suppresses underwater refill. Water Breathing/Conduit override that
hold. Native invulnerable underwater players also refill air unless Nautilus alone
prevents it; the previous five-argument air primitive held instead. Conduit
range/actions and Nautilus mounting remain separate gameplay systems. Private references:
`.local/status-air-MobEffectUtil.javap`, `.local/gravity-LivingEntity.javap`.

October 16: original `StatusAirOracle` invokes both native predicates on the actual
`LivingEntity` effect map.433 contexts cover every 40 catalog entries, zero/one/
finite/infinite/maximum durations, amplifier 0/255 and all eight combinations of
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
Breathing refills four air up to 300; Nautilus-only hold remains a pure future context.
Creative/spectator depleted underwater air now refills, matching native baseTick.
Respiration draws occur only when air can be spent. No extra timer/process/job.

60 affected tests pass(seed956482), including one-tick expiry/refill, natural
drowning after expiry, Fire Resistance negative, stalled geometry/latest policy,
grant-after-admission ordering, depleted air/effect reconnect, creative/spectator
recovery and actual TCP Water Breathing consumption/effect/bottle checkpoint.
Evidence: `.local/status-air-live-targeted.log` and
`.local/status-air-native-check-final.log`(433 native predicates/policies). Native
full-baseTick execution is not claimed; its ordering/refill rules use the pinned
bytecode and the existing native air primitives. Actual-client evidence follows.

Frozen `1fd6287` passes 1,284 full tests(seed105045), production release and native
plaintext/continuous AES-CFB8 TCP. Raw evidence: `.local/breathing-live-full-tests.log`,
`.local/breathing-live-production.log`, `.local/breathing-live-native-tcp.log`.
The full native suite last passed at `d7e688c`; subsequent potion/breathing native
probes and both transports are targeted integration, not a repeat of that entire suite.
The dedicated client tester tested the immutable release and whole consistent dataset
`/tmp/valimc-breathing-live-client-20261016` (initial source/receipt50).

Actual 26.3 client PASS: main/offhand ground-targeted drinking/bottles, actual
submersion with owned+4 depleted-air refill, genuine 400-tick expiry into natural
oxygen loss/drowning20→12HP, separate actual surfacing/recovery, Fire Resistance
negative, creative/spectator refill, canceled use, unsupported Night Vision and
fresh finite/bottle/depleted-air reconnect without offline catchup or replay.
Initial air depletion/modes are trusted fixtures; exact login air before connected
refill and stalled geometry are deterministic evidence, not GUI observations.
Tester report reviewed once: `.local/client-tests/VMC-037c/report.md`; run logs
remain under the frozen checkpoint's ignored client evidence directory.

A tester pool-setup mistake caused ordinary magma death before the successful
breathing trials. Normal respawn/transfers were retained; it is not breathing
failure evidence. Whole dataset advances source/receipt50→51, outboxnil. Final
survival8HP/air300/finite8648ticks/one offhand bottle, safe pool shore. Both owned
JVMs stopped; zero players/connections, seven regions and clock flush:ok, server
cleanly stopped. `.local/breathing-publication-proof.json` binds immutable source
blobs and all accepted reports/checks. Conduit/Nautilus actions, broader effects,
fluid propagation and full-server parity remain separate work.
