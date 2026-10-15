# VMC-027a — Supplied world-border collision geometry

Status: Done within supplied stationary-border scope. October 15, 2026.
Prerequisite for live pose fitting.

Provide pure native border bounds, containment and collision predicates from a
complete supplied stationary border. The preview currently has no border owner,
network synchronization or damage. Those and resizing remain later slices.

Acceptance:

- Match native center/diameter/absolute-limit clamping, asymmetric point bounds,
  AABB max-corner tolerance, distance and entity proximity gate.
- Preserve native floor/ceil collision planes and voxel epsilon overlap. Bounded
  finite query geometry must not require infinite coordinates in the BEAM.
- Differentially invoke actual `WorldBorder` and `CollisionGetter.noBorderCollision`
  on boundary/negative/fractional/clamped/degenerate cases. Bound all inputs;
  require explicit border observations, with no world reads or gameplay authority.
- Run changed-file formatting, targeted regressions/native probe and public audit;
  full suite/release follows the larger fitting block. Dedicated client:
  trusted stationary border fixture, actual inside contact versus predicted planes,
  outside behavior, commands/reconnect and cleanup. Keep fixture networking
  distinct from implemented world-border synchronization.

Reference: pinned 26.3 jar, `WorldBorder`, its `StaticBorderExtent`, and
`CollisionGetter.noBorderCollision`; private bytecode `research/disassembly/VMC027a-*`.
Moving borders interpolate previous/current sizes; a current diameter alone is
insufficient to claim moving-border collision parity.

Implementation/checks: bounded supplied snapshots, native floor/ceil planes and a
single outside voxel grid preserve corner-overlap semantics. Finite outer planes
lie beyond every accepted query. Five targeted regressions, formatting, Python
compilation and 4,860 actual native border cases pass. Private fixtures/logs are
`.local/vmc027a-*`; includes two native initialization packets for client fixtures.
No runtime packet encoder/owner/resizing was added. Full checks/build are deferred
to the larger fitting block under the user's updated workflow: its 458 tests,
isolated `.local/pose-fit-build/rel/valimc` release and full native suite now pass,
including plaintext/encrypted TCP. Private integration logs:
`.local/pose-fit-block-*`.

Dedicated Java 26.3 client passed on frozen grouped checkpoint `228d596`:
diameter-8 fractional border contact at z=3.699999988079071 matches the rounded
plane; the supplied predicate accepts contact and rejects +.001z. Outside movement
matches the native proximity gate. Restoring the default diameter permits crossing;
cleanup, reconnect, terrain and `/stats` pass with no fresh client warnings/errors.
Report: `.local/client-tests/VMC-027a/report.md`. No moving-border, damage, runtime
border synchronization or authoritative movement claim.
