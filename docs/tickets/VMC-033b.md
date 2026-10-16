# VMC-033b — Manual player-grid crafting

Status: Done within manual recipe scope. October 16, 2026; `adfb228`.
Parent: VMC-033; uses [recipes](VMC-033a.md).

Acceptance: ordinary grid1..4 manipulations derive a result view and pickup0
takes one complete recipe output, consuming one from each occupied ingredient
cell atomically on the player owner. Both pickup buttons obey cursor identity/
capacity; creative crafting still consumes ingredients. Keep derived output out
of snapshots, physical conservation and close/disconnect/death drops. No global
crafting owner. Bound recipe matching, input work and encoded inventory size.

Pinned native `InventoryMenu`/`ResultSlot` probes in VMC-033a are the reference;
use that ticket's exact jar revision. Verify grid/result packets through real TCP,
wrong/full cursor, interruption, cleanup and reconnect. Dedicated actual tester
manually crafts logs→planks, mixed-plank sticks/table, inspects exact ingredients/
output, closes and reconnects. Recipe book, special recipes/items, remainders and
other result gestures remain explicit follow-ups.

Result0 is a derived display, never a physical inventory stack. Keep
`Inventory.contents` physical; only packet display includes the result. Ordinary
drop conservation cannot authorize recipe conversion: result throw needs a
trusted conversion plan plus exact durable records, and remains refused in this
slice. Result shift/swap/clone also remain refused until native-verified composition.

Implemented player-owned input pickup/swap/shift/drag, derived result packets and
one-recipe pickup with full cursor identity/capacity checks. Creative input edits
also replicate result0. Physical inventory/snapshots and ordinary transfer
conservation stay separate from the view; encoded menu limits include the view.
Grid armor shift returns to storage, not equipment. Existing item-specific click
overrides remain refused by the ordinary pickup path.

Pinned native `InventoryMenu.clicked`, `ResultSlot.onTake` and the actual crafting
container run in `PlayerCraftingOracle menu`; world construction, networking and
stats are controlled. All3,536 contexts match: survival/creative, both buttons,
cursor counts through each output limit, wrong/patched identity, repeat takes,
collection/result boundaries, input pickup/swap/shift/drag. Included in the next
full native block. Logs `.local/player-crafting-menu-{native,check}.log`.

113 affected tests pass (seed379348): recipe matching, physical/derived bounds,
cleanup/death/transfer conservation, snapshots, ordinary/creative inventory and
actual TCP survival clicks, result corrections/refusals, close and reconnect.
Two prior drag expectations now include the four crafting inputs. Initial test
fixture lacked survival abilities and referenced a nonexistent state field;
corrected fixtures, with no runtime change needed. Raw test log
`.local/player-crafting-live-tests.log`. Frozen production release passed;
accepted graphical crafting evidence follows.

Actual-client evidence, October16,2026: dedicated tester PASS on frozen
`adfb228760b570a424f4cc54ef967b37614ab29d` (all686 blobs verified), Java26.3/
protocol777, disposable whole cloned dataset, direct Quick Play and dedicated SDL
pointer. Survival manual clicks verified log2→planks8 (right pickup takes4 and
left pickup takes4), mixed oak/spruce sticks4 and table1 with exact ingredient
consumption, near-fulloak61 and wrongspruce cursor refusals, validtake4, close
with carried4/remaininglog1, fresh reconnect exactoak65/spruce1/log1 and empty
inputs/result/cursor. Live RPC confirmed physicalslot0nil throughout. Actual
`/stats`:1player/7regions/10schedulers/99MB; wrappers/JVMs stopped, zeroPlayers.
Full original snapshot restored retaining latest source57/niloutbox; all55 prior
item records exact, region1/2/3 receipts exact. A disconnected transient-grid
fixture underwent legitimate login cleanup: newoak_log2 record and region0
receipt57 retained; original receipt10 archived, no journal rollback. No block
fixtures changed. Raw report `.local/client-tests/VMC-033b/report.md`, numbered
observations, full before/final snapshots/ledgers and cleanup assertions. Server
log clean; client only offline auth/Realms and platform/render warnings. Limits:
survival player2x2 only; no creative GUI, recipebook/tablewindow/special/remainder/
itemoverride or unsupported result-gesture claim. Primary reviewed and accepted
the report; this manual slice is complete. VMC-033c owns additional gestures.
