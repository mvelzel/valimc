# VMC-037b — Potion contents and delivery

Status: Done
Note: **Done within contents/delivery and supported Fire Resistance drinking scope**, accepted at `fa0b320`. Other effect behaviors/brewing/projectiles remain.

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

Pinned 26.3: `PotionContents.STREAM_CODEC/forEachEffect/onConsume`,
`MobEffectInstance.STREAM_CODEC/Details/equals/withScaledDuration`, `Potion` built-in
registry and `Consumable`. Original `PotionOracle` records 46 potion holders, four
default components,481 dual-format stacks and 4,329 scaled deliveries. Raw custom
effects may contain noncanonical hidden chains; delivery copies only the head.
Equality ignores those hidden chains, while raw codecs/persistence preserve them.
Native duration scaling uses float32 multiplication, `Math.floor` and saturating
integer conversion; negative non-infinite durations clamp to one tick.
Private evidence: `.local/potion-{facts,cases}.json`, `.local/potion-native.log` and
`.local/potions-*.javap`. No periodic/instant action or live consumption proof yet.

October 16: bounded original Elixir codecs preserve stock/custom values in ordinary
and delimited stacks and existing journals. Limits:64 custom entries,256 total
rungs,32,767 UTF-8 name bytes and the existing 65,536-byte stack limit. Unlike owned
effect state, raw hidden chains need not have decreasing amplifiers. Identity
compares head values; delivery drops hidden values and preserves base/custom order.
New potion patches on food explicitly retain their specialized listener, preventing
plain meals from silently discarding unsupported effects.

44 affected checks pass(seed483742): exact raw journal storage, semantic stacking,
default/removal identity, float32 extrema and malformed count/ID/chain/name limits.
All 481 stacks match native bytes and independent Mojang decoding in both formats;
all 4,329 scaled deliveries and 18,578 raw-patch identity pairs match. Four native
default components were regenerated; other item facts/defaults are unchanged.
Evidence: `.local/potion-{native,native-check,native-decode,identity-native,
identity-check,defaults-native,targeted-final}.log`. Current scale API admits only
nonnegative finite float32 inputs; a duration-scale item component is not supported.

Live composition uses the existing admitted 32-tick use clock. Plain/effectless
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

Frozen `82dd108` passes 1,276 full tests(seed106669), production and both native TCP
transports: `.local/potion-live-{full-tests,production,native-tcp}.log`. Full native
integration at earlier `d7e688c` also passes, including plaintext/continuous AES-CFB8;
new potion-specific probes above and82dd TCP checks cover the additions separately.

October 16 dedicated actual-client report reviewed:
`.local/client-tests/VMC-037b/report.md`. **PASS** native stock/long/custom tooltips,
actual inventory moves/raw-content reconnect, cancellation, main/offhand drinks,
bottles/nutrition, actual magma immunity, genuine 400-tick expiry followed by natural
damage/wear, unsupported Water Breathing refusal, creative retention and saved
finite-effect/bottle reconnect. Effectless potion display/storage passed; its drink
was not separately checked. Custom potion name is a native translation suffix.
Failed ground-target attempts caused a legitimate death and pickups; actual Respawn
passed, dataset retained(source 50/outboxnil), no expiry proof from those attempts.

**FAIL**: reachable ground targeting animated drinking but left the potion/effect
unchanged; aiming into air worked. A paired native-framed block-use/item-use TCP
regression reproduced the lost fallback. The fix retains that item-use frame in
the existing bounded receive buffer until the preceding asynchronous block
admission completes or its300ms deadline fires. Earlier chat/control traffic and
owner clocks stay responsive; clearing the admission resumes the drain. No new
queue/process/timer.53 affected use/table/placement checks pass(seed172851), including
unavailable-owner timeout and ordinary consumption. Evidence:
`.local/potion-block-use-{repro,targeted-final}.log`. Graphical ground-target retest
and native TCP/build acceptance follow below.

Final `fa0b320` production and both native TCP transports pass:
`.local/potion-block-use-{production,native-tcp}.log`. October 16 focused actual
client **PASS**: same ground targeting now supports cancellation, full custom/main
and long/offhand drinks, actual magma immunity then genuine finite expiry/damage/
wear, water/effectless drinks, bread, unsupported Water Breathing refusal and fresh
effect/bottle reconnect. The native 32→4-tick use prefix and 400-tick grant also appear
in owned observations. This closes the82dd failure without substituting air aim.
Reviewed dedicated report `.local/client-tests/VMC-037b-ground/report.md`; both
JVMs stopped, zero connections, regions/clock flushed and server stopped cleanly.
Source 50/outboxnil and region 0,0 receipt 50 remain equal; old drops aged naturally.
Saved 9030-tick effect and one offhand bottle remain in the disposable dataset.

Matched preview measurements,9f→fa 0: five-second static-water creative workloads,
identical load/server driver hashes,912/930 frozen source blobs checked before runs.
Native jobs, compilers, production servers and graphical clients were stopped.
Every sample passes with zero corrections/disconnects and verified final positions.
Raw workloads/results/manifests: `.local/potion-live-loads/`, driver
`.local/run_potion_loads.py`; original samples retained with the reverse dense pair.

| Layout | Baseline/candidate elapsed s | Baseline/candidate MiB | Baseline/candidate login p95 ms |
|---|---|---|---|
| Dense 128 |5.753/5.482|135.78/149.46|94.50/174.31|
| Spread 512 |5.107/5.101|311.85/315.73|78.50/80.45|
| Dense 128 reverse pair |5.283/6.314|142.17/137.60|75.92/85.23|

Dense login is slower in both samples, with varying magnitude; memory direction
reverses. Retain this profiling finding. These are sparse preview samples, not an
active-potion/hazard workload, survival capacity or cross-server speed comparison.
Earlier 512 worker-admission/host-load failures remain recorded in VMC-017b5; current
passes do not establish stable 512 capacity. No fastest-server or improvement claim.
