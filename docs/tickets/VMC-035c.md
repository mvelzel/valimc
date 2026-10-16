# VMC-035c — Item pickup

Status: In progress. Durable owner/writer composition is local; automatic collection
and the graphical gate remain open.

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

Withdrawal-plan checkpoint: canonical≤131,164-byte requests pin source/sequence,
permit, item UUID/generation and exact before/remainder stacks. Pure region plans
retain typed applied/rejected receipts with item removal/replacement; retries work
after codec restoration, including competing players and a superseded birth.
26 affected checks pass(seed905945), `.local/pickup-withdrawal-targeted.log`.
No live permits or durable runtime composition yet.

Player intent checkpoint: v16 snapshots retain original inventory plus canonical
withdrawal and a digest of physical slots/cursor/table/selection/material permission.
Transient menu revisions/drag do not affect persistence. Applied receipt proof
grants the recomputed exact amount and clears the intent together; rejection
clears without gain. The source writer must fetch proof from the owning region,
never trust a delivery reply alone.42 affected checks pass(seed572787),
`.local/player-pickup-intent-targeted.log`: table wrappers, creative overflow,
partial false callbacks, source mutations, counterfeit/stale receipts, legacy
placement/mining/drop snapshots and no second grant. Runtime activation follows.

Admission must reserve receipt capacity for new source UUIDs through terminal
commit, including rejection; other transfer kinds must respect those reservations.
Otherwise a filled receipt table could strand a persisted player intent.

Receipt-capacity foundation: a new player's slot can be durably reserved using
sequence0/digest0 in the existing bounded receipt layout. It acknowledges no
positive transfer, never replaces an existing high-water mark, and survives writer/
owner recovery. Normal transfers count the slot and can advance it to terminal
proof even when all4096 slots are occupied. Other zero-sequence digests remain
invalid; positive legacy bytes remain unchanged.30 affected checks pass
(seed684312), `.local/pickup-receipt-reservation-targeted.log`, including actual
critical write/kill/reload/first-delivery. Live admission must persist the slot
before issuing its expiring contact permit; that composition remains open.

Leased writer checkpoint: prepare saves original inventory/v16 intent; completion
fetches terminal proof from the real owning region before saving gain+clear.36
affected checks pass(seed26220), `.local/player-pickup-store-targeted.log`: stale
leases, pending writes, source restart, rejection/forged proof and failed final
save/reopen. Recovery fixtures write a complete pure region commit after the
source intent and before lazy region load; they do not exercise live admission.
No world item is restored after a failed recipient save. Contact permits, live
inbox/delivery, disconnect composition and automatic collection remain open.

Contact/permit checkpoint: pinned26.3 `Player.aiStep` expands an unmounted body
by(1,0.5,1); `ItemEntity.playerTouch` checks delay/target before insertion. The pure
query matches5,832 actual native AABB boundaries, including adjacent doubles near
world edges. `.local/item-pickup-contact-native{.json,.log,-check.log}`.19 affected
checks pass(seed806605), `.local/pickup-permits-targeted.log`. Grants require an
already committed receipt slot, one per source,≤128 per owner,250ms lifetime.
Consumption rechecks owned position, exact stack, generation, delay and contact;
counter-only revisions do not invalidate contact. These are inactive kernels;
region admission/withdrawal/delivery and the automatic player lane follow. Mounted
pickup and persistent exclusive targets remain outside this initial composition.

Live inbox checkpoint (October16): region admission fsyncs receipt capacity before
issuing contact permission. A bounded off-owner plan freezes competing item changes
until withdrawal/remainder plus typed receipt is durable; only then is it published.
Source completion fetches that proof. Delivery and disconnect use the same protocol.
Material permission is latched with the original insertion plan, so a later mode
change cannot dispose of a survival remainder or strand a creative overflow intent.
62 affected checks pass(seed352045), `.local/pickup-inbox-checkpoint-targeted.log`: actual
admission/writer pauses, expiry, partial conservation, competing players, owner
restart before/after withdrawal, source reopen and disconnect with a mode change.
Automatic player discovery/collection, replication callbacks and GUI checks follow.

Automatic collection checkpoint: each player rotates nearby visible candidates,
with one bounded I/O query and no idle jobs in empty scenes. Publications carry
position/delay hints only; the region rechecks current authority. Accepted pose,
mode, health, loading, teleport and inventory lanes fence returned grants. The
leased writer assigns the source sequence and retains original inventory until
proof. Unusable grants release without consuming receipt history. Whole pickup
publishes the native callback after commit; partial false callbacks do not animate.
73 affected checks pass(seed476133), `.local/pickup-auto-checkpoint-targeted.log`:
real TCP whole/partial/full/creative, delay, spectator/range, adjacent-owner contact,
late-grant movement, fair discovery, two-player races and fresh login; mining/use/
table regressions also pass. Broader integration/build and actual Minecraft follow.

Integration follow-up: production release passed for frozen `79811a8` (805 blobs).
The first broad run passed1,122/1,123; the sole failure expected an unchanged delay
hint in the item-age test. Correcting that assertion retains exact packet/version
checks; the full retest passes1,123(seed489962),
`.local/item-pickup-full-tests-retest.log`.14 additional affected checks pass
(seed618829), `.local/pickup-pressure-targeted.log`: source-write expiry/retry,
disconnect during queued preparation, fresh login and saturated I/O responsiveness.
No runtime change was needed. Full native integration and graphical checks continue.

`bench/item_pickup.exs` exercises actual leased source saves, region capacity/
withdrawal, delivery and authoritative proof across4/32 sources and1/8 owners,
with64/512 entities and plain/4KiB components. Both runs conserve all items. Run01
observed721–1,349 pickups/s and1.6–24.6ms median; run02, during full-suite/native/
client load, observed76–145/s and37–244ms median, including42 safely rejected and
retried expired permits. These are trusted-contact durable-I/O measurements;
TCP/graphics/physics and cross-server comparisons are excluded. Raw workloads,
results, revision/hash/load notes and complete datasets:
`.local/item-pickup-bench-{01.log,02.log,manifest.json}` and the logged `/tmp` paths.
