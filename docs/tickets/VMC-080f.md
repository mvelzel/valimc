# VMC-080f — Reuse native mob fluid observations

Status: In progress
Milestone: M3
Parent: [VMC-080](VMC-080.md).

The user's paired one-minute captures separate loaded-area combat/movement
(`valimc-profile(6).json`) from spectator exploration (`(7)`). Loaded-area
simulation averages 7.41 TPS; the final MSPT ring has median 117.6 ms and p95
166.3 ms. Exploration averages 4.76 TPS, with p95 284.7 ms in the final ring.
These are distinct workloads on the same deployment, not a matched revision
comparison. Region reductions are 747.5M of 844.5M in the loaded-area capture;
457 of 1,244 region observations include mob movement, 59 include fluid sensing.
Stack counts overlap and include NIF waits; they are not exact CPU timings.

Before each mob's AI turn, fluid and eye queries rebuild two native block views;
the eye query repeats the fluid contact scan. Reuse the tick-local immutable view
already held by the native mob ticker and calculate contact depths and eye state
from one scan. Preserve missing-cell failure, eye-source/sturdy-face rules,
body-size changes, mid-tick displacements and sequential AI observations. Use the
existing resource and normal/dirty dispatch budget, with no cross-tick cache.

Acceptance: old and combined reads match on dry, flowing/source water, lava,
bubble columns, sturdy ceilings, negative coordinates and unreadable boundaries.
The live mob path uses the combined read; affected mob/physics/vanilla checks
pass. Retain matched full-profile read and mob-phase measurements. Deploy to the
same world at 32/10 for the user's own gameplay tests, with no GUI client driver
or flight benchmark.

The prototype is uncommitted and undeployed. The user requested a full audit
before further fixes; see [080h](VMC-080h.md). Completed checks and the matched
measurement (about 2% of the full mob phase) are recorded there. Deployment is
held pending review of the larger simulation design.
