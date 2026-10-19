# VMC-005b2d2b — Durable disconnected cursor/grid cleanup

Status: Done
Note: Done — disconnected preview cleanup and recovery validated, local.
Updated: October 14, 2026.
Depends on VMC-005b2d2a and the source/destination transfer journals.

## Scope and acceptance

Before: disconnect saves carried/grid contents as preview recovery state. After:
disconnect drops the whole cursor stack, then grid slots 1..4, even with free
storage. Clear virtual result, cursor/grid and drag; retain slots 5..45 and selection.
Supported component patches remain exact. Existing stationary entity limitations
(physics, pickup, aging, merging, thrower/statistics) remain separate backlog work.

- Commit latest owned state and then reduced inventory plus one bounded outbox
  before publishing any of up to five whole-stack drops. Finish an already
  committed transfer first, then dispose of its remaining cursor/grid contents.
  Never replace committed inventory with a stale socket snapshot.
- The per-player writer owns closing recovery after its socket exits, using one
  bounded delivery job, pinned UUIDs/sequence, receipts, bounded retry/deadline.
  No global gameplay coordinator or process per stack. Other sessions stay live.
- A reconnect can adopt a closing writer, cancel its old job/timers, rotate its
  lease and resume the exact committed intent. Old owner replies/fences must not
  modify the new session. A live writer's lease remains exclusive.
- Legacy/unclean saves with cursor/grid contents are cleaned through the journal
  before login publishes inventory. Recovery sends no play packets during login.
  Storage/capacity/sequence failures preserve the source and reject/retry safely;
  no unjournaled ephemeral drop. Unsaved edits before a hard kill remain the
  existing checkpoint durability limitation.
- Regression tests cover whole-stack disposition vs connected returns, exact
  patches/order, offline completion, pending-intent chaining, closing takeover,
  stale completions, unavailable destination, raw-save/prepare failure, orphan
  cleanup and shutdown/reload. Update old preview-recovery assertions honestly.
  Format, full ExUnit, production release, full Mojang oracle and audit must pass.

Actual Minecraft 26.3 via CUA: use a reversible ordinary-writer/owner fixture
with free main slots, selected stone 63, offhand eggs 3, a patched cursor stack and
four supported grid stacks. Actual disconnect (or a server disconnect while its
inventory is open if the client closes the menu first) must create the five exact
records while offline, without merging into storage. Rejoin/restart must show an
empty cursor/grid, unchanged main/offhand/selection and the same rendered UUIDs.
Also exercise reconnect during a stalled destination, preserving one intent and
no duplicate records. Fixtures are setup, not evidence of actual mouse pickup.
Clean only pinned entities, restore original empty inventory/pose retaining
advanced sequence/receipts, and record limitations and private log evidence.

## References and design

Pinned Mojang 26.3 server SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`AbstractContainerMenu.removed/dropOrPlaceInInventory/clearContainer`,
`InventoryMenu.removed`, `ServerGamePacketListenerImpl.onDisconnect/
removePlayerFromWorld`, `ServerPlayer.disconnect/hasDisconnected`. Private
bytecode inspected October 14: removal marks the player disconnected before
PlayerList removes it; the menu's disconnected branch directly drops contents
with SERVER_ONLY prediction rather than inventory placement. Cursor precedes
grid slots. CHANGED_DIMENSION is excluded from the removed-entity branch;
dimension transfers and death/removal semantics are outside this ticket.

SteelMC `f6fb4e49778c` player-inventory removal handlers and Pumpkin
`b0c48b2d7688` player screen-handler cleanup inform ownership/disposition; their
incomplete coverage and Steel's extra health check do not define vanilla parity.
Paper `a2d844f71e27` menu/plugin patches remain an edge-case reference. See
VMC-005b2d1/d2a for exact upstream paths and conclusions. Original Elixir code
reuses the existing source writer, bounded TransferWorkers and region receipts.
Graceful shutdown journals the intent before returning from connection cleanup;
delivery may finish on recovery if destination infrastructure is shutting down.

## Verification

October 14: format and all 216 tests pass (seed 626513), production release and
full Mojang behavior/codec/TCP oracle pass (04:54:14). Nine added regressions
cover whole-stack vs connected disposition, offline socket-exit completion/reload,
closing-writer takeover/stale messages, orphan cleanup before configuration with
another responsive player, disabled/exhausted source preservation, failed raw
write, pinned deadline recovery, an unobserved creative prepare followed by
cleanup without stale rollback, and destination capacity retaining all five.
Existing cursor-drop/persistence tests now assert vanilla disconnect disposal;
connected-close fixtures seed transient contents after login instead of creating
orphan saves. Generic administrative `close` still saves a raw fixture, while
socket `close_session` owns disconnected cleanup.

The original development harness invokes Mojang's actual `removed` and
`clearContainer` on a constructor-free disconnected ServerPlayer. Both permission
modes request the cursor then four exact patched/damaged whole stacks, clear
cursor/grid and leave selected 63/offhand 3/free storage unchanged. This captures
requested effects only; it does not simulate world entities or replace CUA.

Closing recovery holds at most one job and one source intent; an existing intent
can be followed by one cleanup intent. Each has the existing 10-second/20-retry
bound, 50–500 ms backoff. UUID leases remain within the bounded writer supervisor;
a responsive closing writer rotates its fence on adoption. Source raw save and
cleanup prepare finish before the socket's terminate callback returns. A failed
raw write preserves previously committed bytes (new unsaved edits cannot be
promised durable); failed prepare leaves the latest successful raw save for
pre-login cleanup. Nil storage explicitly prevents durable drops. Directory
power-loss qualification and receipt retirement remain existing limitations.

Actual Minecraft Java 26.3 CUA validation, October 14: release started 04:56:19,
localhost joined 04:56:39. A trusted live-owner/ordinary-writer fixture supplied
selected patched stone 63, offhand eggs 3, cursor patched stone 10 and grid eggs
3/dirt 4/damaged sword 1/diamond 1, with 35 free storage slots. A development-only
game-mode event supplied ordinary inventory UI; server permissions stayed creative.
Actual E displayed all contents. Server-initiated disconnect while this inventory
was open at 04:57:32 produced the actual Connection Lost screen. Before any rejoin,
owner/file checks proved precisely five whole records (19 items), empty cursor/grid,
unchanged selected 63/offhand 3 and source sequence 17→18/cleared outbox. This was
server disconnect, not a claim that Escape from inventory skips connected close.

Actual rejoin 04:58:03/backward movement rendered the overlapping stationary models;
E showed empty cursor/grid and unchanged storage. Full release restart 04:58:40/
rejoin 04:59:03 retained the same five UUIDs, contents and sequence. Another empty
close created no effect.

Two separately reseeded live fixtures exercised actual Game Menu Disconnect with
delivery admission held by the bounded TransferWorkers pool. The 05:00:49 rejoin
followed the closing writer's retry exhaustion (warning 05:00:48); its durable
intent still recovered once as sequence 19. This does not prove writer takeover.
The 05:02:27 repeat recovered five more exact records as sequence 20, but its
diagnostic harness failed an assertion before saving complete handoff evidence;
that experiment is not counted as a takeover pass. Both left selected 63/offhand
3/empty cursor-grid and exact five-record effects, without silent deletion.

A separate uncertain-acknowledgment fixture reinstated precisely the already
committed sequence-20 intent (same inventory, UUIDs/destination receipt; no counter
rollback) in the leased writer. Actual Disconnect and prompt localhost reconnect
at 05:04:41, with delivery admission still blocked, demonstrably adopted the same
closing writer with a different fence and identical outbox. A private probe
observed login/recover before releasing admission. Replay then cleared the outbox
with the same world records, no new entities and empty cursor/grid in actual E.
This is an explicit recovery fixture, not a new item-creation action. Writer/region
disk stalls and uncommitted-delivery takeover are covered separately by ExUnit.

Only the fifteen pinned records were removed through durable region APIs; actual
world view cleared. Original inventory/pose were restored while retaining sequence
20, then a final orphan-save fixture used administrative raw `close` to save the
five cursor/grid stacks with no outbox. Actual localhost join 05:08:02 automatically
disposed of those stacks before configuration/play: source 20→21/cleared outbox,
exact five records, unchanged selected 63/offhand 3 and visible empty cursor/grid
after backward movement/E. Its five pinned records were removed, and original
empty inventory/pose were restored again while retaining 21 and receipts
`{-1,-1}:21`, `{0,-1}:20`. Final actual rejoin 05:09:26/E showed empty creative UI;
the player file is 151 bytes and no delivery job/outbox remains. Private client log
`.local/client-tests/VMC-005b2d2b/latest.log` has zero ERROR/codec/unknown-packet/
duplicate-entity entries in this validation window.

Fixtures establish contents/recovery ambiguity, not actual mouse pickup or recipes.
Keyboard disconnect/rejoin and server disconnect are actual client lifecycle
scenarios. Earlier mouse gates, removed/dead/dimension-transfer semantics and
stationary physics/pickup gaps remain explicit. Public-tree audit/exact diff were
reviewed before amending the unpublished checkpoint with this evidence. Subject:
`VMC-005b2d2b: journal disconnected cursor and crafting-grid cleanup`.
Branch `main`; earlier ancestor mouse gates remain pending before push.
