# VMC-019a — Persistent stationary item records and commit fencing

Status: Done — stationary record recovery validated. Updated: October 14, 2026.
Depends on VMC-018b/005c1.
VMC-019 and gameplay drops/pickups remain incomplete.

## Scope and acceptance

Before: stationary region items disappear when their owner/VM is replaced.
After: accepted item creation, replacement and removal have a storage acknowledgment
before publication/reply. Region/VM replacement restores committed UUIDs, positions
and exact supported stacks with fresh runtime IDs/incarnations.

- Use a bounded versioned/checksummed custom item file per region, pinned to 26.3
  data version 5023. Preserve UUID/XYZ/stack; omit runtime IDs, incarnation tokens,
  revision counters and cached packets. Cap records at 256 and reads/encodings at
  a limit compatible with the existing 512 KiB cached-packet admission budget.
  Reject malformed, oversized, wrong-region/version/identity, duplicate UUID,
  empty or unsupported stack records atomically; preserve invalid files.
- Existing region writers perform serialization/synced temporary replacement.
  Item files are separate from block snapshots so older block saves cannot
  overwrite newly committed items. No disk I/O or blocking save call in a live
  region's item mutation handler. Keep one pending item proposal; reject additional
  mutations as busy while block reads/edits/ticks and publication reads progress.
- Publish/reply only after a matching writer/token acknowledgment. Stale replies
  cannot commit another proposal. No-op stack replacement avoids disk work.
  A write failure, writer loss, deadline or shutdown with a pending operation has
  an uncertain commit outcome: fence/stop the owner, reload the actual valid file,
  and never retry creation blindly or roll an old snapshot over a possible commit.
- Recovery rebuilds cached immutable views and a fresh owner epoch; old mutation
  handles fail. Add bounded UUID lookup to obtain the current handle. Nil world
  storage retains the explicit ephemeral testing behavior. Gameplay must still
  never consume player inventory through this scene API.
- Tests cover record validation/bounds/patches, pending-publication isolation,
  stalled writer independence, busy admission, no-op behavior, acknowledgments,
  failure/deadline/shutdown recovery, old-handle fencing, exact UUID/stack recovery,
  removal persistence, independent block saves and invalid-file preservation.
  Run format/full tests/release/full Mojang oracle/public audit.

Actual Minecraft 26.3 via CUA: create a patched stationary item through the region
API and observe it. Replace its stack, gracefully stop/recreate its region, and
observe recovery with the same UUID/current stack and fresh runtime handle. Restart
the full release, reconnect and observe the same item without reseeding. Remove
it, restart/reconnect, verify absence. Inspect logs and leave the test world clean.

## References and failure contract

Pinned Mojang 26.3 jar `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`Entity` save/load owns UUID and position; `ItemEntity.addAdditionalSaveData/
readAdditionalSaveData` owns Item, age, pickup delay, health and owner/thrower data.
This slice persists only existing stationary preview fields, not those unimplemented
gameplay fields or vanilla NBT entity files. Private bytecode stays ignored.
SteelMC `f6fb4e49778c`, entity storage and player-data atomic file replacement;
Pumpkin `b0c48b2d7688`, item entity/state persistence; Paper/Folia region ownership
provide boundary ideas. Pinned vanilla, not a rewrite's omissions, defines parity.

Owner-local proposals and fenced writer acknowledgments preserve serial mutation
ordering without a global gameplay coordinator. Separate region owners and writers
remain independently scheduled. Synced replacement does not promise parent-directory
fsync/power-loss durability or exactly-once create retries. A file may commit even
when its caller does not receive a reply. UUID-based transfer receipts/recovery
ledgers, atomic inventory-to-world effects, physics, age/despawn, merging, pickup,
cross-region handoff and vanilla tracking-distance rules remain required follow-ups.

## Verification and checkpoint

October 14, 2026, Elixir 1.20.4 / OTP 29.1.1, actual Minecraft Java 26.3:

- Format and all 122 ExUnit tests pass (seed 739466). Eleven new regressions cover
  exact UUID/position/scalar/NBT/removal preservation; fresh handles; record/file
  count/byte limits; duplicate, unsupported, empty, wrong-region/version/checksum,
  trailing and truncated data; mutation/replacement/removal recovery; no-op saves;
  unpublished stalled proposals; busy admission; block operations during a stalled
  item write; stale writer/token/deadline replies; actual rename failure; writer
  loss; deadline fencing; corrupt-file preservation; independent block saves; and
  shutdown after physical commit but before delivery of its acknowledgment.
  Concurrent CAS tests admit one success and permit busy/stale rejections for
  competing requests during the storage gate. Nil-storage behavior stays covered.
- Production release and full Mojang codec/TCP oracle pass, retaining the existing
  registry/chunk/inventory/entity/player/command coverage. New item files are
  custom version 1/data version 5023 with a maximum 524,343 bytes (plus one read
  sentinel), 256 records and a SHA-256 checksum. Cached publication limits still
  gate reconstructed state. The publication audit also rejects `.items` binaries.
- The pending operation holds one proposal, caller, token and deadline. Only a
  matching writer/token acknowledgment publishes it. A no-op returns immediately;
  errors/expired pending work stop the owner with an uncertain result. A suspended
  region allowed its writer to physically commit a new stack while withholding
  acknowledgment delivery, then shutdown/recovery preserved that new stack. No
  rollback snapshot was written. Tests are failure-boundary evidence, not a
  parent-directory/power-loss durability qualification or exactly-once retry claim.
- Actual release restarted at 00:49:16 using the existing temporary world. CUA
  window observation initially failed `cgWindowNotFound`; fresh app binding and
  its exposed Raise action recovered AX/screenshots. Keyboard Tab/Return joined
  localhost. The isolated SDL adapter remains loaded; no mouse action was needed.
- The region API admitted stone 7 with glint/custom NBT half a block along the
  actual camera ray. After the accepted API reply, its 131-byte item file decoded
  to the exact owner record; Minecraft visibly rendered it. Stack replacement
  produced eggs 3 with the same supported patches, confirmed in the file after
  reply and visibly changed the model. Ordering is established by the controlled
  acknowledgment tests above. One screenshot call was slow but returned successfully.
- Graceful region termination/recreation recovered exact UUID/XYZ/stack fields.
  Runtime ID changed from 930 to 1602 and revision reset to 1; a handle with the
  old epoch directed at the replacement returned `stale_region`. Minecraft still
  rendered the recovered egg through normal snapshot replication. Transient
  removal/re-spawn timing was not measured from screenshots.
- Full release stop/start at 00:53:45, then actual keyboard rejoin, rendered the
  same egg without a creation fixture. File/owner assertions matched UUID,
  position and exact patched stack; its new VM allocated runtime ID 645. IDs are
  reallocated per VM and may numerically coincide across other VM lifetimes.
- UUID lookup obtained the current handle; removal saved an empty 55-byte item
  file before replying, and the client visibly cleared it. A second full restart
  at 00:55:14 and actual rejoin left it absent. Current UUID lookup returned missing,
  the item publication/file remained empty, and player inventory stayed empty.
- Private client log copy under `.local/client-tests/VMC-019a/` contains zero
  Network Protocol Error, DecoderException, EncoderException, Duplicate entity or
  ERROR entries. No scene fixture remains. Existing inventory mouse-validation
  gates remain pending. No benchmark was warranted.

The current region bootstrap still awaits its existing block/item load calls;
fully asynchronous bounded region admission/load scheduling is a follow-up, not
a claim of this slice. Block snapshot format/load hardening remains VMC-020/055.
All broader item gameplay fields, physics/age/despawn/merging/pickup, vanilla NBT,
transfer receipts, cross-region ownership and inventory consumption remain incomplete.
Next: durable player outbox/region transfer receipts and recovery reconciliation.

Subject: `VMC-019a: persist region items before publishing accepted mutations`.
Branch: `main`; retain existing ancestor mouse-validation gates before push.
