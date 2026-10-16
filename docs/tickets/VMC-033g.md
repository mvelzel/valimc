# VMC-033g — Crafting remainders

Status: Native research. October16,2026. Parent: VMC-033.

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
No runtime change or client validation for this ticket yet.
