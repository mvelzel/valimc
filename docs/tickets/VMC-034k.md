# VMC-034k — Live owned cooking menus and exchanges

Status: Implementing; prior unused foundations are VMC-034g–j.

Acceptance: all three stock processor menus open through fresh native-range
admission, show three storage/36 player cells and four progress properties, and
support bounded ordinary pickup/shift/number/offhand exchanges through the existing
player prepare → region receipt → seal protocol. Preserve input-reset behavior,
shared-view refresh, close/range/owner-loss fencing and reconnect conservation.
Output with recipe-use records remains refused until its complete XP award exists.

Keep socket state per connection, storage in its region and blocking work in the
existing bounded worker/writer lanes. Reuse coalesced container viewers without
chest lids/sounds for processors. No per-block process, global gameplay owner or
new simulation timer. This slice does not automatically cook or award XP.

Pinned references: AbstractFurnaceBlock/BaseEntityBlock menu provider,
AbstractFurnaceBlockEntity/Container still-valid checks, validated menu codecs,
slot planner, external edit hook and receipt kernels. Reject inconsistent owned
metadata; raw malformed-world providers are not a gameplay contract.

Verify native provider/range conclusions and targeted actual packet/owner tests.
Dedicated client: all three menu models/progress, input/fuel deposit/withdraw,
invalid fuel/output, bucket cap, shift/number/offhand, shared refresh/close and fresh
reconnect. Use a new whole dataset and immutable checkpoint after baseline J ends.

October18 implementation: shared socket menu state now admits native furnace14,
smoker22 and blast10 views. Region-owned metadata supplies content/properties;
existing bounded player candidate/admission/delivery/seal and coalesced viewer
paths handle writes and refresh. No new owner, worker class or timer was added.
Processors never register chest openers, lids or sounds. Input edits operate on
current owned heat/progress, not a copied observation.

Native26.3 provider probe covers360 contexts: all24 processing states, five entity
types and air/stone/water above. Missing providers refuse; native providers do not
query the upper block. ValiMC also fences inconsistent owned types. Native
BaseContainerBlockEntity.stillValid delegates identity plus Container's4.0 extra
range to Player.isWithinBlockInteractionRange; reuse the already-verified strict
box kernel. Probe/comparison `.local/cooking-opening-{native,comparison}.log`.

66 affected checks pass(seed453749), `.local/cooking-live-targeted-final.log`.
Eighteen real TCP scenarios cover all types/both permissions, four properties,
pickup/split/merge/shift/offhand, input resets, invalid deposits, one-bucket cap,
XP-bearing terminal refusal, spectator/shared refresh, two-player race, stale ids,
range/owner closure, pending-candidate cancellation, prepared-owner crash recovery
and reconnect. Earlier test expectations for a matching cursor and a stack field
were corrected; no production regression was found. Formatting/compile pass.
Production, current native TCP and dedicated actual feature acceptance remain.

Frozen6264a79 passes1,625 full tests, production and current native provider/both
TCP transports (`.local/cooking-live-{full-tests,production,native-tcp}.log`).
Dedicated actual menu feature validation is running against that immutable release
and a new whole source20/typed20/item18/storage33 dataset. No release replacement.
