# VMC-004b2c — Enchantment and stored-enchantment stack data

Status: Done
Note: Done — actual-client validated, local commit. Updated: October 14, 2026. Depends on VMC-004b2a effective identity, VMC-004b2b text and the pinned core-pack registry negotiation. This slice implements data preservation; applying enchantment effects to combat/mining/loot remains part of survival gameplay.

## Scope and acceptance

Before: enchantment additions are unsupported. After: `minecraft:enchantments`
and `minecraft:stored_enchantments` accept bounded holder-ID/level maps, round-trip
both stack formats and preserve identity through menus, player/region files and
durable drops. Use IDs from the actual negotiated 26.3 enchantment registry,
with pure compiled lookup tables. No process or global gameplay coordinator.

- Establish constructor/codec/equality/default behavior with Mojang's actual
  `ItemEnchantments`, `Enchantment.STREAM_CODEC`, holder registry codec and map
  codec. Network levels 0–255 differ from the saved-data codec's 1–255; probe
  duplicate entries, overwritten invalid levels, zero-level presence, ordering,
  invalid IDs/levels, empty/default maps and all registry entries.
- Bound inbound map work before allocation/iteration (1,024 raw entries; ordinary
  unique maps cannot exceed the pinned registry). Preserve last-value semantics
  within that bound. Reject invalid state without publishing a partial map; retain
  stack/inventory byte limits and exact historical transfer receipt encoding.
- Extend prototype extraction/default identity and independent oracle coverage.
  Meaningful ExUnit/TCP tests cover corrections/failure isolation, conservation,
  ordering/default distinctions, malformed data and exact snapshot/item/outbox
  recovery. Run format, full tests, release, full Mojang oracle and public audit.

Actual Minecraft 26.3 via CUA: seed through the normal leased/connection path an
enchanted tool and stored-enchantment book in the hovered slot. Actual E must show
correct translated enchantment names/levels and item glint. Exercise equivalent
map-order/default merges and differing level/type separation through actual close;
actual Q/Ctrl+Q must retain enchantments in committed items. Reconnect/full restart
must recover exact stacks/UUIDs and tooltips without reseeding. Invalid levels/IDs
must reject only the affected session and never replace accepted state. Restore
original empty inventory/pose and remove only pinned fixture UUIDs, preserving
advanced source counters and receipts. This is not a mouse-gesture or enchantment
gameplay-effect test.

## References and design

Pinned Mojang 26.3 SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`ItemEnchantments` constructor/equality/stream and saved-data codecs,
`Enchantment.STREAM_CODEC`, `ByteBufCodecs.map`/`holderRegistry`, `DataComponents`,
`ItemStack`, and actual registry loader. Private bytecode remains in ignored
`research/disassembly/VMC004b2c-*`.

SteelMC `f6fb4e49778c`, `steel-registry/src/data_components/components/enchantments.rs`,
separates identifier maps from network IDs; its reader rejects every invalid
intermediate level, which needs independent Mojang duplicate checks. Pumpkin
`b0c48b2d7688`, `crates/pumpkin-data/src/data_component_impl/combat.rs`, separates
enchantment data/serialization; its NBT format compatibility is not network proof.
Paper `a2d844f71e27`, `ItemEnchantments.java.patch`, deliberately sorts holders by
registered name. ValiMC uses deterministic encoding for its map values while
following vanilla equality rather than Paper's iteration policy.

## Verification

October 14 automated checkpoint: format, all **245 ExUnit tests** (seed 591291),
production release and full Mojang oracle pass. The enchantment harness checks
**193** native decode cases, **16,471** actual equality pairs across all **43**
holder IDs and native decoding of **181** Elixir maps/stacks in both formats.
Prototype extraction adds empty active/stored defaults; all **16,772** stack
identity pairs pass. The full TCP oracle accepts native Unbreaking III and stored
Sharpness V through ordinary creative packets. Public-tree audit passes 161 paths.
Private logs are `.local/vmc004b2c-{tests,release,oracle}.log`.

Nine new tests cover holder IDs, network levels/duplicates/budgets, both stack
formats, defaults/zero-level/type distinctions, authoritative conservation,
snapshot/outbox/region receipts and TCP failure isolation. The first full test
run exposed an existing teardown race: cursor cleanup can outlive its socket and
recreate a deleted temporary world. Teardown now terminates the fixture's closing
writer/work before its region/world removal; rerunning the failing seed passes.
Runtime lifecycle logic is unchanged.

Native network decoding retains level zero and validates only the final map,
including overwritten -1/256 values. Ordering is canonicalized for newly
supported maps; previously accepted stack/journal bytes remain unchanged. One
1,025-entry native case intentionally exceeds the local raw-work guard and must
reject; all ordinary unique core-pack maps fit. Saved JSON/NBT uses a distinct
1–255 codec, which is not the current custom network-based snapshot format.

Actual Minecraft 26.3 via CUA, October 14, 06:43–07:06 local:

- Release restart 06:43:50 and actual reconnect. Normal creative packet fixtures
  in slot 13 displayed Diamond Pickaxe with Efficiency V/Fortune II/Unbreaking III
  and glint; the stored book displayed red Curse of Binding, Sharpness V,
  Unbreaking III and glint. Client tooltip attributes are rendering; server
  enchantment gameplay effects remain a separate gate. Ordinary-menu UI fixtures
  retained creative owner permission.
- Actual E close merged reversed wire-order equal maps from 63+10 into selected
  64/storage 9. Empty/default maps also merged 64+9. Differing levels and
  active-versus-stored component types both remained 63/storage 10. Live state
  and ordinary checkpoints matched every exact expected map; no journal/drop
  was created by these close cases.
- Actual Q reduced seven to six and held Ctrl+Q 250 ms emptied six, committing
  sequences 25/26 and exact glint stone records 1/6. F5/backward movement rendered
  the overlapping glint models. Actual reconnect and full restart 06:52:08
  retained both UUIDs/maps and the exact book/tool inventory without reseeding.
  Actual E after restart displayed the same stored-book tooltip.
- Adversarial normal-owner packet fixtures with level 256 and unknown holder 43
  each displayed the expected invalid-creative-item disconnect. The listener
  remained alive, saved book/tool inventory and sequence 26/outbox nil stayed
  unchanged, and actual rejoin recovered the exact records. Independent TCP
  tests additionally keep a separate connected peer responsive across failures.
- A normal creative fixture moved the stored book from slot 13 to the selected
  hand. Actual Q committed it once (sequence 27) into region {0,-1}; the book
  rendered with glint alongside the two stone items. Full restart 07:04:23 and
  actual rejoin retained all three exact UUIDs/maps and the remaining tool.
- Removed only those three pinned UUIDs. Normal writer cleanup restored original
  empty inventory/pose, retaining source sequence 27 and region receipts 26/27.
  Actual rejoin/E confirmed empty creative inventory. The 151-byte source file
  has nil outbox; client logs contain no ERROR/decoder/encoder/duplicate entries.

Keyboard/tooltip and adversarial packet scenarios pass. Packet fixtures are
explicit setup/negative controls, not proof of mouse manipulation. Earlier mouse
clone/fill/cursor gates remain pending. This completes the data slice only; full
components, data packs, enchanting/anvils and enchantment gameplay remain open.
