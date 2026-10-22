# VMC-034n4c — Supplied XP travel geometry and currents

Status: Planned
Milestone: M3 (the entity model it waited for, VMC-067 and VMC-077h, is in place; VMC-026d needs moving orbs)
Earlier plan: follow [stored bodies](VMC-034n4b.md) within [orb simulation](VMC-034n4.md). Reuse the accepted motion arithmetic and pickup protocol; do not reopen those gates.

Acceptance:

- Observe native `ExperienceOrb.tick` with real `Entity.move`, loaded blocks and
  fluids. Establish body/eye contacts, current refresh ordering, support material,
  collision response, launch escape and embedded escape through focused probes.
  Item motion is inspiration; its dimensions/water/bounce rules differ from XP.
- Compose N4a arithmetic with bounded supplied block/current/target observations.
  Compare multi-tick positions/velocity/ground flags bit-for-bit across falls,
  walls/ceilings, edges/slabs, stone/ice/slime/honey, water/lava and embedded cases.
  Missing geometry/current dependencies must refuse, never behave as empty space.
- Keep geometry and pure work off owners, with bounded envelopes/query counts and
  owner/revision/epoch/deadline fences. No process per orb or global gameplay loop.
  Return kinematics and terminal candidates without serializing the whole region
  for each body/frame. N4b checkpoint measurements require a separate persistence
  cadence before live scheduling can be enabled.
- Preserve UUID/value/count and immutable birth/adoption/consumption/expiry proofs.
  Geometry does not authorize collection or transfer. Cross-owner movement needs
  its own durable handoff; cached observations never become gameplay authority.
- Dedicated actual-client preservation on a frozen checkpoint retains stored-pose
  pickup, expiry refusal and smelt/XP/restart conservation. This supplied kernel
  cannot claim live travel before its runtime integration is separately verified.

After this slice: authoritative target selection/pose-generation pickup permits,
bounded frame scheduling/replication and checkpoint/expiry commits, then moving
handoff and merge provenance. The roadmap can reorder these dependencies; enabling
motion requires consistency between current body pose, admission and collection.
