# VMC-077y — One transfer protocol, one retirement authority

Status: Done
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

## Implementation

- `Region.transfer/4` is the one protocol. `hand_over/3` (the regionizer's
  merges and splits) and `move_player/2` (a hosted player standing outside the
  group's sections) queue a request; the group cuts and sends what changed,
  then sends nothing more until no frame it sent is in flight
  (`RegionStorage.sending?/1`), so the wait is one group commit. Frames cut
  meanwhile ride along in the moving storages and the target sends them.
  `RegionStorage.held?/2`, the per-frame `routes` and their syncs are gone:
  a storage's frames are only ever in flight on one stripe.
- The target answers `{:held, ref}` or, for a player whose section it does
  not hold, `{:refused, ref}`; the giver resumes on a refusal or the target's
  `DOWN`. Moving players live in the transfer record, so `Player.Host` has no
  `moving` guards, no `player_moves`, `player_claim` hops or registry sweep. A
  player moves only when `movable?/1` (no session job), and its session's
  pose sources are watched again by the target (`adopted/1`).
- Strays: `Region.elsewhere/3` routes by key or epoch
  (`Directory.epoch_owner/1`, a scan of the routes for strays only); a call is
  relayed with `:gen_server.send_request/2`, so the group its caller watches
  stays until the answer passed through (a group with relays is not idle).
  A call that finds its group stopped never ran: one naming an epoch is made
  again at that epoch's route (`Region.call/3`; box edits and placements
  holding a handle across a merge failed under load without it), others get
  the usual retry, and the portal reader's region wait now retries any retry
  error until its deadline. Player strays go to
  `Player.Storage.host/1`.
- Section timers (`{:resource, epoch, …}` sent to the group that armed them)
  are armed again by the adopter (`RegionData.adopted/1`: waiting encodes, the
  item handoff's wake, the generation retry, job deadlines in `Jobs.watch/1`):
  the group a section left may retire before they fire there. The first test
  run without this stalled logins: encode waiters and a generation retry
  waited for timers lost with a retired group.
- Retirement: `Regionizer.retire/1` and `handle_cast({:retire, pid})`; a group
  ticks while it has sections or players. Each tick also checks a waiting
  transfer, since a section's own save (an unload) can take the last
  acknowledgement it waits for.
- Jobs: a worker reports to its section's current group (`:reply_to`, a
  Directory lookup when the work is done: the group that started it may
  have retired). Every worker is monitored with a tag of its section's epoch
  (`wrap.(:job_down)`), so a DOWN reaches the section by its route; a report
  demonitors without a mailbox scan and the late DOWN is ignored. The
  adopter keeps the old owner's monitors and ignores a `:normal` or
  `:noproc` DOWN of its own, since the report, or the old owner's DOWN,
  follows (`world_test` saw a second encode, then lost reports, without
  this). A slot worker frees its slot itself, or its owner does when it was
  killed (`test/world_jobs_test.exs`).
- Connections monitor the groups they told (`:wanted_owner_down` tag) and
  re-tell the view when one stops. Generation deliveries for moved sections go
  on with `{:generated, scheduler, part, credit}`; the installing group acks
  with `Scheduler.delivered/2` for the credit's account.
- Known window, as before: a change spanning a moving and a staying section,
  cut while the transfer waits for its last commit, is durable in two records.

Tests changed: a stale handle to a group that retired is retried
(`region_group_test`), re-routing by epoch is checked after a split, the
handoff test checks that a rider's registration follows it and the emptied
group retires, the regionizer test resumes the regionizer before the stray
group can retire, and `TestRegion.section/1` follows a section's route.

## Results

- `lib/` and `native/`: 803 lines added, 806 removed. Deleted: the `moved`
  table, `targets`, `forward_timer`, the housekeeping timer, `stoppable?` and
  `adopting?`, `player_moves`, `player_claim` hops, the per-tick registry
  sweep, `moving` guards, `refresh_wants`, `RegionStorage.held?/2` and the
  per-frame routes, the slot workers' `{:job_down, …}` path, the movement
  log lines and the `65_536` beside `QUERY_CELLS`.
- Final code: the handoff, portal, regionizer, region, connection, login and
  world suites with `--include tcp --include slow` (281 tests), `mix
  test.fast` (412), `cargo test -p valimc_core physics`, and
  `check_vanilla.py --changed` (8 of 8 stages; 13 of 13 on an earlier
  revision of the same change).
- `bench/outrun_flight.exs`, 150 s at 116 blocks/s, seed 20261020, view
  distance 32, `OUTRUN_SAMPLE=groups`, base ab6412c1 and this branch
  interleaved on a host shared with another session's flights (load 16 to
  40); raw results kept untracked. Round 1 ran an earlier revision (before
  location-addressed job reports and the stale-call re-route), round 2 the
  final code:

| | Base | VMC-077y |
|---|---|---|
| Round 1: blocks flown | 8,706 / 10,011 / 9,738 | 9,622 / 9,239 / 10,585 |
| Round 1: own chunk missing max | 2,240 / 4,970 / 7,856 ms | 1,097 / 2,456 / 1,070 ms |
| Round 2: blocks flown | 10,753 / 11,728 / 9,982 | 14,419 / 10,098 / 10,231 |
| Round 2: own chunk missing p90 | 294 / 236 / 313 ms | 38 / 361 / 317 ms |
| Round 2: own chunk missing max | 1,136 / 2,099 / 3,859 ms | 1,056 / 2,600 / 2,681 ms |
| Round 2: pool busy while wanted | 78 / 79 / 80 % | 80 / 80 / 79 % |
| Round 2: largest group mailbox median / max | 23 / 170, 13 / 163, 19 / 182 | 31 / 193, 24 / 187, 19 / 178 |

  No regression: flight and generation numbers are within the runs' spread;
  the largest group's median mailbox is a few messages higher (each job's
  monitor now reports through it).
- Flaky under heavy host load, passing alone: `CookingOrbConnectionTest` (an
  orb picked up before the item: 2 loaded runs failed, 5 of 5 alone and on
  base). `PlayerStorageTest.Connection` removed its world while spawn groups
  still wrote to it (also on base, 2 of 8): its teardown now stops them.

## Client

October 22, 2026, Java 26.3 against a frozen release of 91413583, seed
20261020, client render distance 4 (ignored
`.local/client-tests/VMC-077y`): PASS.

- Baseline: join at spawn, terrain renders, `/stats` answers.
- Fast spectator flight, about 68 blocks/s for 66 s (about 4,480 blocks, 35
  sections): no snap back, no loading screen, no disconnect; terrain keeps
  arriving.
- Leaving far out and joining twice more: each login lands at the far
  position, with no "final save could not complete" and no "Player save
  unavailable".
- Twelve teleports between points 3,000 blocks apart (a player moving alone
  between groups): every arrival renders; a block placed and broken at the
  last two.
- Nether portal travel there and back, twice: the inventory is unchanged.
- The server log has no error or warning for the whole session.

Found while building the portal frame, older than this ticket: a placement
whose clicked block and target cell lie in different 8 × 8 sections is
refused (`Player.Placement.plan/2`, `:cross_owner_placement`), even when one
group holds both. Vanilla places across any boundary; fixed by
[VMC-077z](VMC-077z.md).
