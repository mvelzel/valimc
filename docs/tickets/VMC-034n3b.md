# VMC-034n3b — Live remote XP spawn delivery

Status: Planned. Depends on the [durable protocol](VMC-034n3a.md); part of
[orb ownership](VMC-034n3.md). This covers initial remote spawning, not moving
an already active orb or enabling earned-output withdrawal.

Source owners must route pending awards to the owner of their spawn position.
Use the stored intent before delivery, the destination's durable adoption before
publication/ACK, and the source's matching digest before marking delivery settled.
Retain the immutable recipe obligation. Replays must never create another effect.

Implementation/acceptance:

- Keep CPU validation/publication planning on bounded workers and destination I/O
  on bounded transfer workers. One delivery in flight per source region; rotate
  retries with deadlines/backoff. Waiting on another owner never blocks a region.
- Use epoch/lease/token fences and the shared durable write lane. Rebase only the
  routing/adoption delta into current containers, preserving concurrent cooking,
  slots, receipts and local orbs. Publish/ACK only after the exact successful write.
- Include transfer revision in scheduling/publication fences. Cold owners retry
  pending routes and rebuild adopted native records with stable UUIDs/fresh IDs.
  Combine imports/local views under existing 256-award/2,816-record, frame, chunk
  observation and observer pacing limits. Remote source regions expose no copy.
- Duplicate adoption returns its original success without another effect. Full or
  unavailable destinations retain the source intent. Late/uncertain callbacks,
  worker saturation, owner/writer death and graceful shutdown conserve decisions.
  Receipt/creation records stay immutable; no eviction or pickup shortcut.
- Targeted owner/TCP regressions cover both endpoints, replay at each crash boundary,
  capacity refusal/retry, zero XP, simultaneous local cooking and stale observers.
- Actual client: cross the boundary and see the remote orb only at its destination;
  source/destination replacement and full restart preserve one scene and the exact
  ledgers. Repeat ordinary pickup/cooking/output-refusal negatives. Pickup/player
  XP and server motion/lifetime remain inactive and separately tracked.

References: pinned native splitting/codecs in the parent; `CookingOrbTransfers`
for immutable decisions and `ItemHandoffDelivery` for bounded delivery patterns.
Do not redo the accepted local runtime or durable protocol.
