# VMC-015h — Sneaking at edges

Status: Validated and published (`6ca22ef`), complete within scope. October 15, 2026.

Acceptance: native Shift edge protection for grounded and near-ground players,
separate X/Z/diagonal backoff, exact support-query geometry and native 0.05 steps.
Preserve upward motion, flight and mover exclusions. Empty/missing geometry must
remain distinct. Compose after slowing consumption and before collision on the
existing bounded player geometry lane; no new owner or timer. Keep accepted
anchors, movement history and stale-result fencing consistent.

Reference: pinned Mojang 26.3 `Player.maybeBackOffFromEdge/isAboveGround/
canFallAtLeast/isStayingOnGroundSurface`, `Entity.move`. Original native probes
should capture actual query order/boxes and displacement over supplied support
scenes. References and generated cases stay ignored.

Client gate: actual Shift walking to an exposed ledge and diagonal corner; release
Shift to fall, then upward jump and creative flight exclusions. Include a slab/
near-ground edge and brief dry/climbing/slowing regressions on a frozen release.
Kernel checkpoint: `SneakEdges` matches 23,040 actual native displacement and
ordered support-query traces: three poses, local/negative/remote coordinates,
empty/ledge/corner/lowered/disjoint support, fall threshold, flight/Shift/ground
and mover exclusions. The callback consumes supplied support facts; native block
sampling/entity collisions are outside this oracle. Three affected tests pass,
including 64-block backoff within 4,096 queries and missing-fact propagation.
Evidence: `.local/sneak-edge-{native,check,tests}.log`; original
`scripts/SneakEdgesOracle.java`.
Live checkpoint: packet and scratch movement apply backoff after consuming slowing
and before collision. Support checks reuse the worker's single fenced block frame;
each local scan retains existing geometry limits. Native query dependencies fit
admitted packet/tick frames across all 23,040 cases. Seventy-two affected tests pass:
slowing-before-edge order, missing facts, packet path recording, flight/upward
exclusions and a real TCP survival rejection followed by released-Shift recovery.
Evidence: `.local/sneak-live-tests.log`, `.local/sneak-edge-check.log`.

Frozen `6ca22ef`, `.local/sneak-live-checkpoint` (510 verified blobs), passed actual
Java 26.3 checks at 21:17–21:23 CEST: raised ledge/diagonal corner/raised half-slab
holds, release falls, traversable near-ground half-block drop, actual jump and
creative flight exclusions, plus dry/web/ladder regressions. All 51 fixture cells
restored; owned client stopped/waited and zero players confirmed. Tester report
reviewed: `.local/client-tests/VMC-015h/report.md`. This completes the stated edge
behavior gate; complete survival/forces and damage remain separate work.
