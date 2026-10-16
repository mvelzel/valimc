# VMC-036d — Milk and honey effect removal

Status: Native foundation `51fe9be` and owned consumption verified locally.
Production/native TCP and actual-client gates remain; keep this slice unpushed.

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
milk/honey use/removal/containers/negatives/reconnect remain before acceptance.
