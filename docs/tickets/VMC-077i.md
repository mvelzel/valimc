# VMC-077i — Players in owners

Status: Awaiting client
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) (D1 option C, D2, phase 3),
[VMC-077f](VMC-077f.md) (the shared log), [VMC-077g](VMC-077g.md) (owner
skeleton), [VMC-077h](VMC-077h.md) (entity store, handoff, trackers),
[VMC-077j1](VMC-077j1.md)–[VMC-077j3](VMC-077j3.md) (groups, regionizer,
locality), [VMC-077k](VMC-077k.md) (living), [VMC-077l2](VMC-077l2.md)
(movement checks in Rust).

Before: the connection process owns the player: its body, inventory, living
state and open menus, in one 91-key map that about twenty modules read and
write. Every interaction with the world (pickup, drops, mining drops,
placement, chest, furnace and crafting-table clicks, XP pickup, death drops)
is a cross-owner transaction: a player-side intent, a region-side permit and
request, a journal in the player store, delivery, a receipt and a completion,
about 5,400 lines in per-feature families plus their orchestration.

Goal: the group owner holds the player's body, inventory, living state and
open menus. The connection keeps sockets, framing, codecs, encryption and
compression, chunk streaming and the view, and per-player work that touches
no shared state. Interactions are plain calls inside the owner; a player's
record is a keyed record in its owner's per-tick frame (D2), so both halves of
a pickup commit together.

Design:

- **Durability.** An online player is a storage owner of its own,
  `{:player, uuid}`: its records ride in the frames of the group that hosts
  it, in the same `Log.commit_group/4` record as the sections' frames, and its
  checkpoint is the player file (`Valimc.Player.State` records). Recovery
  replays player frames into player files. A group crash rolls its players
  back to their last durable frame, consistently with what they touched.
  As built, the crash disconnects them: their clients hold state newer than
  what is durable (chunks, inventory), so a fresh login is the consistent
  resync, and it loads every durable frame.
- **Where a player lives.** In the section it stands in, inside its group.
  Crossing a section inside the group moves it in the group's commit;
  crossing to another group moves it as a section moves (state by message,
  the storage owner's frame sequence continuing).
- **Packet flow.** The connection decodes each packet and forwards play
  input to its owner as `{:player, uuid, {:input, id, payload}}`; the
  owner tells the connection when it adopts the player, and an old owner
  forwards stragglers. As built, inputs apply in arrival order between the
  group's ticks (the connection's mailbox bounds them), and what a callback
  sends goes back to the connection after it, not once per tick.
- **Interactions are calls**, and the per-feature transfer families, the
  player store's journal kinds, their receipt tables, the connection's
  recovery lane and its guards and queues go.

Slices:

- [VMC-077i1](VMC-077i1.md) — one `Player.State` schema and codec.
- [VMC-077i2](VMC-077i2.md) — one menu click engine and `MenuAccess`.
- [VMC-077i3](VMC-077i3.md) — players in owners; interactions as calls; the
  transfer families deleted; player records in the group's commit.
- [VMC-077i4](VMC-077i4.md) — players in the owner trackers (head rotation,
  ground flag), a global tab list, one way into a level.

Measurements (`bench/players_in_owners.exs`, raw results kept, untracked, in
`bench/results/players-in-owners-*.json`):

| | Before (9eaf51d8) | After (2c88828a) |
|---|---|---|
| Chest click to cursor update, p50 / p95 | 4.0 / 8.7 ms | 0.04 / 0.15 ms |
| Item at the player to `take_item_entity`, p50 / p95 | 51 / 55 ms | 51 / 52 ms |
| Group tick, mean, with 1 / 10 / 50 moving players | 72 / 157 / 138 µs (players tick in their connections) | 291 / 499 / 709 µs (players in the group) |
| Connection reductions per tick, 1 / 10 / 50 players | 4.9 k / 66 k / 692 k | 2.6 k / 39 k / 443 k |
| Group reductions per tick, 1 / 10 / 50 players | 1.7 k / 2.1 k / 5.8 k | 7.0 k / 59 k / 374 k |
| Memory per connection (with its store; after, with its session in the group), 1 / 10 / 50 players | 108 / 120 / 282 KB | 66 / 192 / 791 KB (56 / 171 / 720 KB connection + 10 / 21 / 71 KB session) |

A click is now one call inside the group instead of a transfer. A pickup
still waits for the session's 50 ms pass, as before, so its latency is the
tick's. Total reductions per tick rose about a fifth at 50 players: the
group now cuts each player's records every tick, and a moving player's row
changes every tick, so every observer copies the rows of every player near
it (the connection's entity cache is most of its memory at 50 players).
Follow-ups: publish a player's row only when its base moves, and diff the
player's records only when its state changed.
