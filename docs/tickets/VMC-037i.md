# VMC-037i — Instant Saturation drinks

Status: Done
Note: Done within scope; validated and published at `7b65f32`.69 affected checks, 1,354 full tests, production, full native integration/both TCP transports and all five actual-client groups pass.

Acceptance: drinking Instant Saturation applies native food/saturation once, in
callback order with other potion effects, on the existing atomic consumption
snapshot. Correct container/creative/cancellation/reconnect, no timed instant icon
or replay. Hunger and ordinary food processing remain owned by the player.

First prove actual native PotionContents delivery into FoodData across all 256
amplifiers, starting food/saturation and modes/abilities. Duration scaling must not
silently alter instant strength. No assumption that food component saturation and
the status callback use the same legacy multiplier.

Client: actual custom Saturation drinks raise visible food; cancellation and
unsupported mixes retain state, both hands/creative follow native behavior, mixed
Hunger composes and fresh reconnect retains one accepted container/food change.
Native probes do not replace actual use. Normal food/chance/stew gameplay and
timed command-granted instant effects remain separately scoped follow-ups.

Reference: pinned 26.3 SaturationMobEffect, PotionContents.applyToLivingEntity,
InstantaneousMobEffect/MobEffect.applyInstantaneousEffect, FoodData.eat and
existing PlayerFood/PlayerConsumption. Keep raw jars/bytecode/fixtures ignored.

October 16 foundation: `SaturationDrinkOracle` drives actual PotionContents into
native FoodData. All 98,304 cases match Elixir:256 amplifiers, four food levels,
three saturation levels, both invulnerability flags, four durations and four
duration scales. Each callback adds amplifier+1 food and twice that absolute
saturation, capped by native food rules; duration/scaling and invulnerability do
not suppress it. Existing exhaustion/timer remain exact. Eleven affected tests
pass (seed345269). This proves callback delivery, not owner ticks or containers.
Raw results: ignored `.local/saturation-drinks-{native,elixir}-final.*`.

Live callbacks reuse PlayerConsumption's ordered transition and single final
snapshot; no new timer/process or persisted instant status. Both-hand actual TCP
tests cover cancellation, repeated callbacks at zero/infinite duration, one bottle
and fresh reconnect without replay. Creative amplifier 255 caps food/saturation
while retaining the drink. Mixed Hunger feeds once, then its next owned tick
spends saturation at the existing exhaustion threshold. Negative signed healing
refuses earlier Saturation and Resistance callbacks together. Raw:
`.local/saturation-live-targeted.log`. Graphical acceptance is recorded below.

Larger frozen `7b65f32` block:1,354 full tests(seed394458), production and native
plaintext/AES-CFB8 TCP pass; `.local/saturation-live-{full-tests,production,native-tcp}.log`.
Full native integration session 4900 runs against this immutable 986-blob release,
including Hunger/Saturation and the signed-healing guard, before new Absorption.

Actual 26.3/protocol777 PASS on frozen `7b65f32`; primary reviewed the dedicated
`.local/client-tests/VMC-037i/report.md` once. Actual500ms cancellation retains
the dose; full amp 2 drink visibly feeds 10→13, owner saturation 6, one bottle and
no timed icon/map. It stays exact for 157 admitted ticks. Actual offhand amp 255
caps food 20/saturation20 without wrapping; creative amp 2 feeds 10→13/saturation6
while retaining the exact dose. Mixed Hunger+Saturation feeds 10→14/saturation8,
then only Hunger persists and saturation falls to 5 after 142 admitted ticks,
without repeated feeding. Mixed actual NightVision 15 is refused whole. Actual
amp 0 drink feeds 10→11/saturation2; fresh direct reconnect retains 11/2, one bottle,
empty effects and no replay, with no post-acceptance food fixture. Health 18 stays.

Both wrappers/JVMs stopped, zero connections/players, four regions+clock flush:ok;
server 97442 exit 0 without gameplay errors.986 frozen blobs remain unchanged.
Whole dataset `/tmp/valimc-saturation-live-client-20261016` retains survival,18HP,
food 11/saturation2/exhaustion0, empty effects, bottle 36/milk37, source 60/outboxnil;
fixtures did not reset journals/counters/receipts or health. Saturation numbers
are corroborated by owner/saved state; use, food, container and icons were visual.
Milk after the mixed drink followed expiry, not a new removal proof. Raw evidence/
hashes: `.local/saturation-publication-proof.json`, `.local/saturation-live-cleanup.log`,
tester trace/fixtures and frozen launch directories. No performance claim.

Final immutable7b65f32 native integration exits 0 on October 16, including actual
plaintext and continuous AES-CFB8 TCP. Log/hash retained in the private publication
proof. Published directly to main; no remaining gate for this scoped slice.
