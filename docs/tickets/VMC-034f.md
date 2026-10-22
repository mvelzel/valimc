# VMC-034f — Empty processing-block lifecycle

Status: Parked
Resolved (VMC-079): placement, facing, empty mining and loot are live; spilling an occupied furnace's slots and its stored XP on removal, and named furnaces, remain.
Note: Done within empty physical lifecycle scope at `b68ca61`. No live cooking.

Acceptance: placing a stock furnace, smoker or blast furnace creates one owned
empty cooking entry in the same block/item/container commit; empty mining/removal
retires it without replay. Preserve native facing, consumption and self loot.
Keep names/occupied progress/recipe-use records refused until their complete
metadata/spill/XP protocols exist. Raw edits cannot orphan processing state.

Establish pinned placement/state/loot facts, then extend existing lifecycle and
joint mutation workers. Same-kind state changes retain inventory/revisions;
replacement retires before creation. No new owner/process or direct store writes.
Cover writer boundaries, old chest regressions, typed receipts and stale proposals.

Dedicated client: all three blocks, horizontal facing, survival placement/mining/
pickup, creative removal, refused named/occupied contexts and fresh reconnect.
No furnace menu, automatic cooking or XP claim in this slice.


October 18 pinned 26.3/server33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c:
original CookingPlacementOracle captures 864 candidates across all three types,
four headings, six faces, both secondary-use states and six target blocks/fluids.
All 12 directional results and 24 state kinds match the pure lookup. Candidates are
unlit and never waterlogged. Existing native yaw arithmetic is reused; no copied
threading model. Raw `.local/cooking-placement-native.json`,
`.local/cooking-blocks-comparison.log`. CookingLootOracle captures 864 state/tool/
metadata contexts; all 648 supported unnamed self-loot/harvest cases match. Names
copy into native self loot, so named placement remains refused. Stored contents/
XP use separate hooks and are unadmitted. Raw `.local/cooking-loot-native.json`,
`.local/cooking-loot-comparison.log`.

Supported placement captures transient facing for every admitted command and
validates saved orientations without changing placement-intent bytes. Lifecycle
workers create/retire empty cooking metadata in the existing joint journal;
creative removal uses that path too. Region-owned exact retired-entry proofs can
remove only empty slots, zero remaining heat/progress and no recipe-use counters.
Raw edits remain fenced. Same-kind lifecycle proposals retain metadata; automatic
lit/progress mutation is not admitted. No source receipt or item authority added.

73 affected checks pass(seed606685), `.local/cooking-physical-targeted-final-all.log`:
all three types/both modes/both hands, saved facing/reconnect, stock mining/tool
wear/one drop, creative/no drops, named pre-admission refusal and occupied durable
mining rejection without tool wear/contents loss. Old chest spill/recovery and raw
processor guards still pass. Initial packet checks caught/fixed missing facing
capture and the chest-only creative removal route. Frozenb68ca61 production and both native TCP transports pass
(`.local/cooking-physical-{production,native-tcp}.log`). Dedicated actual placement/
mine/pickup/negatives/reconnect passed.

Dedicated 26.3 feature acceptance and stopped-world audit pass (October 18).
Actual stock placement/facing/offhand, mining/self-loot/pickup, named/occupied
refusals, creative removal and fresh reconnect are accepted. Five valid survival
placements/mines/pickups plus three terminal refusals retain source/item18,
no outbox, typed receipts{}, storage 22, three exact occupied entries, stock 4/2/2,
named2each and pickaxe damage 5. One extra smoker placement was corrected through
real mining/pickup, not a reset. Creative mode used the authorized consistent
fixture because /gamemode is unimplemented. No new-menu/cooking/XP claim.
Client gate is closed; report was reviewed once. Both clients and server stopped;
1,133 frozen blobs/world evidence are in `.local/cooking-physical-publication-proof.json`.
Broader e9d7227 full tests 1,580 and full native integration/both TCP transports
pass (`.local/cooking-physical-menu-native-full.log`). Every F gate is closed.

October 20 client finding (`5b7cf61`): creative removal of a furnace holding items
returns `:occupied_cooking_entry` and the client sees the block restored; contents
stay intact. Vanilla drops the contents and the stored recipe experience, which
needs the occupied spill plus cooking orbs (VMC-034n4c). Copper chests and barrels
place as plain blocks without container records; a copper chest renders invisible
after reconnect because its chunk carries no block entity.

Container-variant refusal (October 20): `BlockEntityOracle` records the 4,743
pinned block-entity states (`priv/physics/block_entities.json`, stage
`block_entities`). Owner block proposals (placement and batch commits) refuse
any that is not a single chest or furnace-family state
(`:unsupported_block_entity`), and the creative preview no longer writes them,
so copper chests, barrels and other container variants are corrected with no
shell or item loss until M1. Survival already corrected them. Raw `set_block`
stays a fixture/admin tool. `test/unsupported_block_entity_test.exs` covers both
modes plus unchanged chest/furnace placement; 190 affected and 1,008 fast checks
pass. No client re-run yet.
