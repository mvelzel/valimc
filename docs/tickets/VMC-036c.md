# VMC-036c — Consumable item use

Status: Next survival slice. October 16, 2026.
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

Client scenario: eat from both hands; visible use animation, stack reduction and
food recovery; full-food negative and always-edible positive; interrupt mid-use,
change held stack, reconnect and test a container remainder with a full inventory.
Delegate on a frozen release after earlier gates; report unsupported effects honestly.
