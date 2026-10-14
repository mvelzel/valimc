# VMC-004b2b — Bounded item names, lore and text identity

Status: Done — actual-client validated, local commit. Updated: October 14, 2026.
Depends on VMC-004b1 NBT and VMC-004b2a effective identity.

## Scope and acceptance

Before: custom/item name and lore additions are unsupported. After: accepted
literal/styled, translatable and keybind text, nested extras/root sequences and
translation arguments round-trip through item names/lore, inventories, files and
stationary items. Text/node/depth/byte work is bounded. Lore uses vanilla's maximum
256 lines, within the existing 64 KiB stack/512 KiB inventory limits. Selector,
score, NBT/object contents and interactive click/hover events remain follow-up
slices; reject unsupported text without accepting/echoing it as stored state.

- Implement original pure Elixir codecs. Preserve raw supported network NBT and
  journal bytes; use semantic text keys for merging/conservation/default equality.
  Equivalent root forms, color aliases and font namespaces compare as Mojang;
  content/style presence, sibling order and different meanings remain distinct.
- Extend pinned prototype extraction/identity verification for item names/lore;
  retain exact old receipt hashing. Validate malformed text, unsupported branches,
  count/size/depth/node limits and Unicode. No process per component or global
  gameplay coordinator; immutable values stay with existing owners.
- Independent Mojang codec/equality cases must exercise raw forms, style/value
  normalization, defaults, nested translations, names/lore and both stack formats.
  ExUnit covers positive/negative transactions, old journals/persistence and TCP
  slot corrections. Full format/tests/release/oracle/audit gates must pass.

Actual Minecraft 26.3 via CUA: seed via the ordinary leased/connection path a named
stone with colored/bold Unicode text and two styled lore lines in the currently
hovered inventory slot. Actual E must show the tooltip/name/lore. Exercise actual
close/return and equivalent-name merging, then a meaningful style/content
difference that stays separate. Actual Q/Ctrl+Q drop must render the supported
stack; reconnect/restart must retain its raw name/lore and stable entity UUID.
An unsupported selector/event fixture must restore the prior slot and show the
correction message. Clean only pinned fixture entities and restore original empty
inventory/pose while retaining advanced counters/receipts. Fixture setup is not
evidence of mouse pickup, and earlier mouse gates remain explicit.

## References and design

Pinned Mojang 26.3 SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`ComponentSerialization`, `Style.Serializer`, `TextColor`, `FontDescription`,
`PlainTextContents`, `TranslatableContents`, `KeybindContents`, `ItemLore`,
`DataComponents`, and `ItemStack` codecs. Private bytecode in ignored
`research/disassembly/VMC004b2b-*` and existing VMC004 dumps informs schema/equality;
Mojang-generated raw fixtures define the executable compatibility checks.

SteelMC `f6fb4e49778c` `steel-registry/src/data_components/components/item_lore.rs`
separates original lines from the dark-purple/italic display projection and enforces
256 lines. Pumpkin `b0c48b2d7688` `crates/pumpkin-data/src/data_component_impl/basic.rs`
defines names/lore separately. Paper `a2d844f71e27` network component sanitization
is a deliberate policy change, not a vanilla parsing specification. Original
Elixir keeps declared values and comparison keys separate, as in VMC-004b2a.

## Verification

October 14, 2026 automated checkpoint: format check, all **236 ExUnit tests**
(seed 848454), production release and full pinned oracle pass. The independent
text harness checks 121 raw native cases, **5,050 equality pairs**, and actual
Mojang decoding of **100 Elixir name/lore stacks in both formats**. Native lore
counts 0/1/256 pass; 257 rejects. Prototype extraction now includes item_name/lore
and all **15,113** stack identity pairs pass. Public-tree audit passes 155 paths.
Private logs: `.local/vmc004b2b-{tests,release,oracle}.log`.

Ten new ExUnit tests cover semantic names/lore in authoritative close, type/style
distinctions, prototype pruning, UTF, aggregate budgets, unsupported branches,
TCP corrections and exact snapshot/item/outbox bytes and digests. Existing
unsupported-component controls now use enchantments or native selector text
because literal names became implemented. Prototype semantic keys are prepared
once at compile time; no new process or global coordinator is introduced.

Actual Minecraft 26.3 through CUA, October 14, 06:12–06:27 local:

- Release restart 06:12:46/join 06:13:12. Ordinary-menu UI fixture retained creative
  owner permission. Actual E displayed gold/bold `ValiMC é 🚀`, aqua non-italic
  `Elixir / OTP — lore é`, and translated purple `Stone` in slot 13.
- Actual E close on equivalent color-alias names/lore merged selected 63 plus
  carried 10 into selected 64/storage 9. Both changed bold and changed text
  controls stayed 63/storage 10. Live state and ordinary checkpoints retained
  their exact declared components; no source intent or world item was created.
- Actual Q reduced seven to six (sequence 23), held Ctrl+Q 250 ms emptied six
  (sequence 24). Exact 1/6 records retained names/lore. F5/backward movement
  rendered the two overlapping stationary item models. Rejoin 06:17:00 and full
  restart 06:17:27/rejoin 06:17:49 retained both exact records/UUIDs with nil outbox.
  Names/lore in ordinary slot 13 also survived full restart 06:19:34/rejoin
  06:19:45 and displayed the same tooltip without reseeding.
- Normal creative packet handler fixtures rejected selector and click-event names:
  the client showed `slot restored` and E retained the prior tooltip/stack.
  Normal accepted item_name root-sequence/keybind text displayed `OTP Space`;
  fallback translation arguments displayed `Concurrency: Elixir / OTP`.
- Final independent cases found legacy dispatch must try complete content codecs:
  malformed translation fields fall through to valid keybind without an explicit
  type. The original parser was corrected, all automated gates rerun, and fixed
  release 06:24:49/join 06:25:00 displayed `Space` for that exact raw legacy case.
  Explicit `type: translatable` kept the error and showed the expected malformed
  creative-item disconnect; no invalid replacement was accepted.
- Only the two pinned UUIDs were removed. Normal writer cleanup restored original
  empty inventory/pose, keeping sequence 24 and region receipts 24/20. Rejoins
  06:21:55 and 06:26 after the final control confirmed empty creative inventory.
  Private client log has no ERROR, decoder/encoder or duplicate-entity entries.

Keyboard/tooltip scenarios pass. Normal packet fixtures are explicit setup or
adversarial inputs, not actual mouse manipulation. Rechecked coordinate click
while empty returned `noWindowsAvailable`; earlier sustained/cursor mouse gates
remain pending. Arrays count against the aggregate text-node budget as well as
bytes. Declared NBT values use the existing sorted NBT writer; semantic comparison
does not rewrite them or historical receipts. Full component/text support,
recipes, item physics and vanilla survival remain incomplete.
