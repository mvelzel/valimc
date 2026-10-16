# VMC-029b — Authoritative placement

Status: Creative single-owner plain/slab core Done; actual report reviewed and accepted.
[Survival consumption](VMC-029b1.md) and broader placement remain open.
October 16, 2026.

Acceptance: preserve vanilla clicked-versus-adjacent targeting, replaceability,
face/hit/hand context and placed state. Begin with plain blocks and slabs, including
halves, double merging and waterlogging. Validate native contexts/codecs before
composing player admission and fenced block-owner writes. Survival stack
consumption must share a durable outcome with placement; retries/reconnect cannot
duplicate a block or consume its source twice. Bound work and retain fresh owner,
mode, geometry, reach and inventory fences. Specialized use/neighbor callbacks
remain explicit follow-ups rather than guessed base behavior.

Reference: pinned26.3 `BlockPlaceContext`, `BlockItem.getPlacementState`,
`BlockStateBase.canBeReplaced`, `SlabBlock` and `ServerboundUseItemOnPacket`; jar
SHA1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`. Private signatures/probes stay
ignored. SteelMC `f6fb4e49778ccffc5c13c3b87c1c2600dd9435aa`,
`steel-core/src/player/game_mode/block_interaction.rs`, illustrates early loading,
range, hit and teleport admission followed by correction; native behavior remains
the correctness source. Do not copy its threading model.

Client scenario: replace grass/liquid versus placing beside solid blocks; place
top/bottom slabs, combine halves, retain water in a wet half and clear it on a
double merge. Check wrong reach/occupied target, survival stack counts, competing
placement/mining and fresh reconnect. Dedicated tester owns GUI validation.

Candidate foundation: `Physics.Placement` proposes clicked/adjacent targets and
states for five plain blocks and all101 slab families. Immutable indexed facts
cover replaceability, single/double halves and source-water logging. The pinned
native oracle matches518,964 actual contexts (all states with supported replacement
methods, all slab halves/faces/float32 half boundaries, liquids, snow layers,
occupied and different-slab neighbors). Its576 native use-on packets match the
bounded decoder across both hands, coordinate extremes, flags and sequence sizes.
Nine actual native nonfinite-hit decodes remain acknowledgeable but grant no
placement; malformed/truncated fields are rejected. Eight foundation tests cover
replaceability, occupied targets and water-versus-flowing-water negatives.
Logs `.local/placement-{native,check,tests}.log`; private facts/cases stay ignored,
only normalized scalar catalogs are public.

Ten specialized replacement classes/803 states are explicit unsupported cases.
Grass-block placement, component overrides, specialized support/use callbacks,
peer-body ownership, cross-owner mutations and survival consumption remain open.
Changed-behavior graphical validation passed on the frozen core checkpoint.

Owner preparation now uses one bounded250ms worker and existing loaded owners;
it neither cold-loads regions nor changes blocks. A prepared one-block creative
batch commits only at its observed owner incarnation/revision and before its
deadline, checked after dequeue. It shares existing batch publication and mining
write exclusion.32 affected tests pass, including inert preparation, wet-half/
double outcomes, target ABA, delayed expired commit, retired owner, stalled reads,
absent regions and explicit cross-owner refusal. Logs
`.local/placement-owner-{compile,tests}.log`. Survival must use durable consumption
rather than this creative API.

Live creative composition: admit commands on their player owner using
current mode, inventory permission, loading, teleport, hit and reach. Capture the
accepted item/body, preserving input order before later selection/movement events.
Keep at most16 queued commands and one bounded worker; queued authority expires
after250ms. The region rechecks incarnation/revision/deadline; body collision and
loaded-target checks precede a write. Corrections originate on block owners so
they cannot overtake later publications from that owner. Verify actual halves,
water, merging, refused occupied/body cases and reconnect. This first live
lane retains other blocks' existing preview behavior; peer-body ownership,
cross-owner mutations, specialized uses and survival consumption remain open.

Seventy affected tests pass. Six new real-TCP scenarios cover native targeting,
both hands, slab states, occupied/body refusal, unloaded/survival refusal,
responsive sockets during stalled region reads, expired authority and original
held-item ordering before selection. Existing fixtures now send native
`player_loaded`; asynchronous placement waits for its acknowledgement rather than
an unrelated stats response. Refused survival predictions restore inventory
before acknowledgement; correction state IDs can advance without changing items.
Native plaintext and continuous AES-CFB8 TCP pass, including offhand bottom/double
slabs and peer section-update replication. Normalized native facts reproduce
exactly. Logs `.local/placement-live-{native,check,affected-tests,tcp}.log`.
Frozen `96da2b87bf73fd6ab257ebe862f73cd8470ed88d` production build and actual
client gates pass;655 blobs verified. `.local/placement-production.log` and
`.local/placement-validation-checkpoint.json`. No full-suite rerun is claimed for
this slice; the preceding mining block owns the822-test/full-native run.

Actual-client evidence — October16,2026: dedicated tester reports PASS for the
creative stone/oak representative slice at frozen
`96da2b87bf73fd6ab257ebe862f73cd8470ed88d` (655 independently verified blobs),
Java26.3/protocol777 and mandatorySDL backend. Actual main-hand use placed stone
on grass beside an anchor, dry bottom oak15180, merged double15182, and top15178
via upper-side targeting. Offhand use placed source-water oak15179 with visible
contained water, then merged15182 with water visibly removed. Downward stone use
inside own body left air; vanilla prediction may reject this before transmission,
so this does not independently establish server negative admission. HUD and durable
inventory retained creative counts32/32/16. Fresh direct reconnect visibly retained
stone, dry double/top lower gap, water-cleared double and a second wet half; `/stats`
responded. Both owned JVMs stopped/waited; zero players, exact original full player
snapshot/worn inventory, all46 touched cells and all41 exact item records/receipt
maps restored/retained; source25/outboxnil unchanged. No server restart. Frozen
runtime/dataset and assertions are in ignored `.local/client-tests/VMC-029b/report.md`
and per-scenario logs. Reviewed and accepted within core scope; the parent stays open.
Graphical scope excludes replaceable vegetation, separately targeted occupied
solids, other plain/slab families, peer/cross-region, survival and special callbacks.
