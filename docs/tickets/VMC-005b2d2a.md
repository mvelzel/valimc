# VMC-005b2d2a — Durable connected menu-close overflow

Status: Done
Note: Done — connected close overflow validated, local. Updated: October 14, 2026. Depends on VMC-005b2d1 and the automated-verified VMC-019b3c transfer helper. VMC-019b3c's actual mouse-input gate stays parked; this slice changes menu close.

## Scope and acceptance

Before: an overflowing connected close restores all cursor/grid items and rejects
the return. After: close returns what fits, atomically prepares the resulting
inventory plus up to five world-drop records, and delivers/clears that intent.
The changed action is container close, independently of how contents were obtained.

- Reuse the existing pure vanilla-order return plan: cursor first, then grid 1..4;
  selected/offhand/storage merges before empty storage; exact supported patches,
  stack caps and damage survive. Cancel quick-craft and clear cursor/grid/result.
  Recipes/result replenishment, game modes and disconnect cleanup remain separate.
- With overflow, publish no partial return before source prepare commits. Pin
  one UUID per remainder and one destination/sequence for the whole batch. Region
  admission/receipt covers all records atomically; no partially visible batch.
  Reuse asynchronous writer/delivery work, existing fences/limits/backoff/deadline
  and mutation gates. Repeated closes during/after completion cannot duplicate.
- Busy normal saves, disabled source storage or no-commit prepare failures
  restore the whole old inventory. Uncertain commits/deadlines/disconnects preserve
  the actual outbox; reconnect recovers reduced inventory and exact records once.
  Movement/chat/other sessions stay live. Destination capacity cannot silently
  drop a remainder: retain the intent until capacity/recovery permits delivery.
- Tests cover partial merge plus all five remainder identities, source/destination
  stalls, repeat close/click/hand-swap admission, normal-save/disabled/error
  boundaries, capacity-retry atomicity, disconnect/reconnect and region reload.
  Existing ephemeral rejection/retry remains valid with its new storage reason.
  Format/full tests/release/full Mojang oracle/public-tree audit must pass.

Actual Minecraft Java 26.3 via CUA: prepare full storage, selected stack 63,
carried stone 10 and four different supported grid stacks as a fixture. Ordinary
inventory UI is supplied by the existing development-only game-mode event; server
permissions remain the documented creative preview. Actual E/Escape close must
show selected 64, empty cursor/grid and rendered overflow. Owner/file checks must
confirm exact counts/patches and five stable UUIDs. Reopen/close again, reconnect
and full restart must create nothing extra. Temporarily disable the source writer
path for a second fixture: actual close must retain old counts; repair storage and
actual retry must succeed. A stalled source must also correct repeat close without
another plan. Clean only pinned fixture entities; restore empty original inventory/
pose while retaining advanced source counters and receipts; restore creative UI.
Actual mouse pickup is a separate parent-ticket gate and fixture setup cannot pass it.

## Reference conclusions and design

Pinned Mojang 26.3 server SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`AbstractContainerMenu.removed/dropOrPlaceInInventory/clearContainer`,
`InventoryMenu.removed`, `Inventory.placeItemBackInInventory`, and
`ServerGamePacketListenerImpl.handleContainerClose`. Existing private bytecode
dumps under ignored `research/disassembly/` were re-inspected. Connected removal
returns the cursor and then grid through inventory placement; no free slot drops
the remainder with SERVER_ONLY prediction and no hand-throw statistics/thrower.
Disconnected/removed players take a different direct-drop branch, outside this slice.
The return method's boolean controls inventory updates; it does not permit creative
overflow deletion. The actual Mojang harness verifies an ordered five-stack
return sequence and partial merge in both infinite-material permission modes.

SteelMC `f6fb4e49778c` `player/player_inventory/player_handlers.rs`
`returns_menu_items_to_inventory/add_item_or_drop` separates removal disposition
and remainder drops. Its additional health check is not inferred as a 26.3 rule.
Pumpkin `b0c48b2d7688` `crates/pumpkin-inventory/src/player/player_screen_handler.rs`
`on_closed` exposes cursor/grid cleanup and a result-clear TODO. Paper
`a2d844f71e27` menu patches add plugin ordering/cancellation behavior; the vanilla
control flow remains the compatibility authority. See the VMC-005b2d1 research.

Original Elixir orchestration uses the socket owner for the plan, leased source
writer for one conserved journal, a bounded I/O job for destination calls, and
the region owner/writer for one atomic batch/receipt. No new process per stack or
global transaction server is introduced. Stationary preview items remain an
explicit physics/pickup/age/thrower/statistics gap; close overflow does not complete
VMC-005b2d2, VMC-019 or vanilla survival. Directory/power-loss and receipt-retirement
qualification remain existing limits.

## Verification

October 14: format and all 187 tests pass (seed 897737); production release and
full Mojang behavior/codec/TCP oracle pass (03:10:12). Six new integration tests
cover partial return/five exact remainders/repeat/reload; unpublished stalled
prepare with gated repeat/click/swap and live movement/chat; whole-batch stalled
destination/disconnect/login recovery; disabled/failed source preservation;
normal-save admission/retry; and 252-record capacity rejecting the five-item batch
without publishing four, then accepting all five after one old item is removed.
The old ephemeral close regression now checks the source-storage rejection.

The actual Mojang return method confirms cursor/grid ordering, partial selected
merge and five exact remainder identities/damage in both permission modes. Its
TCP codecs decode selected 64, cleared cursor/grid and all five world metadata
stacks; another close retains the returned contents.

Actual Minecraft Java 26.3 CUA validation, October 14: release started 03:17:44,
localhost joined 03:18:14. An offline normal-writer fixture populated 36 full
storage stacks, selected patched stone 63, full offhand, cursor stone 10, and
grid eggs 3/dirt 4/damaged iron sword 1/diamond 1. The development-only game-mode
event supplied ordinary inventory UI; server permissions remained creative.
Actual E close and backward movement showed selected 64 and overlapping rendered
overflow models. Actual E reopen showed empty cursor/grid. Owner/file assertions
confirmed precisely five pinned records: patched stone 9, eggs 3, dirt 4, damaged
sword 1 and diamond 1 (18 items), with sequence 9→10 and cleared outbox. Repeat
close created nothing. Actual reconnect 03:21:48 and full release restart
03:22:20/rejoin 03:22:58 retained exact inventory and the same five UUIDs.

A second normal-writer fixture retained sequence 10. Actual rejoin 03:27:31 and E
displayed the full old contents. With the source writer path temporarily disabled,
actual Escape close displayed the prepare-rejection message; actual E reopen
showed selected 63, cursor 10 and unchanged grid. Source/file/owner checks retained
sequence 10/no outbox and only the first five records. After repairing the path,
the writer was suspended until seven seconds after actual close arrival. Actual
Escape/E/Escape/E repeated close during prepare; the screenshot and a three-second
owner read preserved all old contents and the same five-record plan. Resuming
the writer completed that plan once: visible selected 64/empty cursor/grid,
source/file sequence 11/no outbox and exactly ten records (36 items across the two
separate fixtures). Another actual reopen/close retained all exact pinned UUIDs.
Fixture reseeding was administrative setup, not a conservation assertion across
the two scenarios. Movement/chat admission under a stall was verified separately
by automated tests, not by this GUI sequence.

Only the ten pinned fixture UUIDs were durably removed; the world visibly cleared.
Actual Disconnect allowed normal writer cleanup to restore original empty
inventory/pose while retaining sequence 11 and destination receipts. Actual
rejoin 03:30:12 and E showed empty slots and restored creative UI. The player file
is 151 bytes, no recovery job/outbox remains, and the receipt retains sequence 11.
Private client log at `.local/client-tests/VMC-005b2d2a/latest.log` contains zero
protocol/codec/duplicate-entity/ERROR entries. Keyboard closes are actual client
actions; inventory setup and UI-mode selection remain fixtures. Earlier mouse
pickup/drag/clone gates are still pending, and stationary physics/pickup/lifecycle
limitations remain unchanged. Public-tree audit and exact diff were reviewed
before amending the unpublished checkpoint with this evidence.

Subject: `VMC-005b2d2a: commit menu-close overflow as one durable item batch`.
Branch: `main`; earlier ancestor mouse gates remain pending before push.
