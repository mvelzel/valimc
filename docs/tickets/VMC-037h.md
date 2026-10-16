# VMC-037h — Hunger status effect

Status: **Done within owned Hunger-drink scope**, runtime `085ac9f`. Native,
77 affected checks, production/both native TCP transports and all five actual
client groups pass. Newer Saturation work remains separate.

Acceptance: active Hunger heads request native float exhaustion each admitted
player tick, before ordinary food processing. Preserve mode/ability immunity,
duration/hidden promotion, milk removal, atomic drinks and reconnect. Derive from
the existing player-owned status/food state, without another timer or owner.

First slice: actual native Hunger callbacks/food exhaustion over all256 amplifiers,
ability modes and exhaustion boundaries. Prove the coefficient and float ordering
before live admission. Player-owned food spending already has separate proofs;
the new callback must compose with its strict exhaustion threshold and cap.

Client: actual custom Hunger drink shows its icon and exhausts food while stationary;
milk stops it, hidden promotion/expiry changes the rate, creative remains unaffected,
and fresh reconnect retains the accepted timed head/food without extra consumption.
Use fixtures for food/effect preparation, actual use and elapsed admitted ticks for
the effect. Native probes cannot replace the graphical gate.

Reference: pinned26.3 `HungerMobEffect`, `MobEffectInstance`,
`Player.causeFoodExhaustion`, `FoodData.addExhaustion/tick`, existing player effect
clock and food owner. Poison/wither/regeneration remain completed dependencies.
Random consumable chances, mobs and remaining food/status mechanics are follow-ups.

October16: original `HungerEffectOracle` executes10,240 actual Hunger callbacks
into real Player/FoodData over all256 amplifiers, four modes, both invulnerability
values and five exhaustion boundaries. The promoted float0.005 coefficient,
float multiplication/addition and40 exhaustion cap match exactly. The ability
flag gates exhaustion independently of mode labels; creative/spectator normally
have that flag. Another150 actual MobEffectInstance ticks cover finite/infinite/
zero durations and signed-age boundaries, matching pre-decrement request timing.
First probe compile used nonexistent FoodData accessors; fixed with controlled
reflection on the real exhaustion field before observations.

`HungerEffect` derives one pure active-head request and uses existing bounded
status semantics.12 affected checks pass(seed949148), including promotion, zero
duration, high amplifier without wrapping, cap composition and malformed rungs.
Raw `.local/hunger-effect-{native-final,elixir-final,targeted}.log`; source data
in `.local/hunger-effect-{native,timing-native}.json`. Food spending and live
ownership are not established by this request foundation.

Owned composition uses the existing admitted player clock, pre-decrement effect
heads and food state. Hunger requests join ordered status callbacks before food
processing, with ability invulnerability gating exhaustion; no timer/process or
second food authority. Timed admission, grants, drinks/milk and saved reconnect
share existing status/consumption paths. Pinned Player.tick calls Avatar.tick
before ServerPlayer.doTick processes FoodData; private `.local/speed-Player.javap`
and `.local/food-ServerPlayer.javap` record that ordering.

11,520 actual native Hunger→FoodData.tick compositions cover thresholds/caps,
four difficulties, regeneration/starvation requests, saturation/timer and amplifier
boundaries.77 affected checks pass(seed594201): actual TCP drinking, first exhaustion
crossing before food spending, milk stop, hidden promotion/expiry, invulnerability
ability immunity and reconnect with exact food/duration/one bottle. Raw:
`.local/hunger-food-{native,elixir}.log`, `.local/hunger-live-targeted-final.log`.
The first owner fixtures mistakenly used numeric17 (Weakness); native indexed
Hunger is16. Fixtures now use EffectTypes.id("hunger"); a remaining stale index
was corrected before the passing run. Runtime admission already used the lookup.

Native catalog clarification: Night Vision is15, Hunger16 and Weakness17. Earlier
client handoffs calling16 Night Vision were mislabeled; their negatives establish
refusal of then-unsupported16, not a Night Vision GUI proof. Retain those original
reports. The next client negative must look up actual night_vision15. Automated
older mixed negatives already used that named lookup. Do not require Hunger16 to
remain refused once this feature is admitted.

Actual26.3/protocol777 PASS on frozen085ac9f; primary reviewed the dedicated
`.local/client-tests/VMC-037h/report.md` once. Actual cancellation retained potion;
full amp19 drink showed Hunger/brown food and stationary loss20→17 over121 ticks.
Actual milk removed the active head; food/exhaustion stayed exact for62 ticks.
Actual weak200→strong100 drinks gave two bottles; observed strong99/hidden150,
strong2/hidden53, then promoted weak51, with exhaustion slope0.1→0.005 per tick
and genuine expiry. Creative retained its exact drink while the head ticked,
without food/exhaustion change. Mixed Hunger16+actual NightVision15 stayed wholly
refused. Fresh direct reconnect retained saved head407 with no offline mutation
and later head68 after339 admitted ticks, one bottle and no replay.

Both client wrappers/JVMs stopped; zero connections/players, four regions+clock
flush:ok, server87371 exit0 without gameplay errors. All983 frozen blobs match.
Final whole dataset `/tmp/valimc-hunger-live-client-20261016` retains18HP, food20/
saturation0/exhaustion3.0000212193, empty effects, survival, one bottle and bucket,
source60/outboxnil and receipt60. Distant historical records were not rewritten.
Fixtures prepared food/effects/items and mode; uses, elapsed transitions and
reconnect were actual. Final milk followed expiry; active removal was proven
separately. These are admitted-tick observations, not performance measurements.
Proof/raw: `.local/hunger-publication-proof.json`, `.local/hunger-live-cleanup.log`,
`.local/hunger-live-{production,native-tcp}.log`, tester trace and launch evidence.
