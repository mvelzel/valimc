# VMC-033d — Durable crafting output drops

Status: Done
Note: Done within single-record crafting-drop scope. October 16, 2026; `88416e9`.
Parent: VMC-033.

Acceptance: native partial-result shift overflow and a single result Q drop
consume ingredients and create exact output through a validated recipe conversion.
The leased player writer commits the resulting inventory and exact output record
before destination delivery; retry/restart reuse that record and receipt.
Ordinary item conservation must continue rejecting ingredient-to-output changes.
Validate the action, complete before/after snapshot, output stack and destination.
One bounded record per admitted action; keep existing journal/request formats.
Bulk Ctrl-Q remains separate until its bounded delivery semantics are implemented.

Reference: pinned 26.3 actual `InventoryMenu`/`ResultSlot` contexts from VMC-033c;
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
matches 9,466 contexts, including 2,968 exact drop plans across all 476 recipes:
partial shift, signed single-throw buttons, creative/survival and carried-cursor
exclusion. Prior 3,536 manual-menu cases still pass. Canonical native integration
uses that combined gesture probe once. Logs `.local/player-crafting-drops-`
`{native,check,manual-check,affected-tests}.log`.

Boundaries include ordinary-conservation rejection, forged ingredients/output/
metadata/positions/gestures, source bounds and stale writer fences. Real source
and destination restarts retain an exact receipt even after the dropped entity
is removed; retry creates nothing and source clears once. Actual TCP partial
shift moves 2 into planks 62→64 and drops 2, then Q consumes the final log and drops 4;
reconnect retains source 2/nil outbox and exactly those records. The initial TCP
test read an earlier correction snapshot; it now waits for the authoritative
completion packet instead of assuming synchronous disk delivery. Runtime was
unchanged for that test correction. Accepted block/client evidence follows.

Frozen production passed; all 914 full tests pass (seed77307) on `88416e9`.
Full native integration passes, including actual Mojang TCP plaintext 05:18:45
and continuous AES-CFB8 05:18:55. All 693 source blobs remained exact through
integration (`.local/crafting-block-source-proof.json`); raw full logs
`.local/crafting-block-full-{tests,native}.log`. This completes the player crafting
block within its stated scope; table/special recipes, recipe book and bulk Q remain.

October 16 actual-client evidence: Java26.3/protocol777 on frozen checkpoint
`88416e955d5bbb9fdad1a96f6ae456813202667b`; all 693 source blobs and loaded
Inventory/PlayerCraftingTransfers production BEAM identities verified. Dedicated
SDL pointer Shift-result with full storage except planks 62 PASS: planks 64,
log2→1, derived result 4/raw result0nil, exact droppedplanks 2/receipt59. Carried
bedrock 64 resultQ negative PASS without ingredient/output/counter change; empty
cursor singleQ PASS: final log consumed, result cleared, exact droppedplanks 4,
source 60/niloutbox/receipt60. Close/reopen and fresh direct reconnect PASS with
exact inventory and no duplicate output. Wooden dropped models rendered; old
coincident items prevent visual counting, so exact 2+4 comes from authoritative
records. CtrlQ and full item physics remain outside this gate. Both owned JVMs
stopped; zero players; original full player snapshot restored except latest
source 60/niloutbox, all 57 prior records and other receipts exact plus the two
legitimate outputs. Server unchanged. Logs only expected offline authentication
and renderer/version warnings. Detailed actions/checks/limits and ignored raw
evidence `.local/client-tests/VMC-033d/report.md`; primary reviewed and accepted
the graphical results. This single-record drop slice is complete.
