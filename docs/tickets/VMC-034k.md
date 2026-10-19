# VMC-034k — Live owned cooking menus and exchanges

Status: Done
Note: Done within live viewing/manual exchange scope at `6264a79`. Automatic cooking/XP remain separate.

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

October 18 implementation: shared socket menu state now admits native furnace 14,
smoker 22 and blast 10 views. Region-owned metadata supplies content/properties;
existing bounded player candidate/admission/delivery/seal and coalesced viewer
paths handle writes and refresh. No new owner, worker class or timer was added.
Processors never register chest openers, lids or sounds. Input edits operate on
current owned heat/progress, not a copied observation.

Native 26.3 provider probe covers 360 contexts: all 24 processing states, five entity
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
Production, current native TCP and dedicated actual feature acceptance pass.

Frozen6264a79 passes 1,625 full tests, production and current native provider/both
TCP transports (`.local/cooking-live-{full-tests,production,native-tcp}.log`).
Dedicated actual menu feature validation passed against that immutable release
and a new whole source 20/typed20/item18/storage33 dataset. No release replacement.

Accepted actual 26.3 report `.local/client-tests/VMC-034k/report.md` (October 18):
all three models/native menus through overhead stone and static flame/progress,
actual Furnace split/merge/number/offhand/shift/input reset, invalid fuel/output,
one-bucket cap, ordinary seeded output withdrawal, XP-bearing pickup/shift refusal,
range closure and fresh reconnect pass. Shared-view/race/crash coverage is actual
TCP, not two graphical identities. Source/typed40, storage 47, item receipt 18 and
nil outbox retain exact components/quantities; XP3 and all other entries/blocks
remain exact. Both clients stopped 143; server 86790 flushed/stopped0. Root stopped
save audit passes;1,155 frozen blobs/eight dataset hashes are pinned in
`.local/cooking-live-publication-proof.json`. Every K gate is closed. No automatic
cooking, fuel consumption over time or XP award is claimed.
