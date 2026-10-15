# VMC-015c — Player environment ticks and freezing

Status: Implementation checkpoint; client gate pending. October 15, 2026.
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
The peer recreation regression caught/fixed removal helpers that still expected
the older observation tuple after freeze metadata was added. Broad integration
and the actual-client gate remain pending at this checkpoint.
