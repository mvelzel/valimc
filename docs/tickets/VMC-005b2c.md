# VMC-005b2c — Authoritative creative clone and fill

Status: Awaiting client-generated clone/fill validation. Updated: October 13, 2026.
Depends on VMC-005b1/005b2a. Automated checkpoint; keep unpushed until that gate
passes or the user explicitly requests publication.

## Scope and acceptance

Implement `CLONE` and quick-craft type 2 using server-owned infinite-materials
permission. These actions intentionally create items in creative mode.

- Permission defaults to false in the pure inventory constructor. The creative
  preview's connection owner explicitly grants it, matching advertised abilities.
  Incoming click predictions/buttons cannot grant permission. Vanilla samples
  permission at start; an accepted fill stays authorized until end or cancellation.
  A later permission change prevents new fills/clones. Menu close cancels the
  existing gesture through the owner's correction path.
- Clone requires permission, an empty cursor and an owned source stack. Copy
  exactly its item/patch/removals at the effective maximum count; leave source
  unchanged. Empty sources/nonempty cursors/noncreative attempts are no-ops.
- Type 2 starts only with permission, deduplicates at most 41 supported targets,
  fills compatible eligible slots to item/slot caps, and uses vanilla's cursor
  accounting. A one-target type-2 gesture is a no-op; no-target/full-target cases
  retain the original cursor. Existing phase/interruption rules remain intact.
- Aggregate byte limits apply atomically to created items. Reject oversized
  duplication without partial writes; preserve components and corrections.
- Test permissions, start-time authorization, caps,
  one/many/full/incompatible/restricted targets, source preservation, forged
  observations, peer isolation and budget rejection.
  Extend the Mojang behavior harness and official-codec TCP scenarios.

Actual-client scenario: ordinary-menu fixture with server creative permission;
normal-handler clone/fill fixtures, inspect full stack/cursor and place accepted
results via CUA; revoke permission and attempt clone/fill, inspect unchanged
slots. Also attempt actual middle-click creative inventory input and identify its
packet path. Keep actual multi-slot gesture validation pending if CUA cannot
produce it; fixture replication does not prove the client-generated gesture.

## References and design

Pinned vanilla 26.3 jar `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`AbstractContainerMenu.doClick/isValidQuickcraftType`, `Slot.safeClone`,
`Player.hasInfiniteMaterials` (authoritative abilities.instabuild). Private client
inspection: `CreativeModeInventoryScreen.slotClicked`; its player inventory tab
uses creative-slot writes rather than ordinary container-click packets.

SteelMC `f6fb4e49778c`, `steel-core/src/inventory/menu/behavior.rs::do_clone/
do_quick_craft/finish_quick_craft`, corroborates permission checks and the
single-target fill no-op. Vanilla defines behavior; original Elixir code stores
a boolean inside the existing connection-owned inventory. No new processes,
locks or shared global gameplay state are introduced. Permissions are ephemeral,
derived from future authoritative game-mode rules, and must not be restored from
client observations or inventory persistence. General game-mode/creative-write
permissions remain VMC-016; current connections are all explicitly creative.

## Verification

October 13, 2026, pinned Elixir 1.20.4 / OTP 29.1.1:

- All 77 ExUnit tests pass (seed 924276), including clone/fill caps, components,
  invalid targets, sampled authorization, cancellation and atomic byte rejection.
  TCP regression covers owned egg cloning/fill and denied attempts after a
  trusted test-owner permission change; forged observations cannot supply items.
- Production release builds successfully. The full Mojang oracle passes: actual
  menu behavior, nine component fixtures in both formats, Unicode text, and TCP
  clone/fill with forged observations alongside existing protocol scenarios.
  The behavior harness sets the actual `Player.abilities.instabuild` field and
  verifies that permission changed after fill start does not cancel it. Its
  ordinary slots do not model recipes, equipment locks or player lifecycle.
- Rebuilt release restarted at localhost:25565 using the existing temporary test
  world. Actual Minecraft 26.3 was controlled through
  `local.valimc.minecraft-client`, with the isolated SDL event-position adapter.
  A normal creative-input fixture seeded stone 7 with glint/custom NBT; a client
  UI fixture selected the ordinary inventory while server gameplay stayed creative.
  Normal-handler CLONE produced cursor 64 and retained source 7; a CUA click
  placed the 64 in hotbar 37. Another clone/fill fixture produced main slots 9
  and 10 at 64 and an empty cursor. Screenshots and owner reads agree, including
  exact patches. These are graphical replication checks of injected transactions.
- A trusted local test-owner change revoked infinite materials. CLONE then left
  slots and empty cursor unchanged. Actual CUA right pickup split source 7 into
  slot 3/cursor 4; a denied fill fixture left targets 11/12 empty and cursor 4.
  CUA placement put those 4 in offhand. Permission and advertised client abilities
  were restored to the creative preview afterward.
- Actual creative inventory-tab CUA middle-click copied source 3 to a client
  cursor of 64, then CUA placement wrote hotbar 38 at 64 with patches preserved.
  The server cursor stayed empty until placement, consistent with pinned client
  bytecode: this tab computes clicks locally and sends creative-slot writes.
  It does not exercise the ordinary server CLONE packet path. A generic creative
  container and sustained type-2 drag scenario remain pending; VMC-005b2a's
  sustained input limitation also remains. Do not mark this ticket Done.
- Client log copy is private under `.local/client-tests/VMC-005b2c/`; no Network
  Protocol Error, DecoderException, EncoderException or ERROR entries were found.
  Public-tree audit and exact diff review are required at the checkpoint.

No new performance claim. Cursor return/drop, persistence, recipes, specialized
item interactions and full game-mode transitions remain separate backlog slices.
Checkpoint subject: `VMC-005b2c: gate creative cloning and fill by owner permission`.
