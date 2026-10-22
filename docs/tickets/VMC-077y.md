# VMC-077y — One transfer protocol, one retirement authority

Status: In progress
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077j1](VMC-077j1.md) (groups), [VMC-077j2](VMC-077j2.md)
(the regionizer), [VMC-077i3](VMC-077i3.md) (players in owners),
[VMC-077s](VMC-077s.md) (two-phase player handoffs), [VMC-077e](VMC-077e.md)
(unloads).

Before: the live fixes after VMC-077 (a6dab913, and parts of e06afee7,
635ad1fd, 72644707 and d049c6a0) work, but each added a mechanism of its own
beside the others:

- Sections move fire-and-forget (`Region.give/3`); the old group keeps a
  `moved` table (section key, epoch, storage owner and job monitors to the
  target, expiring after two minutes on a `forward_timer`) and forwards strays.
- Players move by a separate two-phase adopt, `{:player_held, …}`, release,
  with a replay buffer, `player_moves` forwards expired by `Host.tick`, and
  `moving` guards at about 13 sites of `Player.Host`.
- Groups without sections tick on a `:housekeep` timer and stop when
  `stoppable?` holds, which scans their own mailbox for adopts
  (`adopting?`, racy by design).
- `Host.tick` sweeps the player registry every tick for stale registrations.
- Connections poll `Directory.lookup` per section every 50 ms
  (`refresh_wants`) to notice restarted owners.
- A group forwarding a generation delivery for a moved section acks the
  scheduler's credit at once.

Folia needs none of this: tasks are addressed by location and its regioniser
alone creates, merges and retires regions.

## Design

1. **One authority.** The regionizer orders every section move (merges and
   splits, as before) and alone retires groups. A group left with nothing
   (no sections, players, leaving players or transfers) asks to retire; the
   regionizer agrees only when its own record of the group is empty, drops
   it from that record (so it is never picked again) and tells it to stop.
   A group whose record still holds sections is about to adopt them, and asks
   again once empty. Groups outside the regionizer (tests) stop on their own:
   nothing else hands them sections. No mailbox scan, no housekeeping timer:
   a group ticks while it has sections or players.
2. **One transfer.** `Region.transfer/4` moves sections and players to another
   group in one message: adopt, held, release. The sender sends only when
   what moves is quiescent (every frame durable, no checkpoint running; a
   player also without running session jobs), holding its own cuts for that
   moment, so no storage acknowledgement or checkpoint report ever needs
   forwarding. Until the target says held, the sender forwards what arrives
   for the moving players and keeps a copy; if the target dies first, its
   sections are gone with it (their route went too; their log has every
   frame) and its players resume where they were, replaying the copies in
   order. Players standing in moving sections ride the section's transfer; a
   teleport, a portal or a walk across a group edge moves a player alone
   through the same function. Workers' monitors are made again by the
   adopter.
3. **Strays by location.** A group that receives a message for a section it
   does not hold re-sends it on the Directory's current route (by key, chunk
   or epoch); one for a player it does not host goes to the player's
   registered host. A call to a stopped group gets the usual `{:retry, _}`.
   An adopt for a player whose section the target does not hold is refused,
   and the sender keeps the player. Deleted: `moved`, `targets`,
   `forward_timer`, `player_moves`, `player_claim` hops and their expiries.
4. **Registration follows hosting.** A player's `PlayerRegistry` entry is
   made when a group hosts it and removed when it releases it (after held, or
   once a leaving player's file holds its last frame), always through
   `Player.Storage`; no per-tick sweep.
5. **Holders watch, not poll.** A connection monitors the groups it told its
   tickets to and tells its view again when one stops; a ticket withdrawal
   that reaches a group the section left is re-routed. The scheduler's credit
   for a delivery is acknowledged by the group that installs it, for the
   group it was sent to.
6. **No `moving` guards.** Moving players live in the transfer, not in
   `players`. A clean stop cuts every hosted player's last frame.

Riding along: `World.Jobs` slot workers are monitored like every other job
(one failure path, `:DOWN`), and a slot whose worker is killed is freed by its
owner; `Player.Movement` loses its per-correction `Logger.info` and the
`relocate/4` stack trace; the movement query cap is exposed once by the
kernel instead of `65_536` beside Rust's `QUERY_CELLS`; spectators skip rain
sampling instead of `RainQuery.sample/4` special-casing them.

## Acceptance

- The design above, with net fewer lines in `lib/`.
- Behaviour unchanged: handoff, portal, regionizer, region, host, connection
  and login tests with `--include tcp`; `mix test.fast`;
  `check_vanilla.py --changed`.
- `bench/outrun_flight.exs` at 116 blocks/s shows no regression.
- `docs/architecture.md` describes the one protocol.
