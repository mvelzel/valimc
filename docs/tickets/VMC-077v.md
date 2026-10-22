# VMC-077v — Spectators fly into chunks not loaded

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077l2](VMC-077l2.md) (one physics-kernel call per move
packet).

Before: the movement kernel failed closed on any cell it could not read, so a
spectator flying into a chunk generation had not reached yet was corrected
(`movement correction: geometry {:missing_block, …}, mode spectator`) and
teleported back. `bench/outrun_flight.exs` showed it once at 116 blocks a
second, view distance 32 ([VMC-077u](VMC-077u.md) follow-up).

Vanilla (26.3 jar `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`, decompiled
privately):

- `Player.tick` sets `noPhysics = isSpectator()`.
- `ServerGamePacketListenerImpl.handlePlayerPositionChange` accepts the move
  whenever `player.noPhysics`, before the "moved wrongly" and
  `isEntityCollidingWithAnythingNew` rules; only "moved too quickly" (which
  does not exempt spectators) can still teleport it back.
- `Entity.move` with `noPhysics` only adds the delta: no collision reads.
- Otherwise collisions skip chunks not loaded (`Level.getChunkForCollisions`
  asks `getChunk(…, FULL, false)`), and fluid contact skips them
  (`hasChunksAt`).

Now:

- The kernel reads a spectator's moves and resting ticks through
  `AirWhereUnreadable` (`physics::source`): a cell it cannot read is air, so
  the move is accepted with its pose, fluids and landing as if the absent
  chunks were empty. Every other mode still fails closed.
- A spectator's rain sample reads a column not loaded as dry
  (`RainQuery.sample/4`); spectators cannot burn, so nothing reads it.
- "Moved too quickly" still applies to spectators, as in vanilla.

Acceptance: a spectator moves from a supplied frame into cells outside it and
is accepted; a creative player making the same move gets
`{:missing_block, _}`; the spectator's resting tick there samples
(`test/player_kinetics_test.exs`).

Checks: `test/player_kinetics_test.exs`, `test/player_motion_query_test.exs`,
`test/player_rain_query_test.exs` (13 of 13 with `--include tcp --include
slow`), `test/game_mode_connection_test.exs`, `test/player_abilities_test.exs`
and `test/portal_test.exs` (10 of 10); `cargo test -p valimc_core` 95 of 95;
`check_vanilla.py --changed` 73 of 73 stages; `audit_public_tree.py`.

Client: none (the next flight at view distance 32 covers it).
