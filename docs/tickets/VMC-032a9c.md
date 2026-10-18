# VMC-032a9c — Bounded chest viewers and lid events

Status: Runtime/targeted checks pass; measurement, production and client gate pending.

Acceptance: a region owns bounded viewer records keyed by socket/session reference,
with process monitors and per-position indexes, never a process per chest. One
pending revision notice per viewer coalesces writes until its authoritative refresh;
idle viewers need no repeated region queries. Keep local range/life checks, owner
fences and source-intent ordering. Close/removal/death/replacement retire records;
late close/refresh events cannot affect a newer menu. Spectators do not open lids.
Native ordinary-chest block events open on the first eligible viewer and close on
the last, including disconnect. Stored contents remain private to actual viewers.

Pin native ChestBlockEntity.startOpen/stopOpen/signalOpenCount/triggerEvent,
ContainerOpenersCounter, ChestLidController and ClientboundBlockEventPacket. Original
probes must establish spectator/removal exclusions, first/last transitions and
wire/lid semantics. Sounds, trapped/double chests, game-event consumers and physical
lifecycle can remain explicit later slices. Preserve vanilla presentation while
using BEAM monitors and coalescing rather than upstream periodic entity scans.

Verify reference fencing, bounded fanout/pending notices, two viewers, disconnect,
owner loss, source-pending refresh and non-viewer privacy over real TCP. Measure
equal idle-viewer workloads against8503ab6 before any efficiency claim. Dedicated
client scenario: chest open/close rendering, another scripted viewer retaining the
lid, disconnect cleanup and unchanged item/counter state through fresh reconnect.

October18: ChestViewOracle passes eight native single-chest traces and18 packet
cases. Eligible counts1/2/1/0 emit event1; spectators and removed entities do not
count. Native lid ticks reach0.5/1/0, with first/last sound calls captured only.
Chest block registry ID245 and six binary occupancy bodies match. Native256/512
counts truncate to0 on the wire; sending1 for any positive occupancy preserves
the ordinary lid result without that wrap. Raw `.local/chest-viewer-native.json`,
`.local/chest-viewer-native-comparison.log`. No sound delivery claim.

The pure bounded registry passes11 affected checks(seed703935), including1024
viewers, duplicate/replaced references, stale close/DOWN, spectators, targeted
invalidation and one pending notice carrying a monotonic revision highwater.
Old snapshots cannot acknowledge a newer pending change. Kernel evidence: `.local/chest-viewer-kernel-tests.log`.

Runtime subscriptions now use the existing bounded owner query lane. Each menu has
an owner monitor and fresh view reference; region records monitor connections and
coalesce committed entry revisions until an owner-authoritative refresh. Pending
source transactions defer refresh; seal still forces a combined inventory/view
snapshot. Idle chest ticks only check local range/life and the published owner
fence. Crafting tables retain their existing behavior. Actual target changes,
close, disconnect and owner replacement retire views; cover changes preserve an
already-open view. Public protected-ETS snapshots contain only lid positions/shared
frames, never contents. Nearby connections track visible lids with one monitor per
owner, bounded64 owners/4096 positions, and close them on owner loss/unload.

109 affected checks pass(seed741413), including all ten exchange TCP scenarios,
three new TCP groups for zero repeated idle queries, late-chunk/non-viewer privacy,
first/last/spectator/stale references and active/passive owner loss. Pure tests cover
coalesced revision highwater,1024 viewer bounds and visible-owner monitor retirement.
Raw `.local/chest-viewer-targeted-final.log`; initial test-fixture snapshot field
error was corrected before this passing run. Native viewer probe/comparison pass;
benchmark and graphical lid behavior remain separate gates.
