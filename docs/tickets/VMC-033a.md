# VMC-033a — Player crafting recipe foundation

Status: Foundation
Note: Done within recipe-foundation scope. October 16, 2026; `6cd6800`.
Parent: VMC-033.

Acceptance: pinned ordinary shaped/shapeless recipes that fit a2×2 player grid
have bounded immutable ingredient/result facts and native-verified matching,
including tag alternatives, translation, mirroring and mixed ingredients.
Classify remainders, special recipes and component-bearing outputs explicitly;
do not infer unsupported behavior. No process per recipe or runtime JSON parsing.

Reference: pinned 26.3 `CraftingInput`, `Recipe.DIRECT_CODEC`, `RecipeManager`,
`ShapedRecipe`, `ShapelessRecipe`, `Ingredient` and player crafting/result slots;
jar SHA1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`. Private recipe examples and
signatures are `.local/recipe-*.json` and `.local/crafting-signatures.txt`.

Follow-up live composition must keep the result a derived view, never an owned
stack: current snapshots deliberately exclude slot 0, and transfer conservation
counts physical inventory only. Keep grid 1..4 owned by the player, apply result
take/ingredient consumption atomically, and retain existing close/disconnect/death
cleanup. Verify native result-menu gestures before enabling them; plain inventory
slots are not a sufficient oracle. Recipe-book synchronization remains separate.

Client scenario for this foundation is baseline smoke on its frozen checkpoint;
the live slice must use actual inventory clicks to craft logs→planks, mixed-plank
sticks/table, verify exact consumption/output and close/reconnect. Dedicated
tester owns those graphical checks. This ticket does not claim live crafting.

Isolated native prototype classifies 1,202 ordinary recipes:496 fit 2×2;
two need remainders (honey block/sugar from honey bottle),17 suspicious-stew
outputs have effect patches, leaving 477 plain candidates. Real static-registry
pending tag lookups must replace construction-only tag placeholders before
reloadable recipes are decoded; the native recipe manager then matches oak logs
to planks 4. Preserve shaped empty cells (eight across this catalog).

Actual global native selection on 149,128 tag-alternative/mixed, translated,
mirrored, shapeless-permutation, extra/missing/wrong-cell and patched/count cases
exposes one shadowed ordinary recipe: `firework_rocket_simple` must remain
excluded while the native special `firework_rocket` behavior is unsupported.
After excluding that candidate, the indexed pure prototype matches all 149,128
cases, leaving 476 intended supported recipes (151 shaped/325 shapeless). Retain
the shadowed candidate's input grids as negative controls in the canonical oracle.
Raw sources/facts/cases,
isolated classes and comparison stay ignored under `.local/crafting-*` and
`.local/CraftingCandidates.java`.

Native `InventoryMenu`/`ResultSlot` probe (network/stat presentation controlled)
confirms both pickup buttons take the complete recipe output; insufficient cursor
capacity leaves ingredients untouched. Quick-move repeats to reverse storage
order; hotbar swap crafts once; throw 0 drops one whole result and throw 1 repeats.
`.local/crafting-menu-probe.log` retains the observed grid/cursor/result/drop states.
Result-drop preparation needs a validated recipe conversion, not ordinary item
conservation alone; retain bounded delivery batches and exact recovery semantics.
All 477 candidate output items inherit base `Item.onCraftedBy` and
`onCraftedPostProcess` in the native probe; no output-specific hook was observed.

Implemented `Crafting2x2.result/1`: immutable rule tuple, count/ingredient index,
bounded shaped placements/mirrors and at most four-ingredient shapeless matching.
Normalized 476-recipe facts are compiled once; runtime lookup owns no process or
RNG. The canonical native generator reproduces the facts and all 149,128 actual
global selection/result cases pass the final API, including patched/count inputs
and unsupported-special negatives. Five targeted tests pass (seed771737): log
tags, mixed woods, translated/mirrored rules, shapeless order, special/remainder
exclusions and invalid grids. Python tool syntax checks pass; the new native
oracle/checker joins the next full integration block. Logs
`.local/player-crafting-{native,check,tests}.log`.

Frozen production build passed; dedicated baseline evidence follows. This kernel
does not enable grid/result clicks; compose those in VMC-033b.


Dedicated baseline client smoke — October 16, 2026: **PASS** on frozen
`6cd6800d4c35d41e7682e45e336651518ce97bca` (all 682 source blob IDs independently
verified; runtime PID78816/frozen BEAM confirmed), whole cloned dataset
`/tmp/valimc-player-crafting-client-20261016`. Direct unmodified Java26.3/protocol777
Quick Play launch in default small window via dedicated SDL app: flat world and
normal survival HUD rendered; E inventory opened/closed; actual `/stats` showed
`1 players · 7 regions · 10 schedulers · 101 MiB`; dedicated internal pointer
clicked pause-menu Back to Game successfully. No crafting/use/attack/movement
performed. Initial app-bind timeout recovered via app inventory refresh.
Owned client session 56818/JVM92510 stopped and waited (wrapper 0/JVM143).
Disconnected checks: zero players, source 56/outboxnil, exact full player snapshot,
all 55 item records and all receipt maps/digests unchanged; baseline reclosed and
reopened exactly with latest sequence retained. Runtime left running unchanged.
Fresh logs had no protocol/gameplay failures; offline properties/Realms auth,
OS/Vulkan and missing post-effect warnings were nonblocking. Raw report,
metadata/logs and full before/after/final snapshots are ignored under
`.local/client-tests/VMC-033a/`; no routine screenshot files. This is baseline
GUI evidence for an unused pure kernel, not live graphical crafting; native
recipe correctness remains the separate 149,128-case oracle evidence above.
