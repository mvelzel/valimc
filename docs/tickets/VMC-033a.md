# VMC-033a — Player crafting recipe foundation

Status: Automated-verified; baseline client smoke pending. October 16, 2026.
Parent: VMC-033.

Acceptance: pinned ordinary shaped/shapeless recipes that fit a2×2 player grid
have bounded immutable ingredient/result facts and native-verified matching,
including tag alternatives, translation, mirroring and mixed ingredients.
Classify remainders, special recipes and component-bearing outputs explicitly;
do not infer unsupported behavior. No process per recipe or runtime JSON parsing.

Reference: pinned26.3 `CraftingInput`, `Recipe.DIRECT_CODEC`, `RecipeManager`,
`ShapedRecipe`, `ShapelessRecipe`, `Ingredient` and player crafting/result slots;
jar SHA1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`. Private recipe examples and
signatures are `.local/recipe-*.json` and `.local/crafting-signatures.txt`.

Follow-up live composition must keep the result a derived view, never an owned
stack: current snapshots deliberately exclude slot0, and transfer conservation
counts physical inventory only. Keep grid1..4 owned by the player, apply result
take/ingredient consumption atomically, and retain existing close/disconnect/death
cleanup. Verify native result-menu gestures before enabling them; plain inventory
slots are not a sufficient oracle. Recipe-book synchronization remains separate.

Client scenario for this foundation is baseline smoke on its frozen checkpoint;
the live slice must use actual inventory clicks to craft logs→planks, mixed-plank
sticks/table, verify exact consumption/output and close/reconnect. Dedicated
tester owns those graphical checks. This ticket does not claim live crafting.

Isolated native prototype classifies1,202 ordinary recipes:496 fit2×2;
two need remainders (honey block/sugar from honey bottle),17 suspicious-stew
outputs have effect patches, leaving477 plain candidates. Real static-registry
pending tag lookups must replace construction-only tag placeholders before
reloadable recipes are decoded; the native recipe manager then matches oak logs
to planks4. Preserve shaped empty cells (eight across this catalog).

Actual global native selection on149,128 tag-alternative/mixed, translated,
mirrored, shapeless-permutation, extra/missing/wrong-cell and patched/count cases
exposes one shadowed ordinary recipe: `firework_rocket_simple` must remain
excluded while the native special `firework_rocket` behavior is unsupported.
After excluding that candidate, the indexed pure prototype matches all149,128
cases, leaving476 intended supported recipes (151 shaped/325 shapeless). Retain
the shadowed candidate's input grids as negative controls in the canonical oracle.
Raw sources/facts/cases,
isolated classes and comparison stay ignored under `.local/crafting-*` and
`.local/CraftingCandidates.java`.

Native `InventoryMenu`/`ResultSlot` probe (network/stat presentation controlled)
confirms both pickup buttons take the complete recipe output; insufficient cursor
capacity leaves ingredients untouched. Quick-move repeats to reverse storage
order; hotbar swap crafts once; throw0 drops one whole result and throw1 repeats.
`.local/crafting-menu-probe.log` retains the observed grid/cursor/result/drop states.
Result-drop preparation needs a validated recipe conversion, not ordinary item
conservation alone; retain bounded delivery batches and exact recovery semantics.
All477 candidate output items inherit base `Item.onCraftedBy` and
`onCraftedPostProcess` in the native probe; no output-specific hook was observed.

Implemented `Crafting2x2.result/1`: immutable rule tuple, count/ingredient index,
bounded shaped placements/mirrors and at most four-ingredient shapeless matching.
Normalized476-recipe facts are compiled once; runtime lookup owns no process or
RNG. The canonical native generator reproduces the facts and all149,128 actual
global selection/result cases pass the final API, including patched/count inputs
and unsupported-special negatives. Five targeted tests pass (seed771737): log
tags, mixed woods, translated/mirrored rules, shapeless order, special/remainder
exclusions and invalid grids. Python tool syntax checks pass; the new native
oracle/checker joins the next full integration block. Logs
`.local/player-crafting-{native,check,tests}.log`.

Next: frozen production build and dedicated baseline client smoke. This kernel
does not enable grid/result clicks yet; compose that in the next live slice.
