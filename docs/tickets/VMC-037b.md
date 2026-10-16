# VMC-037b — Potion contents and delivery

Status: Component/delivery kernel verified locally; graphical baseline pending.
No live potion consumption yet.

Acceptance: bounded native potion contents, effective stack identity and duration
scaling preserve stock/custom values through both stack formats and journals.
Then compose supported drinking on the player clock: effects, consumed stack and
bottle remainder commit atomically. Refuse effects with unimplemented gameplay.
No process or timer per potion/effect. Splash, lingering, arrows, brewing, instant
actions and the remaining effect behaviors are separate slices.

Client: inspect stock/custom potion names and tooltips, move/save/reconnect stacks;
then drink Fire Resistance in both hands, check animation/timing, bottle, duration,
actual immunity/expiry, interruption, creative handling and reconnect. Native-only
component work uses baseline smoke until the live slice exercises drinking.

Pinned26.3: `PotionContents.STREAM_CODEC/forEachEffect/onConsume`,
`MobEffectInstance.STREAM_CODEC/Details/equals/withScaledDuration`, `Potion` built-in
registry and `Consumable`. Original `PotionOracle` records46 potion holders, four
default components,481 dual-format stacks and4,329 scaled deliveries. Raw custom
effects may contain noncanonical hidden chains; delivery copies only the head.
Equality ignores those hidden chains, while raw codecs/persistence preserve them.
Native duration scaling uses float32 multiplication, `Math.floor` and saturating
integer conversion; negative non-infinite durations clamp to one tick.
Private evidence: `.local/potion-{facts,cases}.json`, `.local/potion-native.log` and
`.local/potions-*.javap`. No periodic/instant action or live consumption proof yet.

October16: bounded original Elixir codecs preserve stock/custom values in ordinary
and delimited stacks and existing journals. Limits:64 custom entries,256 total
rungs,32,767 UTF-8 name bytes and the existing65,536-byte stack limit. Unlike owned
effect state, raw hidden chains need not have decreasing amplifiers. Identity
compares head values; delivery drops hidden values and preserves base/custom order.
New potion patches on food explicitly retain their specialized listener, preventing
plain meals from silently discarding unsupported effects.

44 affected checks pass(seed483742): exact raw journal storage, semantic stacking,
default/removal identity, float32 extrema and malformed count/ID/chain/name limits.
All481 stacks match native bytes and independent Mojang decoding in both formats;
all4,329 scaled deliveries and18,578 raw-patch identity pairs match. Four native
default components were regenerated; other item facts/defaults are unchanged.
Evidence: `.local/potion-{native,native-check,native-decode,identity-native,
identity-check,defaults-native,targeted-final}.log`. Current scale API admits only
nonnegative finite float32 inputs; a duration-scale item component is not supported.
