# VMC-081d — Native mob state

Status: In progress
Milestone: M3, at the user's request
Parent: [VMC-081](VMC-081.md).
Depends on: [081a](VMC-081a.md).

Re-scoped from "native entity sections, items first". A survey of the entity
path and a profile of the `mobs` scenario showed that items, orbs, falling
blocks, TNT and projectiles are a small share of a tick with many mobs, while
mob turns are most of it. Native storage starts with mobs; the other kinds
follow once mobs use it.

## Baseline

`bench/tick_budget.exs` `mobs` (the scenario named `combat` before) at
922cdd57, two pinned cores of the development Mac's Linux VM, 60 seconds:

| | Run 1 | Run 2 |
|---|---:|---:|
| TPS (mean / lowest second) | 20.0 / 19.0 | 20.0 / 18.7 |
| Tick mean / p95 | 18.7 / ≤50 ms | 19.0 / ≤50 ms |
| Entity phase (sampled) | 13.9 ms | 16.1 ms |
| Active mobs / loaded entities | 164 / 764 | 161 / 762 |

About 90 µs per active mob on these cores, about 300 on the VPS. A stack
profile of the owner (inclusive shares of its samples): mob turns
(`move_mobs`) 25%, of which the AI's thinking 8% and the per-mob glue around
the physics kernel (input maps, settling, vitals, fluids, motion) about 12%;
natural spawning 14% (mostly the native spawn kernel); building and diffing
entity save records each 50 ms cut 12 to 15% (`Store.record`, `Body.record`,
`Mob.record`, `Living.saved`, `keyed_changes`); tracking 6%.

## Where the per-mob cost is

`MobTicks.steps/5` runs one section's mobs in id order. Each tick it rebuilds
every mob's kernel input map (`MobTicks.input/2`, `MobMotion.kernel/4`), starts
a native ticker over them (`Kernel.mobs_begin`), and per mob runs the AI
(`AI.think_mob/4`), the kernel step, pushes, `AI.settle/5` and
`MobVitals`, then turns each result back into a store step (`Store.step_body`,
a view, the spatial index). The mob AI is about 31,000 lines of Elixir across
30 families; the tick glue about 4,200. No single part reaches the budget:
the 15 to 30 times VMC-081 asks for needs the whole per-mob loop native, the
AI included, family by family.

## Plan

1. **Persistent native mob table.** Each section's mobs' kernel state
   (position, velocity, rotation, box, travel attributes, flags) lives in a
   native table owned by the section's group, moved with `region_give`, kept
   across ticks and changed by deltas, instead of input maps rebuilt every
   tick. The ticker steps it in place.
2. **Native base tick.** Living and mob base ticks (fluids, fire, air, fall
   damage, effects' timers, despawn checks, body rotation) run in the table;
   Elixir keeps the AI's think and the effects that reach other owners.
3. **Native AI, by family.** Goal selectors, controls and sensing in Rust
   (081e), with the ordered fallback that yields an unported mob to Elixir.
4. **Records from the table.** Save records and tracker packets come from the
   table's dirty classes (with 081h).

Each step: parity tests against the Elixir path over seeded scenes, the
`mobs` scenario on two cores before and after, and the vanilla stages it
touches.

Acceptance (for this ticket's steps 1 and 2):

- The same mob behaviour: seeded replays equal the Elixir turn.
- The `mobs` scenario's entity phase down by the glue's share at least.

Checks: pending.
