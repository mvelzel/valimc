# VMC-034i — External cooking-slot state transitions

Status: Done
Resolved (VMC-079): Cooking.edit_slots runs on every live furnace slot change in World.ContainerClicks.
Note: Done within pure external-edit hook scope at `c793348`. Live menu admission belongs to VMC-034k.

Acceptance: after an admitted menu slot edit, replacing/removing an input resets
progress and computes the native contextual duration. Count-only edits preserve
progress; changing fuel/output preserves heat/speed/progress. No-op plans preserve
state. Refuse malformed/oversized proposals whole; never clamp away owned items.
Recipe-use records stay outside this pure hook and unchanged.

Reference: pinned 26.3 AbstractFurnaceBlockEntity.setItem/getTotalCookTime. Probe
actual block-entity setters with controlled world I/O and native recipe lookup;
keep reference bytecode/raw observations ignored. This composes after the slot
planner and before a future region journal commit; it does not admit exchanges,
schedule cooking, change lit blocks or award XP.

Check native boundary compositions, affected state/slot regressions, then a
frozen checkpoint and dedicated baseline. Live exchange validation remains next.

October 18: CookingSlotEditOracle executes 2,304 actual block-entity changed-slot
assignments across three types, empty/same/count/new/glint/99-capacity inputs,
all storage positions, speeds 1/2 and zero/positive progress. All states/slot bytes
match Cooking.edit_slots. Count-only edits preserve progress; changed/cleared input
resets it. A missing recipe uses 200 ticks even at speed 2; matched recipes use the
contextual duration. Fuel/output edits retain heat/speed/progress and total time.
Unchanged slots are not assigned. Raw `.local/cooking-slot-edit-{native,comparison}.log`.

16 affected checks pass(seed487656), `.local/cooking-slot-edit-targeted.log`, with
existing cooking tick and click regressions. Invalid/oversized proposals refuse
whole rather than discard items. Formatting passes. No production schedule,
source/receipt mutation or XP/recipe-use effect exists in this slice.

Frozenc793348 production passes(`.local/cooking-slot-edit-production.log`). The combined
unused-foundation baseline passes at the later cooking transfer checkpoint;
broader physical/menu integration passes on frozen `e9d7227`.

October 18: accepted combined G/H/I/J actual 26.3 baseline on frozen 5105393.
Actual ordinary chest deposit/withdraw restores exact slots/cursor; source 18→20,
typed 20, independent item 18 and storage 23→25 remain consistent through fresh
reconnect. Three occupied processor entries remain exact. Both clients stopped 143;
server 20532 flushed/stopped0. Report `.local/client-tests/VMC-034j/report.md`,
stopped audit `.local/cooking-transfer-final-audit.log`,1,149 unchanged frozen blobs
and eight whole-dataset file hashes `.local/cooking-transfer-publication-proof.json`.
This closes the unused-foundation baseline, not live cooking/menu/XP gameplay.
