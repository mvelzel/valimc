# VMC-037b — Potion contents and delivery

Status: Native/automated and actual air-targeted drinking pass. Ground-targeted
drinking failed in the client; ordering fix passes affected checks, retest pending.

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

Live composition uses the existing admitted32-tick use clock. Plain/effectless
drinks and Fire Resistance normal/long/custom contents are admitted; other effect
behaviors and specialized listeners refuse without consuming. Current completion
contents are rechecked, including potion patches on food. One checkpoint contains
nutrition, effects, consumed count and bottle remainder. Native packet order is
finish event, sequential add/refresh packets, then use/equipment/inventory updates.
Full-inventory single bottles replace the hand; unsupported patched-stack overflow
refuses the whole transition. Creative retains the item without a bottle.

91 affected checks pass(seed60920): real TCP timing/both hands, cancellation,
unsupported current contents, native hidden-copy/flag refresh/suppression/promotion,
creative/remainders/overflow, reconnect and stalled-save ordering, plus movement,
flight, inventory and death/respawn persistence regressions. Evidence:
`.local/potion-live-targeted-final.log`. The stalled-save case exposed a final-save
bug: cached player observations could retain older effect durations. Final saves
now capture current owner state; per-frame guards preserve earlier accepted input.
Active clocks continue during persistence and acknowledgement cannot rewind them.

Frozen `82dd108` passes1,276 full tests(seed106669), production and both native TCP
transports: `.local/potion-live-{full-tests,production,native-tcp}.log`. Full native
integration at earlier `d7e688c` also passes, including plaintext/continuous AES-CFB8;
new potion-specific probes above and82dd TCP checks cover the additions separately.

October16 dedicated actual-client report reviewed:
`.local/client-tests/VMC-037b/report.md`. **PASS** native stock/long/custom tooltips,
actual inventory moves/raw-content reconnect, cancellation, main/offhand drinks,
bottles/nutrition, actual magma immunity, genuine400-tick expiry followed by natural
damage/wear, unsupported Water Breathing refusal, creative retention and saved
finite-effect/bottle reconnect. Effectless potion display/storage passed; its drink
was not separately checked. Custom potion name is a native translation suffix.
Failed ground-target attempts caused a legitimate death and pickups; actual Respawn
passed, dataset retained(source50/outboxnil), no expiry proof from those attempts.

**FAIL**: reachable ground targeting animated drinking but left the potion/effect
unchanged; aiming into air worked. A paired native-framed block-use/item-use TCP
regression reproduced the lost fallback. The fix retains that item-use frame in
the existing bounded receive buffer until the preceding asynchronous block
admission completes or its300ms deadline fires. Earlier chat/control traffic and
owner clocks stay responsive; clearing the admission resumes the drain. No new
queue/process/timer.53 affected use/table/placement checks pass(seed172851), including
unavailable-owner timeout and ordinary consumption. Evidence:
`.local/potion-block-use-{repro,targeted-final}.log`. Graphical ground-target retest
and native TCP/build follow before publication.
