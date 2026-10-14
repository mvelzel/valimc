# VMC-019b3c — Durable ordinary-menu throws and outside cursor drops

Status: Done — actual menu drops validated, local. Updated: October 14, 2026.
Depends on VMC-019b3b. Original checkpoint and completed GUI evidence follow.

## Scope and acceptance

Before: ordinary player-menu THROW and outside cursor clicks restore inventory.
After: container 0 plans supported slot/cursor consumption and passes its drop
effect through the same source prepare/delivery/clear path as in-world Q.
This is an ordinary-menu slice; creative slot -1 creation remains VMC-019b3d.

- Pure plans expose zero/one dropped stack without publishing inventory. THROW
  needs an empty cursor; button 0 removes one and nonzero signed-byte buttons
  remove the current stack. Empty/negative valid slots are no-ops. Outside slot
  -999 with PICKUP or QUICK_MOVE drops the whole cursor for button 0, one for 1.
  Empty cursor does nothing. An interrupting click only cancels active quick-craft.
- Preserve exact supported patches/removals, selected/offhand state and all other
  slots. Predictions/state IDs are observations, never ownership. Normal clicks
  retain their current behavior through a common effect-aware planning entry point.
- Reuse one bounded, pinned source plan, writer fences, destination receipts,
  task/retry/deadline limits and mutation gates. No synchronous destination I/O,
  new coordinator or per-item process. Source-depleted inventory/cursor publishes
  after prepare, and recovery clears only after proof. A pending normal save
  corrects a new effectful click without applying its consumption.
- Meaningful regressions cover single/all/cursor/empty/drag interruption,
  nonstandard vanilla button cases, special click-override items and armor,
  forged predictions, stalled source/destination, blocked repeat/close/swap,
  source failure/disabled storage, disconnect/reconnect and exact conservation.
  Format, full tests, production release, Mojang behavior/TCP oracle and audit pass.

Actual Minecraft Java 26.3 via CUA: open the ordinary player inventory through a
development-only game-mode UI fixture (server remains the documented creative
preview). Perform actual Q/held Control+Q over an ordinary slot, then actual
pickup and right/left outside clicks with a supported carried stack. Confirm
slot/cursor changes and rendered stationary items, empty-cursor no-op, reconnect/
restart UUID/count recovery, and corrections during a stalled transfer. Fixture
setup does not qualify as the changed click. Restore creative UI, only remove
pinned test entity UUIDs, and restore fixture inventory while retaining advanced
source counters/receipts. If CUA cannot generate mouse input, retain the required
scenarios as pending and proceed across the backlog after a local checkpoint.

## Reference conclusions and design

Pinned Mojang server 26.3 SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`AbstractContainerMenu.doClick`, `Slot.safeTake/tryRemove`,
`Player.canDropItems/handleCreativeModeItemDrop` and the previously inspected
drop/entity methods. Private `javap -c -p` dumps stay in
`research/disassembly/VMC019b3c-*`. Standard slots do not replenish on take;
the repeated whole-stack output-slot crafting loop remains VMC-033. Virtual
result slot 0 remains empty. Equipment locks/full components remain later work.

Vanilla's THROW treats every nonzero byte as a whole-stack request, although only
button 1 repeats a replenishing slot. The outer PICKUP/QUICK_MOVE branch shares
the -999 cursor-drop handling. Active quick-craft consumes an interrupting click
solely to reset the gesture. The original focused Mojang harness will capture
requested drops, including invalid-input/no-op boundaries, without a gameplay world.

Actual client jar 26.3 SHA-1 `e877b6a07acd633fb3bb475002175cec036e7b87`:
`CreativeModeInventoryScreen.slotClicked` sends creative drop/add packets for
its inventory tab; it does not establish ordinary-menu click coverage. Actual
ordinary UI input is therefore required. These fixture UI packets do not implement
server game modes or survival rules. All client/Mojang artifacts remain ignored.

SteelMC `f6fb4e49778c` `steel-core/src/inventory/click.rs` and
`inventory/menu/mod.rs` separate carried drops and slot throws. Its input parser
rejects nonstandard buttons/QUICK_MOVE outside and is not the vanilla authority.
Pumpkin `b0c48b2d7688` `crates/pumpkin-inventory/src/container_click.rs` separates
outside and specific slots. Paper `a2d844f71e27`
`paper-server/patches/sources/net/minecraft/world/inventory/AbstractContainerMenu.java.patch`
clears the cursor before invoking drop callbacks; plugin-driven cancellation/order
changes do not substitute for vanilla semantics. Original Elixir plans expose
effects and commit them asynchronously instead of invoking other owners inline.

Existing stationary physics, pickup/merge/age/stats, directory/power-loss,
receipt-capacity, close-overflow and disconnect-cleanup gaps remain explicit.

## Verification

October 14, Elixir 1.20.4 / OTP 29.1.1:

- Format and all 181 tests pass, seed 535987; production release build passes.
  Eleven new tests cover pure cursor/slot effects, signed throw buttons, empty/
  cursor/negative no-ops, special pickup-override items, drag interruption,
  forged observations, source stalls/gates, destination disconnect recovery,
  normal-save admission, failed writes and malformed input during delivery. The
  existing storage-disabled regression also exercises cursor drop correction.
- Full Mojang behavior/codec/TCP oracle passes (02:47:21). Its actual menu methods
  verify both permission modes, nonzero THROW bytes and QUICK_MOVE outside,
  patches, empty/cursor no-ops and quick-craft interruption. The TCP scenario
  decodes depleted slots/cursors and exact world metadata after forged predictions.
- CUA still observes actual Minecraft 26.3 after rebinding/exposed Raise.
  A fresh coordinate click on the observed Game Menu failed with
  `noWindowsAvailable`. Enabled-surface inventory confirms the client is running
  but supplies no directly addressable window ID. These are native-input gates,
  not a server disconnect or a graphical feature pass. Required menu pickup,
  outside drops and stalled/restart scenarios remain pending.
- Updated release started 02:52:28; actual CUA localhost join 02:53:04 rendered
  the fixture. Actual in-world Q changed selected count 2→1 and rendered one
  exact patched item; source advanced 8→9 and cleared its outbox. This validates
  the refactored common path's existing world-Q behavior, not menu input.
- A pinned vanilla CHANGE_GAME_MODE event (type 3, value 0) supplied ordinary
  inventory UI only. Actual E opened it. An existing pure swap moved a prepared
  seven-item stack into the visually indicated offhand square as fixture setup.
  Actual menu Q caused no slot/cursor/source change: sequence remained 9 with
  offhand 7/main 1/storage 7. The visible pointer alone does not prove the client's
  hovered slot or a sent THROW packet. No menu-drop graphical pass is claimed.
  A right click outside the observed ordinary menu also failed before input with
  `noWindowsAvailable`. Actual pickup/right/left outside gestures remain required.
- Closed/disconnected through actual keyboard UI. Removed only the one baseline
  fixture entity and restored original empty inventory/pose through the leased
  writer, retaining sequence 9 and all receipts. Actual rejoin 02:57:45 showed
  empty hands/world; E confirmed the creative inventory UI restored. The player
  file is 151 bytes, no outbox or delivery job remains, and block edits remain.
- Private `.local/client-tests/VMC-019b3c/latest.log` has zero Network Protocol
  Error, DecoderException, EncoderException, Duplicate entity or ERROR entries.
  Public-tree audit and exact diff review pass. This checkpoint remains local
  and the ticket remains Awaiting client-generated menu input. A paused mouse
  gate does not halt implementation of the remaining server backlog.

Subject: `VMC-019b3c: commit ordinary menu drops through the durable source journal`.
Branch: `main`; earlier client mouse gates remain pending before push.

## October 14 mouse-gate completion

Actual Minecraft 26.3 / CUA, **10:11–10:23 CEST**, release code `6770915`:
a fresh private host fixture prepared two seven-item glint-patched stone stacks,
ordinary menu UI and explicit non-infinite test-owner/client abilities. Server
game-mode gameplay remains unimplemented; these were fixture controls. Actual
mouse positioning and Q over slot 9 reduced 7→6 and committed one item at sequence
30; held Control+Q emptied it and committed six at 31. Actual left pickup of slot
10 followed by right outside click reduced cursor 7→6 and committed one at 32;
left outside click emptied the cursor and committed six at 33. No menu transaction
packet was injected. Empty-cursor right/left outside clicks changed nothing.

Owner/disk reads confirm four stable UUIDs with counts **1/1/6/6**, exact patches,
empty slots/cursor and cleared outbox. CUA F5 observed the overlapping stationary
glint item models. They still have no gravity, displacement or pickup. Normal
disconnect/rejoin rendered them without reseeding and retained exact records.
A complete release restart at **10:18:11 CEST**, followed by actual CUA rejoin,
restored all UUIDs/counts/patches and source 33 from physical storage.

A fresh two-item source and destination-writer fixture checked corrections.
The writer was paused before actual input; a bounded host watcher detected the
first accepted drop and resumed it after 4.5 seconds (**10:20:01.551–10:20:06.053**).
Actual menu Q followed by held Control+Q showed the remaining one item rather
than consuming it again. After resume exactly one additional item committed at
sequence 34, with nil outbox/recovery and source slot 9 still one. Five records
then contained **1/1/1/6/6**. This is real client input; the watcher only controls
fixture I/O timing, and has exited.

Cleanup removed only those five pinned UUIDs through current region handles and
restored the fresh original pose/inventory, selected index 1 and creative UI.
At **10:23:51 CEST** the physical player snapshot matched the baseline, source
sequence **34**/nil outbox remained, and the destination receipt still read 34.
Original region item records were unchanged. CUA E showed the original creative
inventory with no fixture cursor. Private context/helper stay in `/tmp`, including
`/tmp/valimc-vmc019b3c-mouse.etf`. Private client log
`.local/client-tests/VMC-019b3c/mouse-latest.log` has zero ERROR/DecoderException
entries; no gameplay repair was needed.

Current code baseline format, **275 tests** (seed 266521), production release and
full Mojang oracle pass at `6770915`. This follow-up changes verification records
only; audit/exact diff checks pass. The original pending statements above describe
the earlier failed mouse session. Physics, pickup/merge/age, full menus, recipes,
special equipment/component behavior and the wider survival server remain work.
