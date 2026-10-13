# VMC-018a — Item entity wire and metadata foundation

Status: Done — wire foundation validated. Updated: October 13, 2026.
Dependency for VMC-005b2d2/035.
Parent VMC-018 remains incomplete. This ticket provides packet primitives rather
than enabling world drops before their authoritative owner exists.

## Scope and acceptance

Before: packet helpers only spawn/move/remove preview players; item entity
metadata and nonzero velocity are unavailable. After: pure bounded helpers can
encode item spawn, selected base/item metadata, velocity, pickup animation and
batched removal, verified independently with Mojang's actual 26.3 codecs.

- Generate pinned entity-type IDs, metadata serializer IDs and selected actual
  Entity/ItemEntity accessor indices. Commit only original extraction code and
  versioned protocol facts; classes/jars/dumps and fixtures remain ignored.
- Implement 26.3's packed velocity codec from pinned vanilla behavior, including
  zero/tiny values, signs, component quantization, scale continuation and limits.
  Byte-for-byte compare Elixir output with Mojang encoders across boundary cases;
  use Mojang decoders to verify values and complete packet consumption.
- Typed metadata supports shared flags, no-gravity and accepted item stacks.
  Reject unknown/duplicate fields, invalid IDs/UUIDs/coordinates/counts, bad value
  types and unbounded batches. Preserve supported stack patches/removals.
- Encode item spawn with velocity/angles/data, metadata updates, velocity updates,
  pickup animation and removal. No guessed older short-velocity or serializer IDs.
  Existing player packet behavior stays covered by the full protocol oracle.
- Meaningful tests cover framing/compression, all supported metadata types,
  exact stack bytes, empty metadata/stack, velocity boundaries, invalid helper
  inputs and removal/pickup bounds. Full format/tests/release/oracle/audit gates.

Actual-client scenario: use a private development fixture to send the new
packets through the existing socket owner to actual Minecraft 26.3. Observe a
nearby visible item entity; change its item metadata to a visibly different item;
remove it and observe disappearance. Exercise a second spawn/motion and pickup
animation/removal when observable. Computer use may navigate by keyboard if
coordinate clicks remain unavailable. Inspect client logs. These wire fixtures
do not prove authoritative drop/pickup, physics, persistence or ownership.

## References and design

Pinned vanilla 26.3 jar SHA-1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`: `ClientboundAddEntityPacket`,
`ClientboundSetEntityDataPacket`, `ClientboundSetEntityMotionPacket`,
`ClientboundTakeItemEntityPacket`, `ClientboundRemoveEntitiesPacket`,
`Vec3.LP_STREAM_CODEC`, `EntityDataSerializers`, `SynchedEntityData.DataValue`,
and Entity/ItemEntity metadata accessors. Private bytecode dumps stay ignored.

SteelMC `f6fb4e49778c`, `steel-protocol/src/packets/game/c_add_entity.rs`,
`c_set_entity_motion.rs`, `c_set_entity_data.rs`, and
`steel-core/src/entity/entities/objects/items/item_entity.rs` provide packet and
subsystem boundary ideas. Pumpkin `b0c48b2d7688`,
`crates/pumpkin-core/src/entity/item.rs` and `synched_entity_data.rs` provide a
separate implementation comparison. Vanilla defines the codecs and indices.

This is original pure Elixir encoding and shared immutable facts. No new global
gameplay coordinator or process per item is introduced. Region-owned simulation,
interest management, tick phases, transfers/fencing, durable drop acknowledgments,
physics and transactional pickups are required follow-ups before gameplay drops
can consume inventory items. Do not treat fixture entities as simulation state.

## Verification

October 13, 2026, Elixir 1.20.4 / OTP 29.1.1:

- Format and all 92 ExUnit tests pass. New regressions cover packed-vector
  quantization, zero/tiny vectors, six-to-eleven-byte scale continuation, unsigned
  maximum scale, clamping, malformed/truncated inputs, packet framing/compression,
  metadata identity/patches, float32 angle boundaries and invalid/bounded helper
  arguments. List admission inspects at most limit + 1 elements.
- Production release build and full `scripts/check_vanilla.py` pass, including
  272 independently generated/encoded velocity cases and 25 complete packets.
  Exact bytes match except unordered component-patch entries: actual Mojang
  metadata decoding confirms typed accessor values, stack identity/count and
  exact patch/removal contents. Complete consumption and re-encoding check all
  other packet types. Existing inventory/protocol/registry TCP scenarios still pass.
- The generator extracts 161 entity types and 44 serializers. Selected accessors
  are shared flags index 0/serializer 0, no-gravity 5/8, item stack 8/7. Item type
  is 72. Regeneration is byte-for-byte reproducible with sorted fact maps.
  `LpVec3` uses 15-bit components and a split scale with an unsigned VarInt tail;
  the positive maximum scale exercises all five tail bytes. Elixir cannot carry
  NaN/infinity as numeric float values; finite out-of-range inputs clamp as vanilla.
- Release restarted at 23:40, using localhost:25565 and the existing temporary
  world. Actual Minecraft 26.3 rejoined via CUA Tab/Return navigation with the
  isolated SDL event-position adapter. AX/screenshot access needed app rebinding
  and Raise once; keyboard navigation worked. Mouse-pickup gates from prior
  tickets remain pending and are not reclassified by this test.
- Private fixtures queued the new packets through the actual socket owner's
  existing outbound batch. A first item placement was not visible from the chosen
  view; a closer fixture 0.5 blocks along the camera ray visibly rendered stone 7
  with glint/custom NBT. Updating item metadata visibly changed it to eggs 3.
  Explicit removal made it disappear. These are wire/render fixtures, with no
  authoritative item owner or inventory consumption.
- A second visible spawn included nonzero packed velocity (0.0001 on X); a zero
  motion update was accepted while it remained rendered. A pickup-animation packet
  referencing the actual player and count 7 made the fixture disappear before
  explicit cleanup. Screenshot latency did not capture the transient animation
  frames or quantify a motion trajectory; those timing/physics gates belong to
  gameplay implementation. The authoritative player inventory remained empty.
- After the final bounded-list helper change, the pure packet module was loaded
  from the rebuilt release into the running test VM. Fresh render/egg-update/remove
  checks passed again with those final helpers. All fixtures were removed; F3 was
  restored to its initial hidden state. Logs under private
  `.local/client-tests/VMC-018a/` contain no Network Protocol Error,
  DecoderException, EncoderException or ERROR entries.

No gameplay drops/pickups, item collision/gravity, despawn, merging, persistence,
interest management or ownership/recovery claims follow from this foundation.
VMC-018/035/005b2d2 remain incomplete. No performance benchmark was warranted.

## Checkpoint

Subject: `VMC-018a: encode item entities and packed velocity with vanilla codecs`.
Branch: `main`. Local validated checkpoint; unpushed ancestors VMC-005b2c and
VMC-005b2d1 retain their client gates, so this commit also stays local. Next:
bounded region item ownership and its inventory-transfer/recovery contract.
