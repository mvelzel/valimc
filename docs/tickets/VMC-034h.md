# VMC-034h — Cooking menu item-transfer plans

Status: Done within pure item-planner scope atbb04210. Live menu admission belongs to VMC-034k.

Acceptance: pure drop-free pickup/split/merge, shift routing and number/offhand
swaps match actual26.3 furnace-family clicks. Fuel slot accepts fuel components
or empty buckets; bucket capacity is one. Output rejects deposits; eligible
input wins over fuel on shift. Keep player/cursor/storage conservation and report
output removal for later award admission. Unsupported overflow/gestures refuse
whole. Do not clear recipe-use records or pretend to award XP.

Native AbstractFurnaceMenu, FurnaceFuelSlot, FurnaceResultSlot and ordinary click
handling define item behavior. Execute native clicks with a SimpleContainer and
controlled player statistics/world endpoints; this excludes block-entity input
reset hooks, XP and persistence. Those need owned joint commits before live use.

Focused native comparisons/boundary tests precede a committed checkpoint and
dedicated baseline. Actual exchanges/reconnect belong to later live admission.

October18: pinned26.3/server33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c
CookingClickOracle executes36,036 native clicks plus4,974 all-item shift routes.
40,776 drop-free results match exactly;234 oversized number/offhand swaps are
explicitly refused pending durable overflow delivery. Covered both permissions,
three storage/player boundary layouts, capacities1/16/64/99, glint/damage patches,
removed cooking-fuel components, both cursor buttons and all three processors.
Raw `.local/cooking-click-{native,comparison}.log`; no upstream recipe files.

CookingClick preserves hidden cells/cursor, routes recipe inputs before fuel,
uses forward player order for input/fuel withdrawal and reverse for output, and
reports removed output quantity without any award. Bucket capacity is1; empty
buckets shift between player areas rather than automatically into fuel. A partial
cursor-pull bug found by the native probe was fixed: a matching cursor must fit
the whole noninsertable stack. Unsupported gestures/overflow return no proposal.

16 affected checks pass(seed769858), `.local/cooking-click-targeted.log`, including
existing generic-chest and cooking-view checks. Compilation is warning-free and
changed formatting passes. This does not apply block-entity input reset hooks,
recipe-use/XP effects, region writes, player receipts or live menu authorization.

Frozenbb04210 production passes(`.local/cooking-click-production.log`). The parent
e9d7227 integration checkpoint has1,580 full tests/production; its full native run
passes; the combined unused-foundation client baseline is accepted below.

October18: accepted combined G/H/I/J actual26.3 baseline on frozen5105393.
Actual ordinary chest deposit/withdraw restores exact slots/cursor; source18→20,
typed20, independent item18 and storage23→25 remain consistent through fresh
reconnect. Three occupied processor entries remain exact. Both clients stopped143;
server20532 flushed/stopped0. Report `.local/client-tests/VMC-034j/report.md`,
stopped audit `.local/cooking-transfer-final-audit.log`,1,149 unchanged frozen blobs
and eight whole-dataset file hashes `.local/cooking-transfer-publication-proof.json`.
This closes the unused-foundation baseline, not live cooking/menu/XP gameplay.
