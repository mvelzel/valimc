# VMC-081k — A connection's chunk streaming costs what changed

Status: In progress
Milestone: M3, at the user's request
Parent: [VMC-081](VMC-081.md).
Depends on: [070](VMC-070.md), [075](VMC-075.md), [077e](VMC-077e.md).

A production profile (`valimc-profile(15).json`: Hetzner, two vCPUs, view
distance 32, simulation distance 10, one player exploring, 60 s) showed TPS
falling to 8.9 while the normal schedulers were 83 to 94% busy. The player's
connection did 454M reductions, the region group 209M. Its stack samples
(493) were in `want_chunks/1` (208 inclusive: region keys, `group_by`,
sections), `stream_chunks/1` (165), `World.sendable/5` (148) and
`chunk_reply/2` (124). Every step across a chunk rebuilt the whole view
(about 3,700 chunks at distance 32) to find what each section's tickets
want, and re-sorted the pending list; every 50 ms tick and every chunk reply
walked the pending list from its head, a route, a map and an ETS lookup per
chunk not generated yet, which while the far view generates is thousands of
chunks per call; and each reply searched the pending list for its chunk.

This slice makes the connection's work proportional to what changed. The
client sees the same chunks, the same center and unload packets in the same
order, and owners get the same tickets and messages.

Acceptance:

- A view change visits the chunks it moved, not the view's area: entering
  and leaving chunks, and a section's wanted chunks, follow from the
  columns and the chunks that changed.
- A batch reads, per section with pending chunks, its route and its
  publication's generated count; chunks are looked at again only when that
  count changed or when they were added since. The batch is the nearest
  generated pending chunks within the quota, as vanilla's
  `PlayerChunkSender` sends the nearest loaded ones.
- Pending membership is a set lookup; no view change sorts the pending
  chunks.
- Incremental results equal a recompute from scratch over scripted walks
  (`test/view_streaming_test.exs`).

## Design

- **Column runs.** A view's chunks in one column are one run of z
  (`ChunkView.contains?/2` solved for z), so `ChunkView.difference/2`
  compares two views run by run: the work is the columns (at most 70) and
  the chunks that changed. Its lists are the old bounding-box scan's, in its
  order, so the unload packets go out in the same order. The simulation
  square moves the same way (`ChunkView.square_difference/2`).
- **Wanted chunks per section** (`Session.ViewWants`). A section's loading
  chunks (its chunks in the view, the simulation square or the dragon
  arena) and simulated chunks (in the square or the arena) depend only on
  those and the section, so a change of view, square or arena updates only
  the sections of the chunks it moved; a change of dimension starts over.
  `want_chunks/1` still looks up every wanted section's owner and compares
  what it told it, so a section whose group changed or stopped is told again
  as before; a section no change touched keeps the very terms it had, and
  the comparison is an identity test. Sections are ordered by their
  center's distance and then their key (a map's order broke ties before).
- **Pending chunks by section** (`Session.PendingChunks`). Each section
  keeps its pending chunks, the generated ones among them and the
  publication count (`BlockSnapshot.generated/1`) and table they were read
  at, and the chunks added since. An owner's publication counts each
  publish that turned chunks from absent to generated, after writing their
  rows, so a reader that sees the new count sees the rows. A batch visits
  sections by the distance of their nearest chunk to the player's and stops
  when no further section can hold a chunk nearer than the batch's
  farthest; a section that loads or has nothing generated costs its route
  and its count. Ties in distance go by `{x, z}` (the old order was the
  pending list's history). Sections not running are still started when a
  batch reaches them (`World.stream_source/1`), and a superset of the
  sections the old walk reached is visited.

## Work removed

Deterministic counts (reductions, `Process.info/2`) of a scripted walk at
view distance 32 (3,725 chunks in 79 sections), reach 10, one chunk per
step (scratch script, not committed):

| Per call | Before | After |
|---|---:|---:|
| View difference and section sets, per step | 194,703 | 12,804 |
| Pending upkeep, per step | 89,808 | 5,682 |
| A batch with 3,408 pending, none generated | 52,438 (3,408 chunks) | 2,003 (71 sections) |

A batch's count leaves out the owner lookups each section costs in both. A
section's first batch after it entered the view reads each of its pending
chunks once (29,423 for all 71 sections at once, as at a join), and again
each time a delivery generates chunks in it. A reply's membership test is a
set lookup instead of a scan of the pending list.

## Checks

Streaming: `mix compile --warnings-as-errors`; `view_streaming_test`,
`chunk_view_test`, `world_test`, `entity_views_test` and the connection
suites that stream or travel (`view_distance_connection`,
`player_handoff_connection`, `connection`, `dimension_travel_connection`,
`chest_lid_replication`, `player_motion_connection`, `dragon_live`,
`regionizer`, `region_lifecycle`): 60 tests, one failure of
`dimension_travel_connection_test`'s first `section_blocks_update` (a
generated chunk's own block update arriving first), which also fails one
run in six at 284c7eae; `check_vanilla.py --changed` through `heavy.py`
(`chunk_view`, `game_mode` and `tcp`: 3 of 3 passed).

Next: the region side of exploring in the same profile (222 group
collections in 60 s, `post_process` of arriving chunks,
`RegionGeneration.pump` and `Scheduler.want`).
