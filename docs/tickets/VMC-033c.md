# VMC-033c — Player crafting result gestures

Status: Done
Note: Done within drop-free gesture scope. October 16, 2026; `b3060b6`.
Parent: VMC-033; builds on VMC-033b.

Acceptance: native-verified result shift, hotbar/offhand swap and creative clone
plans use the derived result, consume the correct ingredients and honor storage
order/identity/capacity. Bound repeated crafting by owned ingredient counts.
Result cloning uses creative permission and leaves ingredients unchanged.

First live composition may admit only plans without world drops; explicitly
refuse overflow atomically until recipe-conversion transfers are implemented.
Vanilla shift can consume ingredients after moving a partial result and drop its
remainder. Result swap requires an empty target, even for matching items;
ordinary conservation cannot authorize
such conversions. Preserve exact source intents/destination receipts for the
follow-up, including result Q/Ctrl-Q behavior. Never label this whole family done
while that boundary remains open.

Reference: pinned 26.3 `InventoryMenu.quickMoveStack`,
`AbstractContainerMenu` result gestures and `ResultSlot.onTake`; exact jar revision
in VMC-033a. Add actual native menu contexts for dense inventories, patches,
both modes, repeated inputs, changed-result recipes and hotbar/offhand boundaries.
Client scenario: actual shift crafts multiple log inputs into reverse storage;
number/offhand keys craft once; full/overflow refusal
leaves all inputs/output unchanged. Dedicated tester owns GUI verification.
The vanilla creative inventory has no 2×2 crafting view, so positive player-grid
clone is a native/TCP boundary check; do not invent a graphical positive claim.

Implemented bounded repeated shift into 44..9, stopping when the result identity
changes, plus one-recipe empty-hotbar/offhand swap and permission-gated result
clone. Nonempty swap targets leave the entire grid untouched. Shift with partial
capacity refuses the whole immutable plan; fully full storage simply stops.
No global owner or recipe process; result remains derived.

The actual native menu harness covers all 476 admitted recipe profiles, both
modes, cursor presence, counts through 64, dense/patch-sensitive storage and
changed-result recipes. All 3,642 drop-free contexts match;112 native partial-drop
contexts are explicitly refused pending VMC-033d. The initial amount 99 log
fixture exceeded its legitimate 64 stack limit and was removed; no runtime
exception handling was added for impossible owned stacks. Native serialization
now also records world drops; both checkers reject malformed case rows instead
of silently filtering them. Prior 3,536 manual-menu contexts remain required.

86 affected tests pass (seed953502), including live shift/swap/correction packets,
partial-plan rollback, exact reverse storage, changed-recipe stop and clone
permission. Logs `.local/player-crafting-gestures-{native,check,tests}.log` and
`.local/player-crafting-menu-{native,check}.log`. Accepted client evidence follows;
this ticket is the drop-free gesture slice, not completed result-drop support.
The eight focused result/TCP tests also pass (seed141568), including positive
clone and revoked-permission correction with exact ingredients retained.

October 16 actual Java26.3/protocol777 verification on frozen checkpoint
`5a004e64b76042f17c07ba564a28ca7b5e30c590`: dedicated SDL tester reports
PASS for Shift log17→planks 64 in 44 plus 4 in 43; number 9 single craft,
occupied matching hotbar target no-op and F single craft to offhand;
partial-capacity Shift refusal preserves log2/planks62/storage/cursor exactly;
close and fresh direct reconnect preserve storage and clear derived result.
All 689 checkpoint blobs and loaded production Inventory BEAM/cwd/PID checked.
Four fresh direct QuickPlay clients stopped via their tracked wrappers and JVM
absence checked. Full snapshot restored except latest source 58/nil outbox;
all 56 old item records retained exact, legitimate close-cleanup log2 record
and region 0 receipt 58 retained, all other receipts exact. Raw detailed report,
action/RPC logs and full snapshot/item evidence are ignored under
`.local/client-tests/VMC-033c/`. Optional entirely full capacity was not separately
exercised. No graphical creative-clone claim or result-drop support claim;
VMC-033d remains a separate boundary. Primary reviewed and accepted this report;
the drop-free gesture slice is complete.
