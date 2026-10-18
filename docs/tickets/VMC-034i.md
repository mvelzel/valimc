# VMC-034i — External cooking-slot state transitions

Status: Pure hook implemented; checkpoint baseline pending. No live caller.

Acceptance: after an admitted menu slot edit, replacing/removing an input resets
progress and computes the native contextual duration. Count-only edits preserve
progress; changing fuel/output preserves heat/speed/progress. No-op plans preserve
state. Refuse malformed/oversized proposals whole; never clamp away owned items.
Recipe-use records stay outside this pure hook and unchanged.

Reference: pinned26.3 AbstractFurnaceBlockEntity.setItem/getTotalCookTime. Probe
actual block-entity setters with controlled world I/O and native recipe lookup;
keep reference bytecode/raw observations ignored. This composes after the slot
planner and before a future region journal commit; it does not admit exchanges,
schedule cooking, change lit blocks or award XP.

Check native boundary compositions, affected state/slot regressions, then a
frozen checkpoint and dedicated baseline. Live exchange validation remains next.

October18: CookingSlotEditOracle executes2,304 actual block-entity changed-slot
assignments across three types, empty/same/count/new/glint/99-capacity inputs,
all storage positions, speeds1/2 and zero/positive progress. All states/slot bytes
match Cooking.edit_slots. Count-only edits preserve progress; changed/cleared input
resets it. A missing recipe uses200 ticks even at speed2; matched recipes use the
contextual duration. Fuel/output edits retain heat/speed/progress and total time.
Unchanged slots are not assigned. Raw `.local/cooking-slot-edit-{native,comparison}.log`.

16 affected checks pass(seed487656), `.local/cooking-slot-edit-targeted.log`, with
existing cooking tick and click regressions. Invalid/oversized proposals refuse
whole rather than discard items. Formatting passes. No production schedule,
source/receipt mutation or XP/recipe-use effect exists in this slice.

Frozenc793348 production passes(`.local/cooking-slot-edit-production.log`). A
combined unused-foundation baseline will run on the later cooking transfer
checkpoint; broader physical/menu integration continues on frozene9d7227.
