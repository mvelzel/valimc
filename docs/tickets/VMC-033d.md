# VMC-033d — Durable crafting output drops

Status: Automated-verified; actual client pending. October 16, 2026.
Parent: VMC-033.

Acceptance: native partial-result shift overflow and a single result Q drop
consume ingredients and create exact output through a validated recipe conversion.
The leased player writer commits the resulting inventory and exact output record
before destination delivery; retry/restart reuse that record and receipt.
Ordinary item conservation must continue rejecting ingredient-to-output changes.
Validate the action, complete before/after snapshot, output stack and destination.
One bounded record per admitted action; keep existing journal/request formats.
Bulk Ctrl-Q remains separate until its bounded delivery semantics are implemented.

Reference: pinned26.3 actual `InventoryMenu`/`ResultSlot` contexts from VMC-033c;
extend the native probe for single result throws, cursor exclusions and other
signed buttons. Verify native pure plans, forged/stale source refusals, exact
source/destination retry/restart and real TCP owner sequencing. Actual tester
uses a full inventory with partial result capacity, then result Q, verifies exact
consumption/dropped output and fresh reconnect. No GUI gate substitution.

Implemented exact partial shift and one-recipe result throw plans. The leased
writer re-evaluates the requested gesture, checks the entire resulting snapshot,
single stack, source drop position and destination key before committing the
existing inventory/outbox format. Ordinary conservation is unchanged. Delivery,
fences, replay and source clearing reuse the existing bounded transfer lane;
no new global gameplay owner. Direct non-effect `Inventory.click` refuses a
plan requiring world delivery. Ctrl-Q remains explicitly unsupported.

140 affected tests pass (seed183000). Native actual `InventoryMenu`/`ResultSlot`
matches9,466 contexts, including2,968 exact drop plans across all476 recipes:
partial shift, signed single-throw buttons, creative/survival and carried-cursor
exclusion. Prior3,536 manual-menu cases still pass. Canonical native integration
uses that combined gesture probe once. Logs `.local/player-crafting-drops-`
`{native,check,manual-check,affected-tests}.log`.

Boundaries include ordinary-conservation rejection, forged ingredients/output/
metadata/positions/gestures, source bounds and stale writer fences. Real source
and destination restarts retain an exact receipt even after the dropped entity
is removed; retry creates nothing and source clears once. Actual TCP partial
shift moves2 into planks62→64 and drops2, then Q consumes the final log and drops4;
reconnect retains source2/nil outbox and exactly those records. The initial TCP
test read an earlier correction snapshot; it now waits for the authoritative
completion packet instead of assuming synchronous disk delivery. Runtime was
unchanged for that test correction. Production/full block and GUI gates follow.
