# VMC-077z — Placement across a section line

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077i](VMC-077i.md) (placement in the player's owner),
[VMC-077j1](VMC-077j1.md) (groups), [VMC-077y](VMC-077y.md) (found by its
client run).

Before: `Player.Placement.plan/2` grouped the clicked block and the cell
beside the clicked face by 8 × 8 section and refused the placement
(`:cross_owner_placement`, with block corrections) whenever they differed.
The rule came from VMC-077i, when one owner held one section. Since groups own
several sections, two adjacent loaded sections share a group, and its block
rules already read and write across their border. A player could still not
build against a block on the other side of a section line: on the VMC-077y
dataset, `/tp ValiMCTest 2.5 87 0.5 90 0` facing the obsidian at (-1, 88, 0)
and right-clicking with obsidian placed nothing at (0, 88, 0). Vanilla places
across any boundary.

## Design

- The plan reads each of the two cells at its own section's owner and goes on
  when both owners are the same group process. The candidate (the clicked
  cell when it is replaced, otherwise the adjacent one) decides the section
  that checks survival and takes the placement, under that section's fence.
- The clicked block in a sibling section is not fenced by the commit. What
  the placement depends on is checked again as it commits, inside the group:
  survival reads siblings' blocks (`BlockRules.first_surviving/5` with the
  group's stores), and the chest check reads a neighbour across the line in
  its sibling (`isolated_chest_changes?/2`).
- The chest-beside-chest rule (`single_chest/5`) already read each neighbour
  at its own section's owner; it now runs at the candidate's section with that
  section's fence.
- Cells in two different groups (groups keep their loaded chunks at least 25
  chunks apart, so only a transient state) are still refused, and both cells
  are corrected at their own owners.

## Acceptance

- A survival player places stone against a block in the neighbouring section
  of the same group (`player_placement_connection_test`); the test fails on
  the old rule.
- The placement tests (`placement_region_test`, `placement_test`,
  `player_placement_connection_test`, `place_connection_test`) and `mix test
  --stale` pass; `check_vanilla.py --changed`.
- Client: the repro above places the block.

## Results

- `Player.Placement.plan/2` and `observe/1`; one test, which fails on the
  old rule.
- The four placement suites with `--include tcp` (14 tests); `mix test
  --stale` (597 of 598); `check_vanilla.py --changed` (placement and tcp, 2 of
  2 stages).
- The one `--stale` failure, `worldgen_scheduler_test.exs:214` (no spills
  counted), passes with its file and fails alone on the base commit too: it
  depends on test order, not on this change.

## Client

October 22, 2026, Java 26.3 against `579c2ebb`, fresh world, seed 20261020:
PASS. From (2.5, 87, 0.5) facing west, obsidian placed against the obsidian
at (-1, 88, 0) appears at (0, 88, 0) and stays, in creative and in survival
(16 → 15); break and place again works. A `/setblock` probe confirms the
server holds it; the server log has no refusal, error or warning. Evidence:
`.local/client-tests/gates-20261022/`.
