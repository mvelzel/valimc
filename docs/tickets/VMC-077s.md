# VMC-077s — A group's tick costs what changed

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077f](VMC-077f.md) (keyed frames), [VMC-077j1](VMC-077j1.md)
(groups), [VMC-077e](VMC-077e.md) (simulation tickets).

Before: a live test at view distance 32 (simulation distance 10, fast
flight over fresh vanilla terrain) saturated the player's group process: its
mailbox passed 1,500 while the host idled, inputs applied in bursts and
corrections followed. Two costs grew with the state, not with the tick's
work:

- `ScheduledTicks.take_due/3` popped every due tick of a chunk outside
  simulation from one gb_set and added it back, every tick; at view distance
  32 nearly every loaded chunk is outside simulation and fresh terrain brings
  thousands of fluid ticks, so each section churned up to its 65,536 cap each
  tick. `rebase/2` dumped and reloaded them all; the cap silently dropped
  generation ticks.
- `RegionStorage.diff_parts/2` rebuilt every record of a part (ticks, items,
  containers, block entities) and diffed the maps whenever anything in the
  part changed; the tick queue changed every tick, so every section paid
  O(state) every tick.

Acceptance:

- Scheduled ticks are vanilla's `LevelTicks` shape: one container per chunk,
  a tick takes due ticks only from the simulated chunks' containers (in
  vanilla order across them, at most 65,536 a tick), and the others are never
  touched. No cap on how many a section holds. Dues are relative to a shift,
  so a rebase is O(1) (one `{:ticks, :shift}` record). Generated chunks'
  ticks are scheduled in one batch per chunk.
- A frame is built from what changed: the scheduled ticks' journal of touched
  pairs, and for items, containers and block entities only the entries that
  are not the terms last committed (an unchanged entry compares by identity).
  The motion and counter deferral keeps its rules.
- `bench/group_load.exs` before and after (raw results kept, untracked, in
  `bench/results/group-load-*.json`).

Measurements (`bench/group_load.exs`, 40 s, one creative player flying east
at a block a client tick, view distance 32, simulation distance 10, fresh
vanilla world; the host process sampled every 50 ms):

| | Before (834fdccf) | After |
|---|---|---|
| Group ticks in 40 s (800 expected) | 72 | 753 |
| Tick time p50 / p95 / max | — / 640 / 1,511 ms | 4.4 / 9.7 / 89 ms |
| Group mailbox p50 / p95 / max | 2,034 / 4,893 / 5,461 | 0 / 265 / 584 |
| Group reductions per second p50 / p95 | 44.9 M / 219.5 M | 3.4 M / 23.7 M |
| Distance flown | 783 | 781 |

The remaining mailbox peaks come with generation: installing generated
chunks, their light and their packets' encodes. Batching the generated
ticks took most of the install's share.

## Player hosting after the live recheck

The live recheck (dev server, view distance 32, fast spectator flight, leave,
rejoin far out) lost the player: the rejoin loaded nothing, the next leave
logged "Player state final save could not complete", and every later login
failed with "Player save unavailable". The registry still held the player for
a group with no sections and no players, whose only entry was a move to a
group that no longer existed; no crash was logged.

Cause: a handoff was fire-and-forget. `Host.hand/3` sent the session to the
target and dropped it. A target can stop normally (its last section
unloaded, `idle?` true) with that adopt, or a section's, still unread in its
mailbox: `hand_over` checks the target is alive just before. The session was
then gone, the connection still addressed the old group, which forwarded to a
dead process, and only the target's `{:player_held}` would have released the
registration. A group without sections never ticks, so its moves never
expired and it never stopped.

Fix:

- A move is two-phase. The group keeps the player (marked moving), monitors
  the target and forwards what arrives for it there, keeping a copy (at most
  4,096, else the player is disconnected rather than replayed in part). It
  lets go only on `{:player_held, uuid, target}`. On the target's DOWN before
  that, the target ran nothing forwarded (it holds before it runs anything),
  so the group resumes the player and replays the copies in order, calls and
  leaves included. A moving player is not ticked, cut, checkpointed,
  published or ended by a clean stop: it is the target's.
- No group stops while an `{:adopt, ...}` or `{:adopt_player, ...}` waits in
  its mailbox.
- A group without sections runs what its tick does for players and forwards
  on a 1 s timer, and stops once idle.
- Every group tick (or that timer) releases registrations the group no longer
  backs by a hosted, moving or leaving player.
- A connection re-tickets owners that restarted on every 50 ms chunk tick, not
  only while chunks are pending, so a section whose group died loads again
  under a player that already had all its chunks.

Vanishing chunks: a scripted spectator flight across three groups (view
distance 2) gets no respawn, no correction and no forget of a chunk still in
its view, and ends with every chunk of its view; a group move does not reset
the client's view. The lost session above also froze the player server-side
while the client flew on, past the chunks it had. `bench/group_load.exs` (now
a spectator, through terrain) also reports how far the last chunk center sent
trails the client: within 2 chunks (p95 1) of view distance 32 at a block a
client tick, 781 blocks in 40 s. There the regionizer merged each section
the flight reached into the player's group (60 section handoffs, no player
handoff).

Regression tests (`test/player_handoff_connection_test.exs`): a target killed
with the player unread in its mailbox (and a call made meanwhile) leaves the
player with its group, which runs the call, moves the player on once the
section loads again, and a leave and rejoin work; a group without sections
whose move expired releases its registration and stops without a tick; the
flight above. The first two fail before the fix.
