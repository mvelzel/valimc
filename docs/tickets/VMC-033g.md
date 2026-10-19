# VMC-033g — Crafting remainders

Status: Done
Note: Done within ordinary manual remainder-recipe scope. October 16,2026. Runtime `c06b4bd`; test expectation repair `265b151`.
Parent: VMC-033; uses VMC-033h.

Acceptance: cake, honey block and bottled-honey sugar select their native recipes,
consume exact inputs and return correct buckets/bottles in player/table menus.
Match native remainder placement/merge, selected/offhand storage preference,
component handling, output gestures and overflow. Exact conversion journals must
authorize every result gesture that can now emit remainders, with no loss or
duplication on close/disconnect/restart. Preserve the five-record transfer limit;
define bounded continuation for repeated shifts exceeding one batch.

Native research first: actual 26.3 `ResultSlot`, `CraftingRecipe`, `Inventory.add`
and both menus. Cover count 1/stacked/patched ingredients, empty/partial/full storage,
cursor/number/offhand/result-Q/shift, wrong/full cursors, repeated operations and
both creative permissions. Existing 3×3 classification excludes exactly these three
remainder recipes. Reference jar SHA1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`.

Actual client plan: craft bottled sugar in the player grid and honey block/cake in
the table; observe residual inputs, buckets/bottles, outputs, full-storage overflow
and reconnect with exact source/destination accounting. Frozen releases stay
unchanged throughout validation.

Private original probe `.local/RemainderMenuProbe.java` reuses actual native menu/
`ResultSlot` dispatch with controlled world construction/stats. It observed 1,960
traces across the three recipes, both grids where fitting, both creative abilities,
counts 1/2/16/99 (legal max-stack patches), seven storage layouts and seven result
actions. Raw `.local/remainder-menu-native.{json,log}`; isolated compiled classes.
The prototype serializer omits max-stack patches; retain them in the public probe
before claiming full component comparison.

Observed: count 1 containers return fresh plain bucket/bottle stacks into consumed
grid cells. Stacked containers leave their patched residual input in the grid and
insert fresh remainders into player storage, preferring matching selected/offhand
stacks. Full survival storage drops remainders; creative `Inventory.add` discards
overflow, unlike close cleanup. Result-Q emits remainder drops before the output
(four bottles then honey block =five records). Repeated shifts can emit 256 records
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
All 2,240 actual menu traces match bounded plans: both fitting grids/permissions,
counts 1/2/16/99, seven layouts, selected/offhand merges, all result gestures and
ordered overflow. Published facts `priv/crafting/remainders.json`; classes include
`CraftingRecipe`, `ItemStackTemplate`, `ResultSlot`, `InventoryMenu`/`CraftingMenu`.
Existing 3,392 ordinary bulk traces still pass. Raw
`.local/remainder-crafting-{native.json,native.log,catalog.json,check.log}` and
`.local/remainder-ordinary-bulk-regression.log`.

68 affected tests passed (seed934998), including cake buckets/patches, both-mode
overflow, output-before-remainder swap, non-five-record boundaries, exact/forged
journals and live TCP pickup/offhand/bulk/shift/close/reconnect. Raw
`.local/remainder-final-targeted.log`. Formatting/Python syntax pass. Coherent
block results follow.

First frozen full suite:969/970 passed; a keyboard-drop test still expected a
pending close to be ignored. Updated it to verify deferred return, unchanged
offhand/selection, exact single drop and fresh reconnect;15 affected checks pass
(seed654680). This test-only follow-up leaves the frozen `c06b4bd` runtime/native
scripts unchanged. Original failed log retained.

Frozen full rerun passes 970 tests (seed443449); production and all five dedicated
GUI scenarios pass. Full native integration passed its pure/codec/menu probes,
then its TCP close scenario waited for a second unsolicited duplicate inventory
response after already observing the correct closed menu and five peer drops.
The unified deferred-close path emits one final response. Removed only that extra
wait; retain cleared menu/partial merge/exact overflow checks and send a real
repeated close before expecting another response. Complete targeted plaintext and
continuous AES-CFB8 TCP reruns pass against the unchanged frozen runtime. Native
integration is validated by the complete probe prefix plus both corrected TCP
scenarios; the original failed run is retained. Raw
`.local/crafting-remainders-{final-full-tests,full-native,production}.log`,
`.local/remainder-tcp-integration-02.log`.

Five actual-client scenarios passed on frozen `c06b4bd`: player bottled sugar with
patched residual input/plain bottle; cake with three returned buckets; survival
full-storage offhand output/four overflow bottles; six-craft Shift continuation
over five four-record journals and final physical bottles; creative overflow
discard followed by physical close cleanup. All used actual gestures and fresh
reconnects (ten launches). Exact snapshots/ledgers corroborate client observations.
Report `.local/client-tests/VMC-033g/report.md`; both 727-blob snapshots rehashed,
unchanged-runtime proof/evidence hashes `.local/remainders-proof.json`.

Fresh whole dataset `/tmp/valimc-remainders-client-20261016` starts at zero with
prior datasets preserved. Restored original snapshot/396 scene cells except latest
sequence 9/nil; retained all 37 committed records (28 bottles/eight honey/one block),
receipt 9, no pending work and no test JVMs. Fresh-world near-camera item planes
reproduced only after drops; stepping away showed recognizable sprites. This
separate presentation/physics observation remains VMC-018c3. Recipe book, special
component outputs and broader crafting/container behavior remain open.
