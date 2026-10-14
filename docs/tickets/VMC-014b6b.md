# VMC-014b6b — Native block collision scan planning

Status: Done — candidate planning and actual contacts verified. October 15, 2026.
Depends on VMC-014b6a.

Plan a bounded native block scan before owner reads: epsilon-expanded integer
bounds, X-fastest cursor order and interior/face/edge classification. Extract
native state protrusion flags and filter face/edge candidates. Shape intersection
and owner/tick-consistent collection remain subsequent parts of VMC-014b6.

Acceptance:

- Match actual `BlockCollisions` state-read positions/order/types at positive,
  negative, integer, epsilon and large-coordinate boundaries. Skip corners.
- Match actual candidate eligibility for every pinned state: interior states,
  large-shape faces and moving-piston edges. Unknown states cannot become air.
- Bound the raw scan volume to 512 cells before allocating positions. Reject
  malformed/unbounded boxes. No owner messages, I/O or new process in planning.
- Pass format, full tests, native differential/full suite, release and audit.
- Actual 26.3/CUA: read planned positions through bounded region observations;
  a protruding fence on a face candidate must remain eligible and stop descent
  at the predicted height. Compare ordinary stone, commands, cleanup/reconnect.

Reference: pinned 26.3 server SHA-1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`, `BlockCollisions.computeNext`,
constructor, `Cursor3D`, `BlockState.hasLargeCollisionShape`. Private bytecode:
`research/disassembly/VMC014b6b-*`. Native strict/full-shape versus voxel epsilon
intersection requires a separate verified primitive before returning final
colliders. This ticket supplies candidates, not an authoritative movement check.

Implementation: pure `BlockScan.plan/1` and `eligible/2`, with a 512-cell raw
volume cap. Corners skip before state lookup; unknown queried states remain
errors. Native facts add 11,176 large-collision state IDs; existing geometry is
unchanged. Owner queries, shape resolution and scheduling remain caller-owned.

Verification, October 15:

- Format, 400 tests, production release and full native suite pass. The oracle
  traces actual `BlockCollisions` state reads over 133 boundary/offset/size cases,
  then observes actual shape requests for all 35,723 states and four boundary
  types: 142,892 decisions. All positions/order/types and eligibility match.
  The exact 512-cell case yields 504 candidates; larger raw scans reject before
  allocation. Exact diff and public-tree audit pass.
- Actual 26.3/CUA on rebuilt release: a narrow scan above y65.4 classifies
  {0,64,0} as a face. Oak fence state 8666 remains eligible; stone state 1 does
  not. A longer fall scan gathers 82 candidates through four bounded region
  observations. Held Shift+Tab from centered y67 stops at y65.5 on the fence,
  then y65 on the stone control. Both queried-state clipping predictions match
  exactly. `/stats`, cleanup and ordinary unseeded reconnect pass at y64.
- Private evidence: `.local/vmc014b6b-*`,
  `.local/client-tests/VMC-014b6b/latest.log`,
  `/tmp/valimc-014b6b-fixture.exs`. Fresh 00:17–00:21 client joins show no new
  localhost protocol errors. An initial CUA window lookup failed transiently;
  refreshing inventory and binding the same app restored access.

The private static-world fixture merges observations only for validation. It does
not establish a simultaneous cross-region tick view. Final shape intersection,
block-entity ownership, tick fences and movement enforcement remain unfinished.
