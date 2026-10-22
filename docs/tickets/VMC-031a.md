# VMC-031a — Water and lava flow

Status: Planned
Milestone: M3
Depends on: [VMC-077m](VMC-077m.md), [VMC-066](VMC-066.md) (scheduled
ticks).

Vanilla's `FlowingFluid` for water and lava:

- **Flow:** spread and its slope search, falling, infinite sources, and
  lava's slower spread and faster spread in the Nether.
- **Fluid interactions:** mixing that makes cobblestone, stone, obsidian and
  basalt.
- **Buckets and waterlogging:** buckets fill and empty, and waterlogged
  blocks behave correctly.
- **Generated fluids:** the post-processing marks generation leaves
  (VMC-024d) settle.
- **Cost:** fluid ticks run in the tick pipeline's scheduled ticks, and the
  slope search runs in the Rust engine.

Acceptance:

- Flow, mixing and source fixtures match the oracle, including across
  section and group lines.
- A bucket-built Nether portal frame (obsidian from lava and water) works on
  the real client.
