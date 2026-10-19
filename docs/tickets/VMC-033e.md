# VMC-033e — Crafting-table recipe foundation

Status: Foundation
Note: Done within ordinary recipe-foundation scope, `7779eaf`. October 16, 2026.
Parent: VMC-033.

Acceptance: pinned ordinary 3×3 recipes have bounded immutable facts and actual
native selection/result checks, including tags, translations, mirrors, mixed
ingredients and negative grids. Preserve current 2×2 results. Classify special
recipes, component outputs, remainders and output hooks explicitly. Match
shapeless ingredients with a polynomial bounded assignment algorithm, avoiding
factorial search on the player owner. No recipe processes or runtime JSON parse.

Use pinned 26.3 `RecipeManager`, `CraftingInput`, `Ingredient`, exact ordinary
`ShapedRecipe`/`ShapelessRecipe` and output hooks; jar revision in VMC-033a.
Private research lives in `.local/table-crafting-*`. Full native integration
currently owns shared `research/java-tools`; use isolated prototype classes.

This foundation does not open a table menu. Follow-up composition owns nine
transient inputs per player, container IDs/slot mapping and reach/close/recovery;
the placed table has no shared inventory needing a process. Keep derived output
out of physical conservation. The shared matcher now drives player crafting:
client regression passed manual log crafting, close and reconnect with exact
counts. Actual table clicks belong to the later live slice.

Isolated native classification:1,202 exact ordinary recipes; exclude three
remainder recipes (cake/honey block/bottled-honey sugar),17 effect-bearing stews
and two shadowed ordinary fallbacks (simple rocket/decorated pot). Actual global
selection exposed the pot fallback; neither can bypass the native special recipe.
No specialized output craft hooks among the remaining 1,180 profiles. Their 476-
recipe 2×2 subset equals the existing catalog exactly, including order/all facts.
Private prototype/classes/facts/log:
`.local/TableCraftingCandidates.java`, `.local/table-crafting-prototype-classes/`,
`.local/table-crafting-candidates.json`, `.local/table-crafting-classification.log`.

`Crafting.result/1` replaces the dimension-specific module, accepting exactly
four or nine cells. One immutable catalog/index; translated/mirrored shapes,
constant one/two-ingredient paths and polynomial augmenting-path assignment for
larger shapeless inputs. Fail on a missing ingredient before building more edges.
At most 61 indexed candidates and nine inputs in the pinned catalog. No new owner.

Canonical `TableCraftingOracle` reproduces all facts and 438,672 actual global
selection/results, including both special fallbacks as negative controls,
exhaustive distinct shapeless permutations, tags/mixes, positions/mirrors,
wrong/missing/extra cells and patches/counts. Current code also passes 149,128
old player cases,3,536 actual menu cases,9,466 result/drop cases and 100 affected
tests. Raw `.local/table-crafting-{canonical-native,check,player-check,menu-check,`
`gestures-check,tests}.log`; canonical cases/facts remain ignored. Native tools
were compiled in isolated classes while the earlier full block owned shared ones.
Frozen production build passed (`.local/table-recipe-production.log`). The prior
player-crafting block passed 914 full tests/native integration/both TCP transports;
this matcher change uses the affected checks above.

Microbenchmark:8,773 identical sampled 2×2 native grids, five alternating rounds,
same 476-recipe coverage, baseline `88416e9`. Final median 2.246ms/887,564 reductions
versus 2.430ms/1,303,659; raw `.local/table-crafting-benchmark.json`, workload
`.local/benchmark_crafting.exs`, previous samples `-v1/-v2` and source hashes
retained. Initial general assignment added overhead; small constant paths and
early failure remove it. Native integration was active, so timings are a local
microkernel observation, not capacity or cross-server evidence.

Actual client regression PASS, October 16,2026: unmodified 26.3/protocol777 on
frozen `7779eafc0171ee354746b3e85aa1c01e68dc4491` (697 blobs verified;
loaded Crafting/Inventory match frozen production code). Dedicated SDL pointer:
hotbar log2→player grid 4, visible result planks 4; right result took whole 4/log1,
left result took whole 4/carried8/empty grid. Stored 8, E close/reopen and fresh
Quick Play reconnect both retained exact 8 with empty grid/result/cursor; RPC
confirmed physical slot 0 nil throughout. Both tracked client wrappers/JVMs
stopped and zero connections verified. Restored original full snapshot with
source 60/nil outbox; all 59 prior records and every region receipt term unchanged
(21/8/4/26 records; receipts 60/6/9/56). Server left running unchanged. Raw report,
snapshots, RPC observations, code hashes and fresh logs:
`.local/client-tests/VMC-033e/`. Scope is existing 2×2 regression only, with no
3×3/table/remainder/special/recipe-book GUI claim. Client logs show ancillary
offline profile/Realms authentication and renderer messages, no crafting crash.
