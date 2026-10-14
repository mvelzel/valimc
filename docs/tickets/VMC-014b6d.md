# VMC-014b6d — Live bounded collider observations

Status: Done — validated. October 15, 2026. Depends on VMC-014b6c2.

Read the bounded scan from existing region owners in a supervised query task,
then collect geometry outside those owners. Return observation fences, never
movement authority. Do not allocate regions or interpret failed reads as air.

Acceptance:

- Bound task admission, region/batch counts and total query deadline. Request
  independent owners concurrently; require one revision across each owner's
  batches. Preserve explicit owner/revision/context errors and cancel outstanding
  reads on timeout, cancellation or caller death. No new global gameplay owner.
- Match native loaded-chunk air outside build height; keep edits restricted to
  the dimension build range. Reject invalid coordinates before task admission.
- Cover missing/replaced/stalled owners, mid-batch edits, malformed replies,
  pool saturation, caller loss, cancellation/late replies and independent queries.
  Pass format, full tests/release, native height checks, diff and public audit.
- Actual 26.3/CUA: live-query a wall at a region boundary, compare predicted and
  actual contact, remove it and requery, then walk through. Exercise unavailable
  owner/timeout/context errors with the session responsive; cleanup/reconnect.

Reference: pinned 26.3 SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`,
`BlockCollisions.computeNext` and `LevelChunk.getBlockState`. The chunk lookup
returns ordinary air for out-of-range sections (distinct from `Level`'s lookup).
Private bytecode: `research/disassembly/VMC014b6d-LevelChunk.txt`.

These observations can change before consumption, including after a successful
batch. They are not simultaneous snapshots or a commit-time fence protocol.
Region BE storage and authoritative movement remain separate work.

Implementation: `CollisionQuery.start/2` returns a standard unlinked Task from a
pool capped at the scheduler count. Callers consume the result/monitor or cancel
with `Task.shutdown/2`; later consumers must retain at most one pending
query per consumer. OTP request collections keep one outstanding read per owner,
with at most 16 owners/batches and 128 states/batch. Later batches require the
first revision. A 250 ms result deadline covers reads and geometry; late results
reject. Caller monitoring ends abandoned waits; task exit removes request aliases.
No query starts a region. Eligible unresolved BEs remain explicit errors.

`Region.observe_blocks/3` now accepts bounded out-of-build Y coordinates
(±1,000,000), returning native chunk air there. This supersedes VMC-014b6a's
earlier build-height rejection. Editing remains restricted to -64 through 319;
out-of-range edit entries cannot override air.

Verification, October 15:

- Format, 421 tests, production release and full native suite pass. Eight new
  tests cover live multi-region geometry/fences, no-allocation failure, height
  limits, concurrent owner reads and independent queries, pinned batch revisions,
  malformed replies, caller loss, cancellation/late responses, dead owners and
  pool saturation/readmission. Native `LevelChunk.getBlockState` matches all 300
  outside-height probes, with null sections proving no section dereference.
- Actual 26.3/CUA, 01:08–01:13 CEST: live-query a six-block wall across four
  existing region owners. Held W stops at z127.69999998807907, exactly predicted.
  Removal makes two old fences stale; a fresh query is empty and another held W
  reaches z132.22928503732032. Host queries reject unavailable/stalled owners and
  unresolved shulker context; `/stats` still responds.
- An offline flight fixture starts at y-68 below bedrock. Held Space stops at
  y-65.79999995231628, exactly predicted from two live region observations of
  out-of-build air and bedrock. Cleanup and normal reconnect restore y64, flight
  off and absent wall/shulker fixtures, preserving source journal state.
- Private evidence: `.local/vmc014b6d-*`,
  `.local/client-tests/VMC-014b6d/latest.log`, `/tmp/valimc-014b6d-fixture.exs`.
  Fresh localhost logs have no ERROR entries. A transient window lookup recovered
  after inventory refresh; keyboard controls supplied these actions.

Exact diff/public-tree audit pass. No wire change, movement
enforcement, step-up, simultaneous snapshots or commit-time fencing is claimed.
