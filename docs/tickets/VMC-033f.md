# VMC-033f — Owned crafting-table menu

Status: Native menu/storage contracts in progress. October 16, 2026.
Parent: VMC-033; uses VMC-033e.

Acceptance: place/use a crafting table, open its unmodified-client3×3 menu and
craft ordinary recipes with correct slot mapping, container IDs and result
gestures. Each player owns their transient nine inputs; the table block has no
shared inventory or process. Validate reach/block identity through authoritative
ownership. Closing, removal, relocation, disconnect and restart cannot duplicate
or lose inputs/output. Keep derived output out of snapshots/conservation.

Native references: pinned26.3 `CraftingMenu`, `CraftingTableBlock`, menu packet
codecs, `ResultSlot` and connected/disconnected cleanup. Probe mapping, both
hands/secondary-use precedence, reach/close and actual return/overflow behavior
before composition. Actual client scenario: place/open table, craft a mixed-wood
pickaxe and nine-cell concrete powder, shift/number/Q, close/reopen and reconnect;
wrong/full cursor and removed/out-of-range table refuse or close correctly.

Ownership work first: separate table inputs from the physical player slots and
map menu addresses at the protocol boundary. Extend snapshot/cleanup accounting
explicitly; do not silently put extra stacks outside `Inventory.contents`.
The [owned input/cleanup foundation](VMC-033f1.md) is the first checkpoint.
Then implement [table click plans](VMC-033f2.md) before live block/menu ownership.
The [table block slice](VMC-033f3.md) admits verified placement/mining first.
Table close can overflow nine inputs plus a cursor, beyond the five-record
transfer batch. Define bounded continuation/recovery before enabling that path;
do not widen generic transfer budgets or hide transient stacks from persistence.
The implementation order is editable; split storage/menu/block-use slices where
useful. Special/remainder recipes, recipe book and bulk Q remain separate.

Native layout probe passed46 actual `CraftingMenu` slots: result0, inputs1..9,
player storage10..36→inventory9..35, hotbar37..45→inventory0..8. Armor/offhand
are not displayed. Native menu type12; open packet round-trip with container17
and `container.crafting` title consumed all bytes. Private original probe/facts:
`.local/TableMenuLayout.java`, `.local/table-menu-layout.{json,log}`. It suppresses
recipe callbacks for layout inspection, so claims no reach/close/click behavior.
