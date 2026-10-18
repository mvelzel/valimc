# VMC-034f — Empty processing-block lifecycle

Status: Physical empty lifecycle/production/native TCP pass; actual client and
integration acceptance pending. Depends on VMC-034e; no live cooking.

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


October18 pinned26.3/server33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c:
original CookingPlacementOracle captures864 candidates across all three types,
four headings, six faces, both secondary-use states and six target blocks/fluids.
All12 directional results and24 state kinds match the pure lookup. Candidates are
unlit and never waterlogged. Existing native yaw arithmetic is reused; no copied
threading model. Raw `.local/cooking-placement-native.json`,
`.local/cooking-blocks-comparison.log`. CookingLootOracle captures864 state/tool/
metadata contexts; all648 supported unnamed self-loot/harvest cases match. Names
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
mine/pickup/negatives/reconnect is running; integration remains before Done.
