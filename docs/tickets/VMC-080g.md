# VMC-080g — Skip absent rare entity scans

Status: Awaiting client
Milestone: M3
Parent: [VMC-080](VMC-080.md).

Building one section's mob world scans every entity of its group to find leash
knots and to decide whether dragon data is needed. In loaded-area profile 6,
38 of 1,244 region observations include the knot scan and 16 include the dragon
scan. Repeated empty scans grow with the entire render-loaded group even though
only simulation-ticketed sections move mobs.

Maintain type counts in the existing owner-local entity spatial index, updated
on every store admission, removal, replacement and recovery. A group with no
matching type skips the scan; a positive result uses the existing authoritative
rows and ordering. Counts never authorize a mutation or replace live entries.
Preserve duplicate-position knot selection, dragon/crystal ordering, same-tick
cross-section effects and handoff semantics.

Acceptance: counts match live entries after create, move, conversion, removal,
restore and worker-created merges. Group lead and dragon behavior remains live.
Retain a matched wide-group absence measurement, run affected owner/entity and
vanilla checks, then deploy with the parent for the user's next profile.

Implementation, checks and the isolated absence-query measurement were retained
during the audit; see [080h](VMC-080h.md). The user has now asked to take the next
step and deploy for their profiler run. Include this verified slice with the
eligibility and owner timing changes in that deployment.

Deployed with [080j](VMC-080j.md) in `f1d9fa85` on October 25. The user's next
profile evaluates the combined changes; no isolated production gain is claimed.
