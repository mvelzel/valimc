# VMC-078d — Villager wandering under roofs

Status: Awaiting client
Milestone: M3
Parent: [VMC-078](VMC-078.md).
Depends on: [VMC-044a1](VMC-044a1.md).

The fresh survival client reaches a generated plains village, where a
villager's roofed wandering path requests the nonexistent block flag
`face_sturdy_up`. The resulting `KeyError` restarts the owner and disconnects
the player. The generated fact table already exposes `sturdy_up`; use that
single fact source rather than add an alias or another support predicate.

Acceptance:

- Roofed wandering uses the generated sturdy-face fact and matches pinned
  vanilla's candidate selection through the existing village oracle.
- The affected villager/AI owner checks pass. The same intact client world
  reloads on an immutable repair release and continues its village builds
  without the owner restart.
- Keep the original crash and ordinary survival progress; do not reset one
  side of a committed transfer, inventories or entity records.

## Evidence and reference (October 24, 2026)

Actual Java 26.3 client runtime `7a300a21`, world-normal seed 20261024:
at 08:53:32 the owner's villager rest activity calls `brownian_walk`, then
`BlockFacts.flag?/2` raises on `face_sturdy_up`. The player was placing
stone beside a newly placed sticky piston, but the stack is a villager
brain tick; this is not a piston result. Exact trace and tester report:
`.local/client-tests/M3-survival/owner-restart-log.txt` and `report.md`.
The owned helper/server stop with no remaining players; the entire dataset,
builds, inventory drops and journals remain intact.

Pinned Mojang 26.3 jar `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`,
`InsideBrownianWalk.create` and its `loadedAndEntityCanStandOn` predicate;
`BlockFactsOracle` extracts `sturdy_up` from `BlockState.isFaceSturdy`.
The existing night scene has a claimable bed and never needs this roofed,
homeless branch. The village oracle adds that one missing scene; it keeps
the ordinary brain, level random, movement and candidate selection.

The new scene reproduces the same `KeyError` before the repair. Merely
renaming the flag then exposes another defect in this previously uncovered
path: its shuffle consumes the level random. Pinned `InsideBrownianWalk`
calls JDK `Collections.shuffle`, whose separate RNG leaves the level and
mob randoms untouched. The existing one-shot's owned state now holds that
independent shuffle stream, initialized alongside the brain's gate streams.
No global gameplay process or new random table is introduced. The oracle
seeds JDK's independent stream for this probe as it already seeds the
brain's private shuffling lists; production still makes ordinary random
choices without a fixture seed.

Candidate enumeration follows `BlockPos.betweenClosed`'s X-first order;
the existing block collision view also supplies the current-body clearance
guard used by vanilla's final predicate. Support reads use `sturdy_up`.
All fifteen village scenes now match for 6,154 ticks, including positions,
walk targets, brain/mob/level randoms and schedules. Ten affected villager
and AI connection checks pass. Original failure and intermediate mismatch:
`.local/m3-villager-brownian-before-stage.log` and
`.local/m3-villager-brownian-after-flag-stage.log`. Passing evidence:
`.local/m3-villager-brownian-complete.log` and
`.local/m3-villager-brownian-final-owner-tests.log`.

All twenty stages selected by the final affected-check run pass, with
fresh fact extraction verified: `.local/m3-villager-brownian-changed.log`.
The separate immutable production release builds successfully in
`.local/M3-survival-villager-checkpoint`; its 760 runtime source files
match the repair. Base `445a5eae`, runtime patch SHA-256
`e913fa4bb65e4cc0d3db3edf00e45a06e5b816656060a420d0806369e0381bbc`.
Its source manifest and physical native/build outputs remain separate
from the old failed release; docs are a freeze-time snapshot. Build log:
`.local/m3-villager-frozen-release.log`. The dedicated tester resumes the
same complete survival dataset; its graphical recheck remains pending.
