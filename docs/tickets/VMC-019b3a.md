# VMC-019b3a — Bounded automatic outbox recovery before login

Status: Done
Note: Done — automatic login recovery validated. Updated: October 14, 2026. Depends on VMC-019b2. First slice of session orchestration; drop controls remain.

## Scope and acceptance

Before: a valid pending outbox rejects login and needs manual API recovery.
After: login retains the UUID writer lease and asynchronously delivers that exact
intent, verifies/clears its source, then initializes the client with depleted
inventory. Inventory/login success must not publish before recovery completes.

- Run destination calls in a supervised I/O task pool bounded at four times the
  scheduler count, separate from region CPU preparation. At most one active job,
  one bounded retry timer and one overall ten-second deadline per recovering
  session. Saturation/busy/restarting owners use capped backoff without a queue.
  Pin source UUID/sequence/records/region; never allocate new UUIDs/sequences on a retry.
- Keep socket processing and unrelated identities responsive. Fence worker
  results by PID/token/monitor; fence retry/deadline messages. Worker loss may
  mean delivery committed: retry only the identical durable intent. Source clear
  remains an asynchronous leased writer request with exact destination proof.
- Source inventory remains unavailable to gameplay until successful source clear;
  update its fence and creative-session permission from owner state, then perform
  the existing compressed login/configuration flow. No synchronous destination
  I/O in a socket callback. No global gameplay recovery coordinator.
- On invalid/conflicting/stale intent, corrupt/ephemeral destination, deadline,
  storage loss or disconnect, preserve the actual source file and release its
  lease after its writer finishes. Terminate outstanding jobs/cancel timers.
  Delivery may finish without a reply; subsequent login deduplicates it. Never
  roll old inventory over a possible source/region commit.
- Tests cover pending-before-delivery recovery, already-delivered recovery,
  removed-item retry, source clear/fence, capacity/backoff/saturation, stale events,
  worker/owner loss, deadlines, corrupt/conflicting/ephemeral destinations and
  unrelated session health. Existing rejected-login test gains automatic success
  expectations; format/full tests/release/full Mojang oracle/audit must pass.

Actual Minecraft 26.3 via CUA: disconnect; prepare an offline stone-7 fixture into
retained 4 + a stone-3 pending outbox. Actual login must recover without a manual
delivery call, display HUD 4 and a rendered item, and clear the source. Restart/
rejoin and confirm no additional entity. Remove that item, restore the same
sequence/depleted-inventory pending snapshot to model a lost source clear, then
actual login must clear it without recreating the removed item. Restore empty
fixture inventory while retaining the advanced sequence/receipts and inspect logs.

## Design and references

VMC-019b1/2 pin Mojang 26.3 and the reference revisions/classes. Recovery is original
BEAM infrastructure; vanilla item lifecycle/ownership, not a rewrite's omission,
defines the item-conservation target. A region receipt remains after item removal
and cannot be substituted with an ETS replication view. The per-UUID writer owns
the source sequence/fence; socket ownership coordinates asynchronous transitions.
No source/jar/decompiled code is copied. Existing source fields/codecs are reused.

The existing login timeout remains an outer bound. Recovery has its own shorter
deadline. Source/destination file sync/rename still lacks parent-directory/power-
loss qualification. Physics, pickups, menu/disconnect drops, actual Q controls,
safe receipt retirement and complete vanilla gameplay remain required. VMC-019b3b
will use this delivery loop for connected-session transfer gating/drop controls.

## Verification

October 14, 2026, Elixir 1.20.4 / OTP 29.1.1, actual Minecraft Java 26.3:

- Format and all 163 tests pass, seed 709526. Eight new integration regressions
  cover already-delivered/removed recovery; unpublished stalled delivery and
  responsive sockets/healthy peer; stale worker/timer/completion replies; UUID
  lease exclusion; worker loss after submission; I/O pool saturation; deadline/
  disconnect cancellation with possible later region commit; corrupt/ephemeral
  target preservation; conflicting/superseded source rejection. The old pending-
  login rejection test now verifies automatic delivery/clear before inventory.
- Production release and full Mojang codec/TCP oracle pass, oracle 02:07:19.
  Existing login/configuration/inventory/entity packets/codecs remain unchanged;
  login success is delayed until the writer proves source completion.
- I/O pool maximum is four times scheduler count (40 on this machine), separate
  from CPU preparation. One job/retry timer/deadline per recovering session; capped
  50–500 ms backoff and twenty retries inside the ten-second recovery deadline.
  Worker/token/monitor and retry/deadline fences discard stale work. Tests control
  actual stalled writers/job death and deadline delivery; they are not throughput
  measurements. No fastest-server or power-loss durability claim follows.
- Initial CUA observation required app rebinding/exposed Raise after
  `cgWindowNotFound`. Actual keyboard Disconnect released the previous lease.
  Updated release started 02:09:36 in the disposable temporary world. Offline
  source prepare checkpointed patched stone 7 and reduced it to retained 4 plus
  pinned stone 3, source sequence 2 (309-byte pending file). No destination fixture
  was manually created before the actual login.
- Actual CUA join 02:09:55 recovered automatically, displayed HUD count 4 and a
  glint item model. Read/source/owner/file assertions confirmed the exact UUID/
  XYZ/patches, world stack count 3, one entity, source sequence 2/no outbox. A later
  exact destination retry was already-applied. The numeric world count comes from
  owner/codec state; screenshots independently establish rendering and HUD count.
- Full restart 02:10:22 and actual rejoin 02:10:50 retained inventory/rendering and
  one exact entity; no source counter regression or second creation occurred.
- Region removal visibly cleared the item. After actual Disconnect, the same
  sequence 2/pinned request/depleted inventory pending snapshot was restored as a
  controlled uncommitted-clear fixture. It did not restore inventory 7 or lower
  the source sequence. Actual join 02:12:35 cleared it automatically without a
  manual delivery/completion call and left zero records/views, HUD 4, source
  sequence 2/no outbox/no remaining I/O job. The receipt stayed authoritative.
- Cleanup through the leased writer restored original empty inventory/pose while
  retaining sequence 2. The player file is 151 bytes. Final actual join 02:13:48
  showed empty hands/hotbar and no item. No item fixture remains; receipts persist.
- Private `.local/client-tests/VMC-019b3a/latest.log` has zero Network Protocol
  Error, DecoderException, EncoderException, Duplicate entity or ERROR entries.
  Public-tree audit/self-checks and exact diff review pass.

Next: connected-session transfer admission/mutation gating and actual keyboard
drop controls. Physics, pickup/merging/despawn, menu/disconnect lifecycle, safe
receipt retirement and full vanilla compatibility remain incomplete. VMC-019b3
and the full goal are not complete.

Subject: `VMC-019b3a: recover pending item transfers asynchronously before login`.
Branch: `main`; retain earlier ancestor mouse-validation gates before push.
