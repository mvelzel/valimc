# VMC-036c — Consumable item use

Status: Live plain-food use automated-verified; graphical gate pending. October 16, 2026.
Depends on owned food, hand/inventory authority and the admitted player clock.

Acceptance: unmodified-client use starts the native held-item animation and
finishes after its component-defined duration. Apply nutrition/saturation,
consume the correct hand stack and return bowls/bottles without loss or duplication.
Honor full-food/always-eat/creative rules. Release, hand/stack changes, death and
disconnect retire the attempt. Stale ticks/results cannot finish it twice.
Persist food and inventory together; delayed writes must retain later owner ticks
and recover one result. Keep use state transient, local and bounded; no new timer.

First checkpoint: native default food/consumable/remainder facts and component
codecs, then live plain-food use with interruption and durability boundaries.
Expand native effects, specialized consumables and gameplay events with their
owners; this ticket does not replace VMC-037's full effects work. Sprint eligibility
and mining/combat exhaustion remain other survival follow-ups.

Pinned 26.3 jar SHA1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`FoodProperties`, `Consumable.startConsuming/canConsume/onConsume/consumeTicks`,
`UseRemainder.convertIntoRemainder`, player/living active-use callbacks. Private
`.local/{FoodProperties,Consumable,UseRemainder}.javap`. Native duration truncates
float32 seconds×20; food eligibility delegates to `Player.canEat`; completion
notifies component listeners/effects before consuming one item. Creative abilities
and remainder conversion require their own actual native observations.

Foundation: original `ItemFoodOracle` extracts 50 stock consumable records,
including 44 foods, durations, remainders and additional component listeners.
It verifies 60 bidirectional food-patched stacks in ordinary/delimited formats,
64 actual `Consumable.canConsume` gates, eight duration boundaries and twelve
actual remainder conversions. Specialized effects/listeners remain explicit;
honey/potions/suspicious stew cannot silently become plain food. Raw evidence:
`.local/item-food-{native,check,verify}.log`, `.local/item-food-{facts,cases}.json`.

The food component now has a bounded codec and effective default identity;
44 new default identity values preserve existing item data. Native equality
passes 18,474 raw-patch cases; 49 affected tests pass, including malformed food,
signed-zero identity, component removal/override and journal round trips. The
expanded native meal matrix passes 315 cases, including maximum-nutrition int
overflow. Logs `.local/food-stack-identity-{native,check}.log`,
`.local/item-food-affected-tests.log`, `.local/item-meal-{native,check}.log`.
This foundation does not start eating or complete the graphical gate.

Active-use foundation: 30 native request codecs, 28 living-flag codecs, four
completion-event codecs and 32 actual `LivingEntity.updatingUsingItem` prefixes
match the bounded request decoder and transient owner timer. The native probe
controls completion/stop callbacks and excludes world effects. Same item type
refreshes the active stack even if count/components change. A changed main-hand
selection and hand swap explicitly stop use; off-hand use survives selection.
Native stop clears the active bit but retains the off-hand bit. Four affected
tests pass. Evidence `.local/item-use-{native,check,verify,tests}.log`; source
`LivingEntity.startUsingItem/stopUsingItem`, `ServerPlayer.completeUsingItem`,
`ServerGamePacketListenerImpl.handleSetCarriedItem/handlePlayerAction`.

Live checkpoint: existing admitted player ticks advance one transient use counter.
Requests acknowledge native sequences and wrapped angles; loading, spectator,
full-food and active-use gates apply. Both hands publish living-use flags. Completion
sends native event9 before the authoritative inventory, uses the latest same-type
stack's food properties, and checkpoints food/inventory together. No new owner,
task or periodic timer is added. A busy writer defers completion; consumption acknowledgements
never overwrite subsequent food ticks. Inventory transfers wait for that checkpoint.
Release, main-hand selection, swaps, changed item types, death and reconnect cancel.
Final soup replaces the held stack with its bowl even with full storage; creative
keeps the consumed item without another bowl. Patched container extras can merge
into storage. World overflow rejects the whole meal pending a conversion outbox.

Thirty-eight affected tests pass, including eleven real TCP scenarios covering
native duration/repeated requests/stale ticks, both hands, cancellation, current
components, eligibility, creative, full storage, atomic reconnect, blocked saves,
deferred completion, death and unsupported effects/overflow. Evidence:
`.local/live-item-use-{compile,affected-tests}.log`. Full block checks/build and
actual-client verification remain pending. Specialized effects/listeners, world
overflow, [peer equipment's client gate](VMC-018d.md), use slowing, sounds/particles, vibration
and statistics are follow-ups; this is not full consumable or survival parity.

Block verification: 762 full tests pass (seed327342), after correcting two peer
recreation assertions to include the new living-use metadata; the focused peer
regressions pass15 tests. Frozen `7d715999757747bee2fd644a7b0d5a52d9be7dac`
has589 verified blobs in `.local/consumable-validation-checkpoint` and a successful
production build. Full native integration finished successfully on that frozen
tree, including both plaintext/encrypted TCP sessions. Equipment's subsequent
767-test/build/native-TCP block is recorded in [VMC-018d](VMC-018d.md).
Logs `.local/consumable-block-full-tests-final.log`,
`.local/item-use-peer-regressions.log`, `.local/consumable-validation-production.log`,
`.local/consumable-validation-full-native.log`.

Client scenario: eat from both hands; visible use animation, stack reduction and
food recovery; full-food negative and always-edible positive; interrupt mid-use,
change held stack, reconnect and test a container remainder with a full inventory.
Delegate on a frozen release after earlier gates; report unsupported effects honestly.
