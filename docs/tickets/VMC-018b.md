# VMC-018b — Region-owned stationary items and snapshot replication

Status: Done — stationary foundation validated. Updated: October 14, 2026.
Depends on VMC-018a.
Foundation for VMC-005b2d2/035; these parents remain incomplete.

Historical scope below describes the ephemeral VMC-018b checkpoint. VMC-019a now
persists stationary items when world storage is enabled and recovers them after
owner replacement; nil storage retains ephemeral behavior. Its separate record
defines commit acknowledgments and remaining transfer/physics limits.

## Scope and acceptance

Before: item packets can be sent as connection fixtures but have no world owner.
After: region owners admit bounded stationary development items, replace their
stacks and remove them; observers replicate owner-published snapshots without
per-item processes or mutation/event fan-out into connection mailboxes.

- Region-local admission validates nonempty supported stacks and finite preview
  positions belonging to that region. Limit each region to 256 items and 512 KiB
  of cached spawn/metadata bytes. Rejection leaves all state unchanged.
- Allocate unique runtime IDs/UUIDs in the owner. Mutations require its incarnation
  token and the item's current revision. Stale revisions/incarnations fail;
  removals cannot recreate an entity. A dead owner cannot be retried blindly.
- Publish compact immutable packet views through an owner-owned protected ETS
  table. Registry metadata locates the table. Reads never allocate regions or
  call suspended owners; owner loss destroys its publication automatically.
- Each connection samples only its subscribed regions and already-sent chunks.
  Spawn precedes metadata, updates preserve identity, leaving visibility removes
  the item, and returning/reconnecting receives its current state. Owner loss
  removes stale client entities on the next observation.
- Bound observation to 64 regions/1024 visible items, retained entities to 1024,
  and each item replication interval to 64 additions/updates and 256 KiB of logical
  packet bytes (framing/compression overhead is additional). Removals
  precede additions/updates. Round-robin scanning prevents an always-dirty low ID
  from indefinitely starving later changes. Share cached binaries across observers.
- Regressions cover bounds, negative boundaries, byte rejection, CAS races,
  protected/publication failure, independent owners, incremental replication,
  loaded-chunk filtering, reconnect, and region replacement. Full format/tests/
  release/Mojang protocol oracle/public-tree audit must pass.

Actual Minecraft 26.3 scenario through CUA: join localhost, create a stationary
item along the current camera ray using the region API (not connection packet
injection), observe rendering, replace stone with eggs, reconnect and observe
the same current item, then remove it. Create another item and terminate its
region; observe disappearance and a healthy session. Recreate the region and
verify an old handle is rejected. Inspect client logs; clean all fixtures.

## Ownership and limits

This is explicitly a development scene API, not inventory-drop admission.
Items have zero velocity and no gravity until authoritative physics exists.
The only mutations are ordered create, compare-and-swap stack replacement and
compare-and-swap removal. There is no simulation tick, cross-region movement,
merging, pickup, despawn, item persistence or acknowledged durable transfer.
Owner death/restart intentionally loses these ephemeral items. A mutation call
timeout has an uncertain outcome; callers must inspect the same surviving owner,
not retry creation. No player inventory may be consumed by this API. Inventory
ownership/persistence and a recoverable transfer ledger must precede gameplay
drop integration. Replication snapshots confer no mutation authority.

## References

Pinned Mojang 26.3 jar SHA-1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`: `ServerEntity.sendPairingData`
sends spawn before tracked metadata; `sendDirtyEntityData` publishes changed
accessors. `ItemEntity.setItem` changes its synchronized item accessor. The
actual packet codecs/facts are validated by VMC-018a and the full oracle.
Private bytecode is under ignored `research/disassembly/VMC018b-ServerEntity.txt`.
Chunk-square preview interest filtering remains an explicit simplified policy,
not vanilla entity tracking-distance parity.

SteelMC `f6fb4e49778c`, `steel-core/src/entity/storage.rs`, separates proto-chunk
staging from full-world ownership and explicitly returns ownership after closure.
Pumpkin `b0c48b2d7688`, `crates/pumpkin-core/src/entity/item.rs`, reserves merging
items around independently mutable fields. These are useful consistency boundary
examples. ValiMC uses one serial region owner and immutable observations rather
than their locks/atomics. Folia's exclusive region ownership informs the broader
architecture; boundary simulation/handoff remains VMC-012.

## Verification and checkpoint

October 14, 2026, Elixir 1.20.4 / OTP 29.1.1, actual Java 26.3:

- Format passes; all 102 ExUnit tests pass. Ten added regressions cover supported
  patches, negative region boundaries, empty/invalid stacks, 256-item and aggregate
  byte rejection, no-op/CAS revision behavior, concurrent mutation serialization,
  protected ETS and suspended owners, killed-owner cleanup, stale incarnation
  rejection and read-only missing regions. Replication tests exercise 64-change
  pacing, continuously dirty low IDs, large binary byte pacing and the full 1024
  visible population. Actual TCP sessions cover current stacks for late joiners,
  visibility removal/reentry, explicit removal and owner loss without session loss.
- Production release and full `scripts/check_vanilla.py` pass. Existing Mojang
  inventory behavior, 9 item fixtures, 272 packed vectors, 25 entity packets and
  compressed login/registry/chunk/inventory/player/block/command scenarios remain
  passing. No new wire IDs or serializers were guessed. Observation/mutation
  behavior is covered by the owner/TCP tests; the codec oracle alone is insufficient.
- The final release restarted at 00:09:09 with the existing temporary world.
  CUA screenshot access recovered using the exposed Raise action after an initial
  `cgWindowNotFound`. A coordinate click still rejected `noWindowsAvailable`.
  Tab/Return joined localhost. The isolated SDL event-position adapter remains
  loaded; this slice's UI actions used keyboard input, with no mouse-pass claim.
- The region API created stone 7 with glint/custom NBT half a block along the
  actual camera ray. Its publication was sampled by normal connection replication
  and visibly rendered stone. Replacing with eggs 3 preserved the ID and produced
  the visible egg; removal using revision 1 returned `stale_item` after revision 2.
  No fixture wrote packets into the connection or consumed its inventory.
- Actual Escape/Tab/Shift-Tab/Return disconnected; Down selected localhost, and
  Return rejoined. The same current egg was visible after reconnect. Removing
  revision 2 made it disappear and emptied the region publication.
- A second visible stone was created, then its actual region was gracefully
  terminated and recreated. The item disappeared, the replacement publication was
  empty, and an old-incarnation handle directed at the replacement was rejected
  with `stale_region`. Actual keyboard `/stats` displayed one player/four regions/
  ten schedulers. This used graceful region termination, not a crash-durability test.
- All scene fixtures are removed; owner inventory remains empty. Private log copy
  under `.local/client-tests/VMC-018b/` contains zero Network Protocol Error,
  DecoderException, EncoderException or ERROR entries. Earlier inventory mouse
  gates remain pending; they are not reclassified by this keyboard/scene test.

No simulation, gravity, merging, pickup, despawn, entity persistence, survival
tracking-distance or recoverable inventory/world transaction claim follows from
this foundation. No performance benchmark was warranted. Next: bounded durable
supported-inventory state (VMC-005c1), before a recoverable drop ledger/handoff.

Subject: `VMC-018b: own stationary items in regions and batch their replication`.
Branch: `main`; keep behind existing unverified ancestor client gates.
