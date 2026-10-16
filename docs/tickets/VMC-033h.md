# VMC-033h — Bounded bulk result dropping

Status: Done within ordinary bulk-result scope. October16,2026; `f1db8f0`.
Parent: VMC-033; precedes remainder composition.

Acceptance: actual Ctrl+Q on an ordinary player/table result repeats the native
recipe until output identity changes or inputs run out. Bound each plan/journal to
five records and continue asynchronously on its player owner. Serialize later
table clicks, freshly admit each table batch and honor close/removal/death. Crash/
reconnect preserves each committed conversion and cleans remaining owned inputs
without replay. No expanded generic transfer budget or unbounded owner loop.

Implementation: pure plans emit at most five whole recipe outputs. The connection
continues after durable delivery/completion; table batches receive a fresh owner
decision. Later table clicks stay queued. Close/removal/death cancel future batches;
player-menu close now waits for an active source write before returning unspent
inputs. Continuation is ephemeral: restart recovers committed output and cleans
unspent inputs, without replaying the gesture. Canonical source authorization
replays each exact bounded recipe plan.

Original private `.local/RemainderBulkProbe.java` observed3,136 actual menu traces
including an ordinary oak-planks control. Ctrl+Q over99 logs creates99 four-plank
records, consuming all inputs in both permissions. Remainder combinations reach491
records, confirming the continuation requirement; those recipes remain VMC-033g.
Raw `.local/remainder-bulk-native.{json,log}`; pinned26.3 jar revision in VMC-033g.

Native/targeted checks first: both menu sizes, input counts and output-identity
boundary, finite batches, ordinary gestures, source/destination crashes and closing
between batches. Actual client: Ctrl+Q17 logs into68 planks, observe completed drops
and empty grid, close and reconnect without repetition. Table variant includes
removal/close cancellation; public checkpoint remains local until client validation.

Checks:47 targeted tests passed (seed529916), including both menu sizes/permissions,
five-record boundaries through99 inputs, cursor/patch/output identity, journal
forgeries, TCP repetition/FIFO, close/removal/death interruption and crash after
the first prepared source. Original `CraftingBulkOracle` observed3,392 native
menu traces across1,180 table/476 player recipe profiles and focused repeated/cursor/
changed-recipe cases. Bounded Elixir plans match effective components, exact counts,
visible/physical storage and ordered drops. Full native integration now includes
this probe. Raw `.local/{bulk-crafting-final-targeted,crafting-bulk-native,
crafting-bulk-check}.log`; facts `.local/crafting-bulk-native.json`. Formatting and
changed Python syntax pass.

Frozen `f1db8f0` production and three actual-client scenarios passed: player/table
Ctrl-Q17 logs each, wrong cursor, real Escape before the first prepared batch
committed, and fresh reconnects. Cancellation committed exactly five crafts and
returned12 logs. Two induced writer-pause/save-timeout attempts were recovered;
their two legitimate log17 cleanup records remain. The final bounded observer
captured uncommitted five-record prepare and actual close, then resumed the writer
without changing production deadlines. Report `.local/client-tests/VMC-033h/report.md`.
All722 frozen blobs rehashed; `.local/bulk-crafting-proof.json` pins evidence.
Original snapshot/90 scene cells restored except sequence84/nil; all78 prior and
41 new records retained, receipts84/6/9/68, all clients stopped.

Menus/recipe counts passed. Near-camera overlapping dropped-item planes prevented
confirming natural item appearance or counting individual entities visually;
authoritative records establish exact counts. [VMC-018c3](VMC-018c3.md) tracks this
separate observation; no rendering diagnosis or regression claim.
