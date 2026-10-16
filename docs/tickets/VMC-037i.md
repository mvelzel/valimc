# VMC-037i — Instant Saturation drinks

Status: Native request foundation verified; live Saturation remains unsupported.

Acceptance: drinking Instant Saturation applies native food/saturation once, in
callback order with other potion effects, on the existing atomic consumption
snapshot. Correct container/creative/cancellation/reconnect, no timed instant icon
or replay. Hunger and ordinary food processing remain owned by the player.

First prove actual native PotionContents delivery into FoodData across all256
amplifiers, starting food/saturation and modes/abilities. Duration scaling must not
silently alter instant strength. No assumption that food component saturation and
the status callback use the same legacy multiplier.

Client: actual custom Saturation drinks raise visible food; cancellation and
unsupported mixes retain state, both hands/creative follow native behavior, mixed
Hunger composes and fresh reconnect retains one accepted container/food change.
Native probes do not replace actual use. Normal food/chance/stew gameplay and
timed command-granted instant effects remain separately scoped follow-ups.

Reference: pinned26.3 SaturationMobEffect, PotionContents.applyToLivingEntity,
InstantaneousMobEffect/MobEffect.applyInstantaneousEffect, FoodData.eat and
existing PlayerFood/PlayerConsumption. Keep raw jars/bytecode/fixtures ignored.

October16 foundation: `SaturationDrinkOracle` drives actual PotionContents into
native FoodData. All98,304 cases match Elixir:256 amplifiers, four food levels,
three saturation levels, both invulnerability flags, four durations and four
duration scales. Each callback adds amplifier+1 food and twice that absolute
saturation, capped by native food rules; duration/scaling and invulnerability do
not suppress it. Existing exhaustion/timer remain exact. Eleven affected tests
pass (seed345269). This proves callback delivery, not owner ticks or containers.
Raw results: ignored `.local/saturation-drinks-{native,elixir}-final.*`.
