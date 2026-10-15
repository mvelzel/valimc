# VMC-015d — Player fluid travel

Status: In progress; current/input observations and live composition pending. October 15, 2026.
Follows [dry travel](VMC-015b1.md) and [saved velocity](VMC-015b2.md).

Replace the current fluid exclusion with bounded water/lava observations and
native travel math on the existing player geometry lane. Keep accepted position
separate from scratch motion. Flow propagation belongs to VMC-031.

Acceptance: complete fluid kind/amount/height/source/falling facts, overlap/depth
and flow boundaries, native numeric fixtures and transition traces. Unknown or
missing observations fail; no new global owner, timer or relaxed query bounds.
BlockScan already samples neighboring cells; verify every needed flow dependency.

Reference: pinned jar/hash in VMC-015a; `FluidState`, `FlowingFluid`,
`Entity.updateFluidInteraction`, `EntityFluidInteraction.update/applyCurrentTo`,
`LivingEntity.travelInFluid`,
`travelInWater`, `travelInLava`, `getFluidFallingAdjustedMovement`,
`jumpOutOfFluid` and `Player.travel`. Private notes: `.local/fluid-travel-next-plan.txt`.
Default water/lava drag differs from air; fluid surface height can depend on the
cell above. Creative flight must retain its native fluid exclusion.

Automated checkpoint: complete 35,723-state scalar catalog (20 property sets,
35,723-byte immutable lookup) and bounded body depths; eight affected tests pass.
Fresh dense native facts match every lookup. `FluidContactOracle` runs actual
`EntityFluidInteraction.update` with supplied loaded chunks and current accumulation
disabled: 6,120 depths/dry-reset cases match, including flowing levels, mixed fluids,
waterlogging, 0.001 body deflation and surface/edge boundaries. Height uses original
feet and same-fluid above. Every required cell fits the existing geometry frame;
no query envelope/owner/timer changed. Full native integration includes both probes.
Evidence: `.local/fluid-{blocks,contact}-{native,check,tests}.log` and native cases.
No live fluid travel/current/eye-camera parity is claimed; those and the client
scenarios remain open.

Baseline on exact frozen `01c4627` passed actual render/walk/jump/stats, with
three original F2 hashes reviewed. Owned client stopped; safe v8 player state,
inventory/journal and all existing region edits/items/receipts conserved. Evidence:
`.local/client-tests/VMC-015d-baseline/report.md`. This covers startup/dry regression
for unused catalog/contact modules, not live fluids.

Local post-collision checkpoint `0ae6ef3`: `FluidMotion` keeps water/shallow-lava/deep-lava
drag and gravity distinct, including sprint, water efficiency, Dolphin's Grace,
climbing and the native bounded surface-escape query. The caller must resolve
that query against collision/fluid observations before applying the escape boost.
Four affected tests pass. `FluidTravelOracle` invokes actual `Player.travel` with
supplied contact/post-collision vectors and zero relative input: all 2,736 cases
and three 200-step water/lava transitions match bit-for-bit, including remote-Y
arithmetic. Logs/cases: `.local/fluid-travel-{native,check,tests}.log`. Current,
input/swim forces and live composition remain open; this is not a full physics
or world-collision oracle. The new native probes are in the integration runner;
the kernel checkpoint remains unpublished until its live/client gate.

Current checkpoint: all 35,723 native flow barriers/support classifications match
(41 compact property sets; 114 block-entity-dependent states stay explicit).
`FluidFlow` matches 13,312 native vectors; `FluidCurrents` matches 12,288 actual
`EntityFluidInteraction` player depth/current results, including shallow weighting,
minimum push, mixed fluids, fast lava and unaffected players. Required native cells
fit the existing frame. Eleven affected flow/contact tests pass; the refactored
contact scan still matches 6,120 native depths. Evidence: `.local/fluid-{boundaries,flow,currents}-{native,check}.log`
and `.local/fluid-flow-tests.log`. Current support for active shulker/piston block
entities was pending there; missing context fails.

Contextual support now matches 486 native support grids and 4,680 active shulker/
piston cases. FULL support requires native face equivalence, including interior
slices, rather than covering a face with oversized geometry. Shulker closed status
is explicit and independent of progress; unknown status still fails. Eighteen
affected voxel/flow tests pass. Evidence: `.local/fluid-support-{native,check,tests}.log`.
Input/swim forces and live composition remain open; live block entities still need
their future authoritative resource observations rather than invented defaults.

Client gate: actual water/lava entry/exit, shallow/deep and waterlogged boundaries,
swim/sink, wall/surface escape, flight, saved velocity and dry impulse regression.
Damage/oxygen, effects/complete swimming attributes and propagation need explicit
follow-ups. A scalar catalog or arithmetic-only probe cannot close this ticket.
