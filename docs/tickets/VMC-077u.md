# VMC-077u — Generation follows the player

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077n](VMC-077n.md) (one generation scheduler per dimension),
[VMC-077t](VMC-077t.md) (flight without storage stalls; this ticket measures
on top of it).

Before: in a live flight at view distance 32 (spectator, about 58 blocks a
second, fresh vanilla world) the dirty schedulers peaked at 0.35 with a pool
of 8 on 10, normal schedulers at 0.05–0.15, and the world vanished for
seconds whenever the player's own chunk was missing (the vanilla client draws
nothing then: `SectionOcclusionGraph` only propagates through loaded chunks).

Causes (`bench/outrun_flight.exs`, below):

- **Wants arrived late, in bursts.** Generation was not underfed by its own
  scheduling: while it had wanted chunks the pool was about 80 % busy. For
  seconds at a time it had none, while the player flew on, and then got a
  thousand at once. Wants come from the regions' tickets, and a connection
  sent two ticket messages to every section of its view (about 80 at
  distance 32) on every chunk it entered, only to move their centers, the
  sole input of priority. They filled the group's mailbox (about 6,000 of
  its 7,000 messages at the end of a flight) ahead of installs and of the
  player's own input. VMC-077t made that one message per group; the group's
  synchronous checkpoints on unload (also VMC-077t) stalled it as well.
- **Chunks were made twice or more.** A region whose mailbox still held a
  full chunk wanted it again with its next ticket change, and the scheduler
  made it again ("a chunk it newly wants that was already sent is sent
  again (it lost it)"): 1.2–3.4 full-chunk jobs per installed chunk.
- **Priority was the ticket's center.** The player's own chunk went first
  only once the group had read the ticket of the chunk the player had
  entered, behind everything in its mailbox.

Not a cause: decoration conflicts along the moving front. Decorations
within two chunks run in number order (Z outer, X inner per request), so a
strip of new chunks is a chain, but successive strips pipeline: in a model
of the rule at distance 32 the longest chain grows by three to six
decorations per chunk crossed (headings 0°, 45° and 115°) while each crossing
brings 65 to 130 new decorations, so a moving front offers about 20 that can
run at once. Renumbering (for example
by 3 × 3 classes) would also change the order the vanilla live check
compares (`check_live_decoration.exs` numbers each region Z outer, X inner
as the oracle decorates it), so the numbering stays.

Design:

- **Focus.** A connection tells its dimension's scheduler which chunk the
  player entered and which way they move (`Scheduler.focus/5`: the unit
  vector of the move since the last chunk, none after a jump of more than
  64 blocks), at every chunk entered, straight from the connection: one
  message, not routed through any group. The scheduler monitors the
  connection and forgets it when it exits, changes dimension or the
  scheduler restarts (the next chunk tells the new one).
- **Priority from focus.** While any player is in the dimension, a wanted
  chunk's priority is its score from the nearest player: 0 for the player's
  own chunk, else four times its squared distance weighted by direction, a
  quarter of it straight ahead and seven quarters straight behind
  (`Frontier.score/2`). Calls that wait for a chunk (-1) stay first; wants
  from where the player was drop behind those near where it is now. The work
  a wanted chunk needs inherits its priority as before: the terrain of its
  3 × 3, its own decoration and those of its neighbours, and every earlier
  decoration they wait for (VMC-077n's `needs`), so the own chunk's whole
  dependency set jumps the queue. Running jobs are not preempted; with 8
  slots one frees within tens of milliseconds.
- **Tickets only where chunks change.** A view tells a section again only
  when the chunks its tickets cover (loading or simulated) change, or its
  owner changed; the center alone no longer orders anything.
- **Nothing sent twice to one mailbox.** The scheduler remembers, per
  requester (a group and section key) and epoch, the chunks it sent that the
  requester's wants may still name, and leaves them out of its next wants;
  they are on their way, in order. A section loaded again has a new epoch and
  gets them again; a section moved to another group is another requester.
- **Gauge.** `worldgen_wanted_<dimension>`: chunks wanted and not sent yet,
  so a pool's occupancy can be read against wanted work.

Acceptance:

- With a player in a chunk moving east, the chunk it is in starts first,
  then the chunk ahead before the one beside and the one behind, whatever the
  regions' priorities; a waiting call stays first; a forgotten player orders
  nothing (`worldgen_frontier_test.exs`).
- A region that wants a chunk again before reading it is not sent it again;
  a new epoch is (`worldgen_scheduler_test.exs`).
- Measured below: no duplicate full chunks; at the live run's speed no chunk
  the player enters is missing; the pool is busy while chunks are wanted.

Measurements: (October 22, 2026, `MIX_ENV=bench`, 10-core host shared with
other sessions at load 7 to 15; `bench/outrun_flight.exs`: one loopback
spectator at view distance 32, flying 40 s at heading 115° (the live run's)
over a fresh world of seed 20261020, a fresh world each run, acknowledging
at 64 chunks a tick and, as the vanilla client, standing still while its own
chunk is missing; before is e06afee7 (VMC-077t) with only the wanted gauge
added, after is this ticket; raw results in ignored
`bench/results/outrun-077u-*.json`; two runs each):

| | 58 blocks/s before | after | 116 blocks/s before | after |
|---|---|---|---|---|
| Chunks entered / missing on entry | 181, 184 / 0, 0 | 183, 182 / 0, 0 | 195, 216 / 95, 105 | 219, 191 / 109, 81 |
| Missing time, median of the missed | — | — | 146, 129 ms | 113, 185 ms |
| Missing time, p90 / max | 0 / 0 | 0 / 0 | 280, 252 / 1,028, 924 ms | 246, 340 / 604, 1,617 ms |
| Full-chunk jobs per installed chunk | 1.24, 1.15 | 1.03, 1.03 | 3.44, 3.40 | 1.10, 1.09 |
| Generation CPU per installed chunk | 16.0, 15.6 ms | 15.4, 16.1 ms | 21.3, 19.4 ms | 17.1, 20.4 ms |
| Wants received | 2,573, 2,585 | 2,525, 2,490 | 4,071, 4,401 | 3,571, 3,172 |
| Pool busy while chunks are wanted | 81 %, 80 % | 79 %, 80 % | 75 %, 77 % | 77 %, 76 % |
| Dirty CPU schedulers busy | 42 %, 40 % | 41 %, 42 % | 52 %, 54 % | 50 %, 51 % |
| Chunks generated per second | 254, 255 | 255, 254 | 285, 319 | 318, 276 |

At 58 blocks a second generation keeps up whole: 255 chunks a second is
what the flight needs. At 116 it cannot (2,500–2,900 of 4,640 blocks
flown, the player waiting at the edge about half the chunks it enters), and
the player's own chunk arrives a median 0.1–0.2 s after the player enters
it, at most 0.6–1.6 s. Here duplicate full chunks took a third of the pool's
full-chunk work; without them each installed chunk costs about 8 % less
generation CPU. With VMC-077t's ticket batching in place the centers were
already fresh, so the order changes little in this straight flight: the
own-chunk times before and after are within run-to-run noise. The pool's
occupancy while chunks are wanted is bounded by the work that can start:
terrain never takes the last of the 8 slots, and decorations wait for
earlier ones.

On a6dab913, before VMC-077t (same bench without the vanilla client's
standing still, single runs): the largest group's mailbox reached 7,300 and
held 6,092 tickets at the end of a 58 blocks/s flight, the scheduler saw no
wanted chunk in 85 of 147 quarter seconds of flight, and full-chunk jobs ran
1.7–2.5 per installed chunk; with this ticket's changes alone the mailbox
peaked near 1,000 with 144 tickets and full-chunk jobs ran 1.06 per chunk.

Checks: on the rebased tree (after eb774cdf): `test/worldgen_frontier_test.exs`
(4) and `test/worldgen_scheduler_test.exs` (9), and with them the region,
view, connection and regionizer files that send or read tickets, 48 of 48
with `--include tcp --include slow`; `mix test.fast` 409 of 409;
`check_vanilla.py --changed` 10 of 10 stages (live generation, tcp, spawn
and world settings among them); `audit_public_tree.py`.

Client: none per slice; the next player-visible milestone run flies at view
distance 32.

Follow-ups:

- The server refuses a spectator's move into a chunk not generated yet
  (`movement correction: geometry {:missing_block, …}, mode spectator`) and
  teleports it back, at 116 blocks a second in the bench. Vanilla spectators
  have no physics; whether a move into an unloaded chunk is refused belongs
  to movement.
- Installs (`put_columns`, `LightHalo.handle`, scheduled ticks) are the
  group's largest remaining cost while flying; a delivery could carry every
  chunk finished for a section since the last one, for one install.
