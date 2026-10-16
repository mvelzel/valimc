# VMC-036d — Milk and honey effect removal

Status: Done within stock milk/honey scope at `d71b2a9`. Targeted/native TCP/build
and actual-client checks pass, as does the larger parent native integration.

Acceptance: Milk removes all active/suppressed effects, honey removes poison
only. Use native durations, nutrition/eligibility, cancellation, both hands,
creative rules and containers. Commit effects/food/consumption/remainders together;
refuse overflow atomically until durable delivery supports it. No new timer or
shared gameplay owner. Missing effects are a successful ordinary consumption.

Client: actually drink milk while beneficial/harmful effects are present and
observe all icons/health actions stop with one bucket. Honey clears poison while
another supported effect persists, adds native nutrition and returns its bottle.
Check cancellation, empty effect state, creative/hand negatives and fresh reconnect.
Fixtures may seed effects/items; acquisition/removal still needs actual CUA use.

Pinned26.3: stock `DataComponents.CONSUMABLE`, `ConsumeEffect` removal callbacks,
`LivingEntity.removeEffect/removeAllEffects`, existing native consumption/remainder
facts. Private disassembly remains ignored under `.local/consume-*.javap`.
Do not generalize to all consumable effects, food listeners or random outcomes.

October16: original `ConsumableRemovalOracle` invokes stock consumable callbacks
through actual `LivingEntity` removal methods with controlled notification hooks.
658 maps/callback results match `ConsumableRemoval`: all40 effect identities,
empty/zero/finite/infinite/hidden state and dense maps. Milk has one clear-all
callback and32-tick use; honey has one poison-removal callback and40-tick use.
Pure admission accepts only their unchanged stock consumable/listener set;
overridden/missing callbacks and introduced potion listeners remain refused.
Eight affected tests pass(seed225739). Evidence:
`.local/consumable-removal-{native,native-check,targeted}.log`. The probe excludes
health/attributes, nutrition, consumption/counts, persistence and actual-client
behavior; those remain composition/GUI gates.

Owned completion now folds either potion additions or the explicit stock removal
policy into the same nutrition/effects/inventory/remainder checkpoint. Removal
packets follow native use-finished notification; no extra process/timer. Ordinary
milk/honey consume even when no effect matches. Creative removes effects while
retaining the held item; honey's excess bottle uses existing bounded inventory
insertion. Unhandled overflow refuses food/effect/count mutation together.

87 affected checks pass(seed666961): both hands,32/40tick completion, full storage,
hidden/unrelated removal, poison-only honey with nutrition and selected-hotbar
bottle insertion, cancellation, empty effects/full food, creative, introduced
listener refusal, and reconnect saves. A suspended milk writer cannot restore a
removed status or rewind a later grant. Evidence:
`.local/consumable-removal-live-targeted-final.log`. The first run exposed stale
unsupported-item/slot expectations, corrected to match the new support and native
inventory insertion. Production, both native TCP transports and actual CUA
milk/honey use/removal/containers/negatives/reconnect are recorded below.

Frozen `d71b2a9` production release and both native plaintext/continuous AES-CFB8
TCP transports pass. Logs: `.local/removal-live-{production,native-tcp}.log`.
The dedicated client tester owns the immutable946-blob release and whole consistent
source/receipt53 clone `/tmp/valimc-removal-live-client-20261016`. The larger parent
block's1,302 full tests and full native integration pass at `5b123b1`; this later
consumption increment has its own87 checks,658 native cases, build and both TCP transports.

Actual26.3 client PASS, report reviewed once:
`.local/client-tests/VMC-036d/report.md`. Actual mainhand cancellation/full milk
clears four statuses, offhand milk works with full storage, empty/full-food
consumption works, creative clears without consumption, honey clears active and
hidden poison while FR/WB persist and returns its extra bottle to the selected
hotbar. Actual full-storage honey refuses count/food/removal atomically; Night
Vision remains intact. Final actual milk+honey and fresh Quick Play reconnect
preserve empty effects, bucket36/honey1slot37/bottle38 and food11/saturation1.2.
Precise32/40tick boundaries use native/owner proofs; GUI uses actual full/canceled
holds. A rejected unordered poison fixture was corrected before the valid trial.

Source/receipt53, outboxnil retained; final1HP/air300. Both owned clients stopped,
zero players/connections, two region flushes and clock:ok. Primary server log
review found no gameplay errors; production server stopped cleanly. Raw client
logs remain under the frozen checkpoint. All stated gates pass; broader food
effects remain separate.
