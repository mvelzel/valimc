# VMC-029b — Authoritative placement

Status: Native context research started. October 16, 2026.

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
