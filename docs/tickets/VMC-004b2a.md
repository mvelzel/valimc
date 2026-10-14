# VMC-004b2a — Effective component identity for supported stacks

Status: Done — effective supported-component identity validated, local.
Updated: October 14, 2026.
Splits VMC-004b2; text/name/lore/enchantments remain subsequent slices.

## Scope and acceptance

Before: identical item types with redundant default additions or absent-component
removals fail to merge, and conservation compares their literal patch bytes.
After: inventory pickup/merge/shift/drag/collect/connected return and source
conservation compare the effective supported component identity, excluding count.
Different effective patches/removals, component presence and item types remain
distinct. Removal of a present default is significant even when its accessor's
fallback value happens to equal that default (for example absent repair cost).

- Extract per-item prototype component presence and supported component values
  from the pinned 26.3 runtime, with version/protocol/data-version provenance.
  Regeneration must reproduce public facts; use immutable indexed facts, pure
  bounded comparisons and existing inventory owners, without a new coordinator.
- Canonicalize comparison keys only. Preserve stored/encoded patch bytes and
  exact-intent transfer receipt hashing, including existing journals. No silent
  change to replay digests or broad permission bypass. Accepted stack/count/
  component/aggregate-size restrictions remain enforced before comparison.
- Validate equal defaults, absent removals (including unsupported component types),
  present-default removals, changed caps/models/damage/glint/custom NBT, inventory
  algorithms and conservation when merge representations differ. Counts, items
  and retained patches must agree with Mojang. Include meaningful persistence/
  old-receipt replay cases and malformed-input rejection.
- Compare against Mojang's actual ItemStack/PatchedDataComponentMap/menu methods,
  and generate raw redundant patches with its component codecs (normal `set`
  already normalizes). Full format/tests/release/oracle/audit gates must pass.

Actual Minecraft 26.3 via CUA: supply ordinary inventory UI using the documented
development game-mode fixture, selected default stone 63 and a cursor stone 10
whose raw patch redundantly sets its default stack limit/rarity/model/repair cost
and removes an absent component. Actual E/Escape close must merge to selected 64
and put the remaining 9 in the first empty storage slot. A changed maximum stack
size, removed present default or glint must remain separate instead (selected 63,
new stack 10). Reopen, reconnect and release restart must retain exact contents;
repeat close must create no items. Fixture contents are setup, not evidence of
mouse pickup. Restore original inventory/pose while retaining counters/receipts.

## Reference conclusions and design

Pinned server SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`ItemStack.isSameItemSameComponents/matches`, `PatchedDataComponentMap.fromPatch/
isPatchSanitized/set/remove/equals`, `DataComponentMap`, item prototypes and
`Inventory.placeItemBackInInventory`. Private bytecode under ignored
`research/disassembly/VMC004b2a-*` confirms redundant additions and removals of
absent prototype entries are normalized before map comparison. Component absence
is distinct from explicit values. Counts are excluded by same-item comparison.

SteelMC `f6fb4e49778c` `steel-registry/src/item_stack.rs` effective component
comparison and Pumpkin `b0c48b2d7688` `crates/pumpkin-data/src/item_stack/mod.rs`
patch/prototype lookup are architectural references, not proof of 26.3 semantics.
Paper `a2d844f71e27` component-patch patches include deliberate network sanitization;
those plugin-specific changes are not copied into vanilla identity. Original
Elixir comparisons use pinned immutable facts and bounded supported codecs.

## Verification

October 14: format and all 226 tests pass (seed 992575), production release and
full Mojang behavior/codec/TCP oracle pass (05:24:02). Ten added regressions cover
default additions/count-independent identity/raw preservation, significant presence
and changed values, all 1,658 extracted prototypes, NBT equality, scalar float
signed zero and malformed inputs, pickup/shift/drag/collect, connected return/source
conservation across different raw representations, serialized exact receipt retries,
and actual TCP positive/three negative close scenarios with forged observations.

`ItemMetadata` extracts all prototype component names and the existing supported
component encodings into `priv/protocol/item_defaults.json` with pinned provenance.
Eight of the thirteen supported types appear in item prototypes. The full oracle
regenerates and compares both item facts and defaults, rather than trusting a
committed verifier manifest. The immutable index remains inside ItemTypes; pure
identity keys preserve existing limits and never mutate encoding or journal hashes.

The original `StackIdentityOracle` builds raw additions/removals with Mojang's
component codecs and calls its actual optional stack decoder/equality method.
Elixir matches all 11,797 pairs in ordinary and delimited input forms, including
every supported prototype value, absent/present removals and explicit false glint
across all items. Focused menu-return calls confirm 63+10→64+9 for redundant defaults
and unchanged 63+10 for different caps, absent repair cost and glint.

The oracle exposed Mojang's FloatTag/DoubleTag `valueOf` zero cache: NBT -0 and +0
decode to the same tag, while the ordinary float component preserves signed zero.
NBT comparison keys collapse cached zero, NaN payloads and empty-list element types;
original NBT bytes remain unchanged in codecs/files/receipts. Typed numbers, list
order, compound values, different effective presence and patches remain distinct.
Private disassembly/fixtures stay ignored; no Minecraft implementation is published.

Actual Minecraft Java 26.3 CUA validation, October 14: release started 05:27:52,
localhost joined 05:28:02. A live-owner/ordinary-writer fixture supplied selected
default stone 63, offhand eggs 3 and cursor stone 10 with redundant default stack
limit/rarity/repair cost/model and absent custom-name/unbreakable removals. The
documented game-mode event supplied ordinary inventory UI; server authority stayed
creative. Actual E displayed 63/cursor 10; actual Escape/E returned selected 64,
first empty storage 9 and empty cursor. Owner/file checks retained exact raw
patches, counter 21/no outbox and no world items. Actual disconnect/rejoin
05:30:49 and full release restart 05:31:31/rejoin 05:31:59 retained those contents;
ordinary UI again showed 64/9/empty cursor.

Three separately seeded negative fixtures changed the cursor's stack limit to 32,
removed its present repair-cost component, or added true glint. In each case actual
Escape/E showed selected 63 and a separate returned 10, with empty cursor and
unchanged offhand 3. The glint-bearing stack visibly remained separate. Exact
owner/file assertions passed for all three; fixture reseeding is administrative
setup, not an economy claim across scenarios. Another fixture supplied different
NaN payloads/empty-list element types in main/cursor custom NBT. Actual Escape/E
merged 63+10 to 64+9; exact distinct raw NBT remained in the saved resulting stacks.
Repeated empty close retained the same contents and no world effect.

A full-storage fixture additionally forced the changed source-conservation path:
selected default stone 63 plus raw default-equivalent cursor 10 returned selected
64 and precisely one stationary overflow stack of 9. The source advanced 21→22,
cleared its outbox and matched the destination's exact digest/receipt. Actual
backward movement rendered the item; repeat close created nothing. Full release
restart 05:39:47/rejoin 05:40:19 retained the exact inventory and pinned UUID/raw
stack/receipt. Only that fixture UUID was durably removed; actual world view cleared.
Original empty inventory/pose were restored through the ordinary leased writer,
retaining counter 22 and receipts `{-1,-1}:22`, `{0,-1}:20`. Final actual rejoin
05:42:18/E showed empty creative inventory. The source file is 151 bytes, with no
outbox/recovery job. Private `.local/client-tests/VMC-004b2a/latest.log` has zero
ERROR/codec/unknown-packet/duplicate-entity entries in the validation window.

Raw fixtures establish starting components; the closes/reopens/disconnects/rejoins
are actual client actions. Mouse pickup/drag/clone gates remain on earlier tickets;
full structured components, unrestricted inventories, survival and item physics
remain incomplete. Exact diff/public-tree audit were reviewed before amending the
unpublished checkpoint. Subject:
`VMC-004b2a: compare effective component identity without rewriting journals`.
Branch `main`; earlier ancestor mouse gates remain pending before push.
