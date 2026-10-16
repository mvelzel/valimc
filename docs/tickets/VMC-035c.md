# VMC-035c — Item pickup

Status: In progress; same-owner merging retains its separate client gate.

Acceptance: eligible nearby world items enter the authoritative player inventory
with native slot priority, component identity, partial capacity and creative
overflow behavior. Delay/target/mode/range negatives refuse. Concurrent players,
disconnects, source/destination crashes and retries conserve items and durable
receipts. Inventory observations cannot authorize a world withdrawal.

Start with pure insertion and actual pinned26.3 `Inventory.add(ItemStack)` and
`ItemEntity.playerTouch` callbacks; reference bytecode stays ignored at
`.local/inventory-pickup-bytecode.txt` and `.local/item-entity-bytecode.txt`.
An insertion may mutate inventory/world remainder even when its native callback
returns false; verify that independently from pickup animation/stat callbacks.
Build leased, recoverable region→player consumption only after these plans match.

Client scenario: actual walk into a naturally dropped stack after delay, inventory
gain and entity removal/partial remainder, full and incompatible negatives,
simultaneous-player contention and fresh reconnect/recovery. Dedicated tester owns
the verdict. Kernel checks do not complete the live or graphical gate.

Insertion checkpoint: `Inventory.pickup_stack/2` preserves all other inventory
ownership and returns the exact remainder separately from the callback boolean.
24 affected checks pass(seed298116), `.local/item-pickup-inventory-targeted.log`.
384 actual native insertion/callback/remainder observations pass across slot
priorities, full/partial capacities, damage, names, effective defaults, custom99
and both material permissions. Raw `.local/item-pickup-native{.json,.log,-check.log}`
stays ignored; isolated Java output avoids concurrent integration compilation.
No live pickup authority or graphical pickup claim yet; checkpoint stays local.

Next authority protocol: persist a player intent with its original inventory before
requesting region withdrawal. The region commits item removal/partial replacement
and a typed terminal receipt atomically. Only matching applied proof lets the
player add inventory and clear its intent atomically; rejection clears without
gain. Reuse the player's monotone sequence/receipt lane. A bounded expiring region
permit fences the item UUID/generation/stack, accepted contact and source player.
Recovery first checks the receipt; an expired/missing permit may reject only when
withdrawal was not committed. Never grant inventory from a published item view.
