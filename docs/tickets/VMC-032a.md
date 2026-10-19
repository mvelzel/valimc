# VMC-032a — Chest menu foundation

Status: Foundation
Note: Done within layout-foundation scope at `faee515`. Persistent chests are not live.

Acceptance: native generic chest row/type/slot mapping and contents over container
storage plus player inventory. Closing a view must not return chest contents to a
player. First prove 1–6 row layouts against pinned 26.3 ChestMenu/SimpleContainer;
single physical chests use 3 rows. Wire layout alone is not shared-container support.

Architecture: region owns persistent container contents/revision, not a process per
block. A player owns its menu session, cursor and inventory. Plan clicks against a
fenced container revision; reuse durable player intent→region receipt→player seal
ordering for both deposits and withdrawals. Conflicts resync; committed intents
recover forward. Published observations are not authority. Bound encoded contents,
viewers, pending operations and fanout. Placement/removal must fence open views and
preserve contents/drops before publishing block changes.

Next slices: bounded container storage/leases; pure native click plans; transactional
live menus/recovery; physical chest placement/mining/opening rules and lifecycle.
Do not enable a UI before ownership/persistence are ready. Double/trapped chests,
redstone and other containers remain separately scoped. Roadmap order is editable.

Client: baseline join/terrain/command for this pure foundation; later frozen live
chest tests cover two players, competing transfers, close/reconnect, block removal
and recovery. Delegate actual GUI. Native probes cannot replace it; raw jars,
bytecode, observations and worlds remain ignored.

October 18: original ChestMenuOracle verifies all six generic row/type layouts,
405 slot identities, complete open-screen bodies, contents and empty-cursor close
callbacks retaining storage. ChestMenu exposes pure addresses/views only; no live
chest authority is admitted. Shared open-screen encoding retains the native table
body. Six native comparisons,24 existing table cleanup cases and 8 affected tests
pass(seed505985); changed-file formatting/Python compilation pass. Native fixtures
use ContainerUser callbacks, matching 26.3. Private logs: `.local/chest-menu-*`
and `.local/chest-foundation-table-*`. Baseline GUI remains pending.

Frozen faee515 production and dedicated actual 26.3 baseline pass: join/movement/HUD,
command/inventory and existing 3×3 table recipe, cursor close and input close cleanup.
The open-screen helper retains correct rendering. Report reviewed once; no live
chest UI claim. Client/server stopped, four regions+clock flushed,1,022 frozen blobs
unchanged, stopped dataset source 61/outboxnil/receipt61 retained. Private report
`.local/client-tests/VMC-032a/report.md`; cleanup/audit/hashes in
`.local/chest-foundations-publication-proof.json`. All gates for this foundation pass.
