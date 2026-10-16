# VMC-033c — Player crafting result gestures

Status: Automated-verified; actual client pending. October 16, 2026.
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

Reference: pinned26.3 `InventoryMenu.quickMoveStack`,
`AbstractContainerMenu` result gestures and `ResultSlot.onTake`; exact jar revision
in VMC-033a. Add actual native menu contexts for dense inventories, patches,
both modes, repeated inputs, changed-result recipes and hotbar/offhand boundaries.
Client scenario: actual shift crafts multiple log inputs into reverse storage;
number/offhand keys craft once; full/overflow refusal
leaves all inputs/output unchanged. Dedicated tester owns GUI verification.
The vanilla creative inventory has no2×2 crafting view, so positive player-grid
clone is a native/TCP boundary check; do not invent a graphical positive claim.

Implemented bounded repeated shift into44..9, stopping when the result identity
changes, plus one-recipe empty-hotbar/offhand swap and permission-gated result
clone. Nonempty swap targets leave the entire grid untouched. Shift with partial
capacity refuses the whole immutable plan; fully full storage simply stops.
No global owner or recipe process; result remains derived.

The actual native menu harness covers all476 admitted recipe profiles, both
modes, cursor presence, counts through64, dense/patch-sensitive storage and
changed-result recipes. All3,642 drop-free contexts match;112 native partial-drop
contexts are explicitly refused pending VMC-033d. The initial amount99 log
fixture exceeded its legitimate64 stack limit and was removed; no runtime
exception handling was added for impossible owned stacks. Native serialization
now also records world drops; both checkers reject malformed case rows instead
of silently filtering them. Prior3,536 manual-menu contexts remain required.

86 affected tests pass (seed953502), including live shift/swap/correction packets,
partial-plan rollback, exact reverse storage, changed-recipe stop and clone
permission. Logs `.local/player-crafting-gestures-{native,check,tests}.log` and
`.local/player-crafting-menu-{native,check}.log`. Actual client gate remains open;
this ticket is the drop-free gesture slice, not completed result-drop support.
The eight focused result/TCP tests also pass (seed141568), including positive
clone and revoked-permission correction with exact ingredients retained.
