# VMC-015c — Player environment ticks and freezing

Status: Done within freezing scope; source `91caf387`. October 15, 2026.
Follows VMC-015a; supports VMC-015b.

Fix the observed powder-snow overlay that persists outside the block. Own freeze
state and a 50 ms logical clock in the player process. Obtain powder contact from
the same fenced body observations used by pose/movement; never assume missing air.

Acceptance: stationary/moving powder contact increments the bounded native freeze
counter, leaving cools by two per tick, armor/spectator immunity works, self/peer
metadata agrees, and saves/reconnect retain state. Reject stale/retired/expired
geometry and clock messages. Client packets cannot manufacture server ticks.
Actual client: enter powder, wait for overlay, walk/teleport out and visibly thaw;
reconnect, jump/flight and ordinary movement remain usable. Verify full cleanup.

Ordering: socket owner serializes accepted movement and tick receipts. A clock
token is single-use. At most one tick is pending; missed ticks coalesce rather
than accumulating jobs. Movement cancels background geometry and its fresh result
may satisfy the pending tick; idle freezing retries through the pose lane. Only
validated frames advance effects. Failed/stale frames preserve state and retry;
no region writes or cross-player effects occur. Ordinary warm stationary players
need no repeated geometry unless observations change. This leaves full forces,
fluid/fire effects, freeze damage and swept block-effect traversal for later work.

Reference: pinned 26.3 jar/hash from VMC-015a. `InsideBlockEffectType.FREEZE`,
`LivingEntity.aiStep/canFreeze`, entity frozen metadata/save/load and
`Entity.checkInsideBlocks` (deflated body). Private `.local/environment-*.javap`.
Native effect/accessor/metadata probes and targeted tests precede a frozen client
handoff. Completion requires reviewed client thaw evidence.

Implementation: `PlayerEnvironment` retains contact and 0–140 frozen ticks.
Fresh pose/movement results can consume one pending tick. Source failures preserve
state, and movement cancels background work. Warm idle players reuse the existing
invalidation path. Native item tags determine armor immunity. Frozen metadata is
sent to self/peers, including zero on exit; snapshot v7 retains the bounded counter
alongside fall/journal state and reads v1–v6. No freeze damage yet.

Checks: 167 affected tests pass, including stationary freeze/peer packets,
legal creative armor immunity, thaw on relocation and stalled/retired geometry.
Snapshot/recovery regressions preserve fall and freeze fields through pending
disconnect transfers. Native effects/accessors match 282 fixtures; cooling is
referenced to the inspected `LivingEntity.aiStep` branch, not claimed as a full
native entity tick. Mojang verifies 272 packed velocities and 50 entity packets,
including freeze counter boundaries. Evidence: `.local/environment-*.log`.
Exact targeted commands are retained in `.local/environment-checkpoint-commands.txt`.
Peer recreation regressions caught/fixed removal helpers and an older assertion
that omitted freeze initialization. All 527 tests, formatting and a separate
production release pass. Full native integration passes, including plaintext and
encrypted TCP. Logs: `.local/environment-block-{full-tests-final,native,production,format}.log`.

Actual client: dedicated tester, October 15, 15:13–15:17 CEST, frozen `91caf387`
(400 source blobs verified). Root reviewed the report, action samples, original
screenshots and all ten image hashes. Stationary contact reaches 140 with visible
ice; actual walking out clears the overlay without reconnect. The exit trace
captures 140→102; later owner state is zero and the screenshot is clear. A second
warm relocation trace captures the full 140→0 cooling sequence. Disconnect inside
powder saves 140; actual reconnect retains the overlay/counter. Flight ascends
64→73.2429→64, and spawn/walking work. Fresh client/server logs are clean.
Evidence: `.local/client-tests/VMC-015c/`, `.local/environment-root-review.txt`.
No graphical armor/peer claim or measured baseline jump arc. All six regions and
the whole source dataset are clean: no edits/items/receipts/pending transfers,
zero players, safe pose, fall/frozen/sequence zero, outbox nil and original oak.

Frozen warm loopback loads pass: 512 spread players / 51,200 moves / 5.153 s;
128 dense / 12,800 / 5.308 s. Both verify final positions with zero corrections or
disconnects. Cumulative tick lateness is 135,528/15,091 ms across 57,830/14,543
player ticks; these are preview workloads, not survival TPS or fastest-server
evidence. Raw: `bench/results/environment-{512-spread,128-dense}.json`;
exact source manifests: `.local/environment-load-revisions.json`.
