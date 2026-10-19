# VMC-014b6a — Bounded region block observations

Status: Done
Note: Done — owner API and actual client scenario verified. October 15, 2026. Depends on VMC-014c1.

Read at most 128 block positions in one existing region-owner turn. Return the
owner incarnation and block revision with immutable state IDs. A caller can
require a previous revision; a stale owner/revision rejects. This provides a
local observation, not a multi-region tick transaction or mutation permission.

Acceptance:

- Validate integer positions, build/world bounds, request size and revision
  before enqueueing; check them again in the owner. Reject foreign-region reads.
- Snapshot blocks together with owner identity/revision. No block-by-block owner
  calls, new coordinator, geometry calculation, region allocation or disk I/O in
  the query. Unavailable/dead/timed-out owners must never become empty terrain.
- Cover edits, duplicate positions, negative region boundaries, invalid/oversized
  queries, stale revisions/incarnations, concurrent reads/writes, timeout and
  owner replacement. Keep observations independent of item publication.
- Pass format, full tests, production release, exact diff and public-tree audit.
  No protocol change; the VMC-014c1 native-suite baseline remains applicable.
- Actual 26.3/CUA: query stone wall/air observations, walk into the queried wall,
  remove it through the trusted host API, verify the old revision rejects and a
  new snapshot reports air, then walk through. `/stats`, cleanup and reconnect.

Design follows existing region incarnation/revision ownership. Mojang block IDs
and collision facts are pinned to 26.3. BE observations, shape collection and
cross-region tick fencing remain separate slices. No eventual publication is
treated as authority; a future gameplay commit must validate fences in its owner.

Implementation: `Region.observe_blocks/3` validates at both call boundaries,
returns one immutable owner/revision/state map, and optionally requires a previous
revision. Calls time out after 250 ms; timeout/death return errors. `World.owner/1`
names the existing incarnation lookup/start API; `item_owner/1` remains compatible.
Geometry stays outside the owner. Revision checks alone cannot authorize a later
action or establish simultaneous snapshots across regions.

Verification, October 15:

- Format, 395 tests, production release, exact diff and public-tree audit pass.
  Eight new tests cover bounded/malformed direct and API requests, duplicates,
  negative boundaries, concurrent revision/state pairing, stale owners/revisions,
  timeout/death, flushed replacement and independent regions/item publication.
  No wire/registry changes; the full native suite passed on the preceding ticket.
- Actual 26.3/CUA on rebuilt release: a seven-position query returns six stone
  wall states plus nearby air at revision 7. W held 1,000 ms stops the centered
  player at z1.699999988079071, exactly matching clipping of queried states.
  Trusted host removal increments revision to 13; requiring revision 7 rejects,
  while the new query reports all air. Another 1,000 ms W crosses to z6.22928503732028.
  `/stats` and ordinary unseeded reconnect preserve {1.5,64,6.22928503732028}.
  Wall removal also cleans the fixture. No new localhost protocol errors appear.
- Private evidence: `.local/vmc014b6a-*`,
  `.local/client-tests/VMC-014b6a/latest.log`,
  `/tmp/valimc-014b6a-fixture.exs`. Source journal counters/outbox are preserved.

Remaining: block-entity observations, spatial candidate collection, cross-region
tick fences and owner-validated gameplay commits. Movement is still client-owned.
