# VMC-033d — Durable crafting output drops

Status: In progress. October 16, 2026. Parent: VMC-033.

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
