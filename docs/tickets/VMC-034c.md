# VMC-034c — Stock cooking recipes

Status: Done within pure recipe resolver scope at32bc5a1. No live processing.

Acceptance: indexed stock smelting/smoking/blasting selection, result components,
base cooking time and float32 XP match actual pinned RecipeManager/assemble calls.
Named/count-varied inputs must resolve correctly; noningredients and empty input
must not smelt. Numeric facts may be public; upstream recipe JSON remains ignored.

Use immutable lookup tables keyed by cooking kind and item. Keep recipe discovery,
XP awards, timers and durable region ownership separate until their full behavior
is established. Baseline client scenario: direct join/HUD, ordinary empty-chest
open/close and fresh reconnect with quantities unchanged; no smelting claim.


October18 pinned26.3/server33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c:
CookingRecipesOracle loads native tags/reloadable registries, uses the actual
RecipeManager selection and recipe assembly, and invokes native getTotalCookTime.
14,922 stock/named/full input cases pass; all4,974 stock kind/item combinations
have at most one matching recipe. Selection covers163 smelting,9 smoking and62
blasting inputs,107 unique recipes. Stock base time is200 for every cooking kind;
speed0/1/2 contexts resolve200/200/100. Output is one unpatched stock item; exact
float32 XP bits are retained, with no awards implemented. All44,766 composed
speed-context results match. Raw `.local/cooking-recipes-native.json`, comparison
`.local/cooking-recipes-comparison.log`; upstream recipe JSON stays private.

CookingRecipes.find/3 validates supported input patches and returns an immutable
indexed recipe/result/time/XP observation. Names/counts do not leak into output.
Seven affected checks pass(seed628797), including composition with atomic output
refusal/consumption, cooking-kind exclusions, invalid input/context and unsupported
speed (`.local/cooking-recipes-targeted.log`). Changed formatting/Python compilation
and public audit pass; production and dedicated baseline remain pending.


October18 frozen32bc5a1 passes1,547 full tests, production and dedicated baseline:
two actual fresh direct joins, native empty chest/HUD/lid open/close and reconnect
retain every quantity/component and source110/typed109/item110+61/storage30. No
packet errors or gameplay edits. Both clients stopped143; regions/clock flushed,
server29174 stopped0. Accepted `.local/client-tests/VMC-034c/report.md`;39 stopped
dataset-file/1,115 unchanged frozen-blob hashes and audit
`.local/cooking-recipes-publication-proof.json`. Parent full native/both TCP and
current targeted recipe probes pass. All unused-foundation gates are closed;
do not repeat this baseline. Actual smelting and XP awards remain future work.
