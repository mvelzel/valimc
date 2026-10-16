# VMC-033e — Crafting-table recipe foundation

Status: Automated-verified; client regression pending. October 16, 2026.
Parent: VMC-033.

Acceptance: pinned ordinary3×3 recipes have bounded immutable facts and actual
native selection/result checks, including tags, translations, mirrors, mixed
ingredients and negative grids. Preserve current2×2 results. Classify special
recipes, component outputs, remainders and output hooks explicitly. Match
shapeless ingredients with a polynomial bounded assignment algorithm, avoiding
factorial search on the player owner. No recipe processes or runtime JSON parse.

Use pinned26.3 `RecipeManager`, `CraftingInput`, `Ingredient`, exact ordinary
`ShapedRecipe`/`ShapelessRecipe` and output hooks; jar revision in VMC-033a.
Private research lives in `.local/table-crafting-*`. Full native integration
currently owns shared `research/java-tools`; use isolated prototype classes.

This foundation does not open a table menu. Follow-up composition owns nine
transient inputs per player, container IDs/slot mapping and reach/close/recovery;
the placed table has no shared inventory needing a process. Keep derived output
out of physical conservation. The shared matcher now drives player crafting:
client regression must craft a log manually, close and reconnect without changing
counts. Actual table clicks belong to the later live slice.

Isolated native classification:1,202 exact ordinary recipes; exclude three
remainder recipes (cake/honey block/bottled-honey sugar),17 effect-bearing stews
and two shadowed ordinary fallbacks (simple rocket/decorated pot). Actual global
selection exposed the pot fallback; neither can bypass the native special recipe.
No specialized output craft hooks among the remaining1,180 profiles. Their476-
recipe2×2 subset equals the existing catalog exactly, including order/all facts.
Private prototype/classes/facts/log:
`.local/TableCraftingCandidates.java`, `.local/table-crafting-prototype-classes/`,
`.local/table-crafting-candidates.json`, `.local/table-crafting-classification.log`.

`Crafting.result/1` replaces the dimension-specific module, accepting exactly
four or nine cells. One immutable catalog/index; translated/mirrored shapes,
constant one/two-ingredient paths and polynomial augmenting-path assignment for
larger shapeless inputs. Fail on a missing ingredient before building more edges.
At most61 indexed candidates and nine inputs in the pinned catalog. No new owner.

Canonical `TableCraftingOracle` reproduces all facts and438,672 actual global
selection/results, including both special fallbacks as negative controls,
exhaustive distinct shapeless permutations, tags/mixes, positions/mirrors,
wrong/missing/extra cells and patches/counts. Current code also passes149,128
old player cases,3,536 actual menu cases,9,466 result/drop cases and100 affected
tests. Raw `.local/table-crafting-{canonical-native,check,player-check,menu-check,`
`gestures-check,tests}.log`; canonical cases/facts remain ignored. Native tools
were compiled in isolated classes while the earlier full block owned shared ones.

Microbenchmark:8,773 identical sampled2×2 native grids, five alternating rounds,
same476-recipe coverage, baseline `88416e9`. Final median2.246ms/887,564 reductions
versus2.430ms/1,303,659; raw `.local/table-crafting-benchmark.json`, workload
`.local/benchmark_crafting.exs`, previous samples `-v1/-v2` and source hashes
retained. Initial general assignment added overhead; small constant paths and
early failure remove it. Native integration was active, so timings are a local
microkernel observation, not capacity or cross-server evidence.
