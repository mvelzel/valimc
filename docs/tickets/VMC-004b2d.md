# VMC-004b2d — Tooltip display controls and component type index

Status: Done
Note: Done — supported tooltip controls validated, local. Updated: October 14, 2026. Depends on effective stack identity and supported names/lore/enchantment data.

## Scope and acceptance

Before: `minecraft:tooltip_display` additions are unsupported. After: its whole
tooltip flag and hidden-component set round-trip both stack formats, menus,
snapshots, outboxes and stationary items. Hiding presentation must preserve the
underlying names/lore/enchantment values. All known component types may be hidden,
including types whose value codecs are not implemented yet.

- Follow pinned Mojang `TooltipDisplay`/`DataComponentType` stream codecs,
  equality and `shows`. Check all component IDs, noncanonical nonzero booleans,
  duplicate/order set behavior, defaults/removals and hidden values retained even
  when the whole tooltip is hidden. A 1,024 raw-entry guard bounds duplicate work;
  unique sets cannot exceed the pinned component registry.
- Use one pure compiled component index, shared with ItemTypes, so default
  semantic keys can be prepared without a compilation dependency cycle. No new
  process or global coordinator. Canonicalize newly accepted set encoding while
  preserving all previously supported raw stack/journal encodings and digests.
- Independent Mojang decoding/equality/default fixtures, meaningful ExUnit/TCP
  failures, conservation and exact snapshot/receipt recovery must pass. Complete
  format/tests/release/full Mojang oracle/public audit and exact diff review.

Actual Minecraft 26.3 via CUA: normal connection fixtures place an item with a
name, lore and enchantments in hovered slot 13. Actual E shows all sections, then
only requested sections disappear; hide-all removes the whole tooltip, and reset
restores it. Glint and underlying values remain. Actual close merges equivalent
set orders/defaults and keeps differing visibility controls separate. Actual
Q/Ctrl+Q commits exact supported data/controls. Reconnect/full restart restores
UUIDs/maps/tooltip behavior without reseeding. Unknown IDs/truncation reject only
their session and never replace accepted state. Restore original empty inventory/
pose and remove only pinned entities, preserving source counters/receipts.
These tests do not prove earlier mouse gestures or enchantment gameplay effects.

## References and design

Pinned Mojang 26.3 SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`TooltipDisplay`, `DataComponentType.STREAM_CODEC`, `ByteBufCodecs.BOOL` and
collection codec, `DataComponents` defaults and actual ItemStack equality. Private
bytecode stays in ignored `research/disassembly/VMC004b2d-*`.

SteelMC `f6fb4e49778c`, `steel-registry/src/data_components/components/tooltip_display.rs`,
separates component identifiers from network IDs and uses set membership.
Pumpkin `b0c48b2d7688`, `crates/pumpkin-data/src/data_component_impl/basic.rs`,
preserves tooltip-display NBT as a component; neither is a vanilla wire oracle.
Vanilla record/set equality and actual client rendering are the authority.

## Verification

October 14 automated checkpoint: format, all **254 ExUnit tests** (seed 544022),
production release and full Mojang oracle pass. The tooltip harness checks **264**
raw cases, **32,896** equality pairs, `shows` for all **122** component types and
native decoding of **256** Elixir controls/stacks in both formats. Re-extracted
prototype defaults and **18,430** stack identity pairs pass. The full TCP oracle
accepts selective tooltip controls while retaining underlying custom data.
Public-tree audit passes 168 paths. Private logs:
`.local/vmc004b2d-{tests,release,oracle}.log`.

Nine new tests cover IDs, nonzero booleans, set/default identity, hidden-data
preservation, bounds/malformed input, authoritative close, exact snapshot/outbox/
item receipts and TCP owner isolation. A test's immediate post-login owner lookup
raced play initialization; tooltip/enchantment failure tests now wait for world
initialization before inspecting their owners. Runtime login behavior is unchanged.

Native sets collapse duplicates and compare without order; hide-all keeps its
hidden set significant. Compiled default keys use that semantic identity while
previously supported encodings/receipt digests remain unchanged. The native
1,025-entry duplicate case intentionally exceeds the local work guard; every
unique vanilla component set fits. Hidden types with unsupported value codecs
are accepted because this field names types, not values.

October 14 actual Minecraft **26.3**, installation `ValiMC computer-use test`,
app `local.valimc.minecraft-client`, localhost production release: CUA E opened
ordinary inventory with normal owner-packet fixtures in hovered slot 13. The
Unicode custom name, Unbreaking III, lore and glint rendered. Selectively hiding
lore/enchantments kept the name/glint; hide-all removed the tooltip, and reset
restored all text. Each accepted stack retained all underlying component values.

Actual E close merged reversed/duplicate-decoded sets and explicit defaults to
64 + 9. Different hide flags, and different memberships with both tooltips wholly
hidden, stayed 63 + 10. Server state and saved slots/cursor matched each result.
Fixture cursor setup is explicit; these checks exercise close, not mouse pickup.

Actual Q and held Ctrl+Q dropped 1 + 6 with exact name/lore/enchantment/controls,
advancing the source from 27 to 28/29. CUA third-person/back-step observed glinting
stationary models. Normal reconnect restored inventory and both pinned records.
A full release restart at **07:36:16 CEST** restored exact entity UUIDs, stacks,
controls and counter 29. E showed saved selective hiding without reseeding.
Unknown ID 122 and truncated tooltip fixtures entered the normal connection
packet path; each produced the actual malformed-item disconnect, preserved
accepted inventory and left the listener alive. ExUnit TCP tests separately prove
unrelated-session isolation; these malformed fixtures are not client UI gestures.

Cleanup removed only the two pinned fixture UUIDs through durable region APIs,
then restored the original empty inventory/pose through a fresh player writer.
Counter 29 and region receipts 29/27 were retained. Actual rejoin and E confirmed
empty slots and the restored world/pose at **07:39 CEST**. Private client log at
`.local/client-tests/VMC-004b2d/latest.log` has zero ERROR/DecoderException entries.
Fixture scripts/context remain private under `/tmp/valimc-vmc004b2d-*`.

No runtime repairs were needed during manual validation. Full components,
survival rules and earlier mouse-input gates remain incomplete.
