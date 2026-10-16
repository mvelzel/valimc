# VMC-033g — Crafting remainders

Status: Implemented; client/coherent integration pending. October16,2026.
Parent: VMC-033; uses VMC-033h.

Acceptance: cake, honey block and bottled-honey sugar select their native recipes,
consume exact inputs and return correct buckets/bottles in player/table menus.
Match native remainder placement/merge, selected/offhand storage preference,
component handling, output gestures and overflow. Exact conversion journals must
authorize every result gesture that can now emit remainders, with no loss or
duplication on close/disconnect/restart. Preserve the five-record transfer limit;
define bounded continuation for repeated shifts exceeding one batch.

Native research first: actual26.3 `ResultSlot`, `CraftingRecipe`, `Inventory.add`
and both menus. Cover count1/stacked/patched ingredients, empty/partial/full storage,
cursor/number/offhand/result-Q/shift, wrong/full cursors, repeated operations and
both creative permissions. Existing3×3 classification excludes exactly these three
remainder recipes. Reference jar SHA1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`.

Actual client plan: craft bottled sugar in the player grid and honey block/cake in
the table; observe residual inputs, buckets/bottles, outputs, full-storage overflow
and reconnect with exact source/destination accounting. Frozen releases stay
unchanged throughout validation.

Private original probe `.local/RemainderMenuProbe.java` reuses actual native menu/
`ResultSlot` dispatch with controlled world construction/stats. It observed1,960
traces across the three recipes, both grids where fitting, both creative abilities,
counts1/2/16/99 (legal max-stack patches), seven storage layouts and seven result
actions. Raw `.local/remainder-menu-native.{json,log}`; isolated compiled classes.
The prototype serializer omits max-stack patches; retain them in the public probe
before claiming full component comparison.

Observed: count1 containers return fresh plain bucket/bottle stacks into consumed
grid cells. Stacked containers leave their patched residual input in the grid and
insert fresh remainders into player storage, preferring matching selected/offhand
stacks. Full survival storage drops remainders; creative `Inventory.add` discards
overflow, unlike close cleanup. Result-Q emits remainder drops before the output
(four bottles then honey block =five records). Repeated shifts can emit256 records
in one native gesture, proving that bounded continuation is necessary. Do not
widen transfer limits or reuse connected-close insertion rules without comparison.
Implementation: three additional indexed profiles (1,183 table/478 player recipes)
and two verified remainder templates. Result pickup/swap plans now carry ordered
remainder effects; empty output targets are filled before remainder insertion.
Each conversion uses existing exact source authorization and at most five records.
Bulk/shift continuation can stop at fewer than five records when the next whole
craft cannot fit; a final drop-free craft still updates the owner. Ordinary gesture
APIs refuse plans needing external delivery. No generic transfer limit increased.

Original `RemainderCraftingOracle` now retains effective max-stack/glint/damage and
exports the three recipe profiles/two plain one-item templates from the pinned API.
All2,240 actual menu traces match bounded plans: both fitting grids/permissions,
counts1/2/16/99, seven layouts, selected/offhand merges, all result gestures and
ordered overflow. Published facts `priv/crafting/remainders.json`; classes include
`CraftingRecipe`, `ItemStackTemplate`, `ResultSlot`, `InventoryMenu`/`CraftingMenu`.
Existing3,392 ordinary bulk traces still pass. Raw
`.local/remainder-crafting-{native.json,native.log,catalog.json,check.log}` and
`.local/remainder-ordinary-bulk-regression.log`.

68 affected tests passed (seed934998), including cake buckets/patches, both-mode
overflow, output-before-remainder swap, non-five-record boundaries, exact/forged
journals and live TCP pickup/offhand/bulk/shift/close/reconnect. Raw
`.local/remainder-final-targeted.log`. Formatting/Python syntax pass. The combined
bulk/remainder block still needs frozen full tests/native integration/production
and dedicated GUI scenarios; no client/Done claim yet.
