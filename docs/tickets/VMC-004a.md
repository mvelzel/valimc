# VMC-004a — Bounded item stacks and scalar component patches

Status: Awaiting client validation. Updated: October 13, 2026. Depends on VMC-002.
VMC-003 is parked awaiting client validation; this slice does not change storage.

## Scope and acceptance

The preview currently reads only the beginning of a creative stack, discards
component-bearing items and stores a block ID rather than a stack. Introduce
pure versioned stack codecs and preserve accepted scalar component patches.

- Pin all item/component IDs and item stack-size/damage defaults from the official
  26.3 runtime. No dynamic network atoms or registry lookup scans on the hot path.
- Decode and encode empty/default stacks and the initial scalar patch set in both
  ordinary clientbound and length-delimited creative-input formats.
- Bound bytes, component counts and lengths. Reject unknown IDs, duplicate or
  overlapping patches, truncated/trailing input and invalid stack invariants.
- Preserve removals. Unsupported known components reject the edit and restore the
  previous authoritative hotbar slot; they never become an accepted empty stack.
- Accepted creative edits retain item identity/count/patch and correct the slot
  on the client. Ordinary block placement continues to use the selected stack.
- Mojang generates input fixtures and decodes Elixir's encoded output for empty,
  ordinary, non-block, scalar, removal and mixed-patch cases. TCP oracle exercises
  metadata round trips and an unsupported-component correction.

Actual-client scenario, pending while locked: select ordinary blocks/non-block
items in creative; place a block and clear its slot. Exercise a scalar-patched
fixture through the session and inspect the client's tooltip/count; attempt an
unsupported compound item and verify the previous slot and explanatory message.
Inventory clicks/menus, persistence and structured codecs are separate slices.

## References and design

Vanilla jar `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`, protocol 777:
`ItemStack` optional/validated codecs and component invariants;
`DataComponentPatch` ordinary/delimited codecs;
`ServerboundSetCreativeModeSlotPacket`, `ClientboundContainerSetSlotPacket`,
`FriendlyByteBuf.readContainerId` and
`ServerGamePacketListenerImpl.handleSetCreativeModeSlot`.
Private bytecode dumps remain in ignored `research/disassembly/`.

SteelMC `f6fb4e49778c`,
`steel-registry/src/data_components/registry/patch_network.rs`, explicitly
separates ordinary and delimited formats. Its slice decoder inspired bounded
sub-binaries; its implementation is not a semantics oracle. Pumpkin
`b0c48b2d7688` uses generated component registries; pin equivalent wire facts
from our target version instead of adopting a different version's numeric IDs.

Stack data stays in the socket/session owner. The codecs are pure functions;
there is no new process or global inventory coordinator. Small immutable registry
facts are compiled into indexed maps. Structured components remain VMC-004b,
and full slot ownership/transactions remain VMC-005.

Implemented: 1,658 item definitions and 122 component IDs, twelve scalar codecs
(stack limit, max damage, damage, repair cost, rarity, unbreakable, creative lock,
intangible projectile, glint override, item model, tooltip style and minimum
attack charge). Stack bytes are capped at 64 KiB and patch count at the registered
component count. Duplicate/overlapping patches and invalid/trailing values fail.
The preview accepts hotbar slots only; full player slots are VMC-005a. Inputs that
exceed these resource limits are deliberately rejected rather than claiming
unrestricted vanilla component coverage. Unsupported compound values are never
stored or echoed as accepted state.

## Verification

October 13, 2026: all 36 ExUnit tests, formatting and production release pass.
New tests cover both stack formats, scalars/removals, item defaults, namespace
normalization, truncated/trailing/oversized input, duplicate/unknown component
IDs, stack-size/damage invariants, slot restoration and peer isolation.

Mojang-generated fixtures are decoded and cross-converted by Elixir; Mojang's
ordinary and validated untrusted codecs decode all eight resulting cases and
compare semantic stack equality. The full TCP oracle also passes the 49-chunk
baseline plus glint/count preservation, unsupported-name slot correction and
placing a component-bearing block. The independent oracle exposed the intangible
projectile component's NBT unit encoding; it is now encoded as an empty network
NBT compound, unlike unbreakable's zero-byte unit.

`scripts/check_vanilla.py` runs both oracle stages. Private fixtures/logs stay
outside the public tree. Public-tree audit/self-tests and staged diff check pass.
Actual-client scenario remains queued; no GUI pass claimed while the user's
MacBook is locked. This slice and the overall VMC-004 subsystem are not Done.

## Checkpoint

Planned subject: `VMC-004a: add bounded item codecs and creative slot corrections`.
Branch: `codex/minecraft-implementation`. Commit locally after automated checks;
push deferred until required manual validation. Next: VMC-005a or VMC-004b.
