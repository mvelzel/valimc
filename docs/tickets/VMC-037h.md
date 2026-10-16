# VMC-037h — Hunger status effect

Status: Native request foundation verified locally; owned integration/client gate
remain. Live Hunger remains refused at this checkpoint.

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
