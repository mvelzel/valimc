# VMC-036c — Consumable item use

Status: Native facts/food codecs verified; live use in progress. October 16, 2026.
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

Client scenario: eat from both hands; visible use animation, stack reduction and
food recovery; full-food negative and always-edible positive; interrupt mid-use,
change held stack, reconnect and test a container remainder with a full inventory.
Delegate on a frozen release after earlier gates; report unsupported effects honestly.
