# VMC-019b3b — Connected keyboard drops through the durable transfer path

Status: Done
Note: Done — keyboard controls and transfer gates validated. Updated: October 14, 2026. Depends on VMC-019b3a. Stationary preview scope; full item lifecycle remains.

## Scope and acceptance

Before: in-world Q/Ctrl+Q player-action packets do not transfer inventory into
the world. After: one item or the entire selected hotbar stack moves into a
durable stationary preview entity, preserving supported components and counts.
Empty hands do nothing. This slice does not claim vanilla item motion/pickups.

- Plan from current connection-owned inventory, never client predicted counts.
  Pin one entity UUID, position and destination before source prepare. Persist
  the reduced inventory/outbox before delivering; clear only with receipt proof.
  Reuse the bounded delivery/retry/deadline path and reconnect recovery.
- Allow one transfer per session; reject/correct additional inventory mutations
  during prepare, delivery and source clear. Parse malformed payloads normally.
  Gate selection, hand swap, creative writes, menu clicks/close and held-item
  placement; keep movement, chat, keepalive and unrelated sessions responsive.
  Skip periodic checkpoints while a transfer is active. No mutation queue.
- Prepare failures with no commit restore the old inventory. Unknown commits,
  disconnects, deadlines and worker/storage loss preserve the actual journal.
  Never roll back counts over a possible commit. Completion retains the latest
  accepted pose and monotonically advances the current menu state ID.
- Tests cover single/all/empty/component identity, durable counts and repeated
  drops, blocked mutation/periodic-save admission, responsive movement, source
  and destination stalls, disconnect/deadline/reconnect, stale replies, storage
  disabled and failed writes. Format, full tests, release, Mojang oracle, audit
  and exact diff review must pass.

Actual Minecraft Java 26.3 via CUA: seed a supported stone-7 hotbar fixture while
offline; join, press Q and inspect HUD 6 plus one rendered entity after backing
away. Press Ctrl+Q and inspect an empty slot plus the second entity. Empty Q must
create nothing. Reconnect/full restart must preserve total world count 7, no
additional UUIDs and no outbox. Exercise a second selected slot and hand swap
after completion. Remove only fixture entities and restore fixture inventory
through current leased writers, retaining the advanced source sequence/receipts.
Inspect client/server logs. A stalled-transfer negative case also needs actual
client selection/swap correction and recovery without duplication.

## References and decisions

Pinned Mojang 26.3 SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`ServerGamePacketListenerImpl.handlePlayerAction`, `ServerPlayer.drop(boolean)`,
`Inventory.removeFromSelected(boolean)`, and `LivingEntity.drop` /
`createItemStackToDrop`. Private `javap -c -p` dumps live under ignored
`research/disassembly/`. Q removes one from the selected stack; Ctrl+Q removes
its count; empty stacks remain empty. Drop actions bypass block acknowledgments.
Vanilla spawns at eye Y minus float32 0.3, adds facing/random velocity, a 40-tick
pickup delay and thrower tracking. This preview uses the standing-player origin;
velocity/gravity, crouched eye height, pickup/merge/age/thrower/stats remain later
VMC-015/016/035/052 slices. Stationary items are an explicit compatibility gap.

SteelMC `f6fb4e49778c`, `steel-core/src/player/player_inventory/player_handlers.rs`
`drop_from_selected`/`drop_item`, and Pumpkin `b0c48b2d7688`,
`crates/pumpkin-core/src/entity/player.rs` `drop_held_item`/`drop_item`, support
selected-stack planning and separate world creation; Pumpkin marks merging TODO.
They do not prove durable cross-owner behavior. Original Elixir orchestration
uses the socket owner, leased writer, bounded I/O workers and region receipt.
No reference implementation source is copied into the public tree.

Menu throw/outside-click, creative slot -1, close overflow and disconnect cleanup
remain separate tickets; this slice adds actual in-world keyboard drop controls.
Receipt capacity and directory/power-loss qualification remain existing limits.

## Verification

October 14: format and all 170 tests pass (seed 744400), production release
build and full Mojang oracle pass (02:26:11). Seven new tests cover pure count/
identity planning and connected single/all/empty/reload; source/destination
stalls and all mutation gates; live movement/chat and stale reply fencing;
disconnect/deadline recovery; periodic-save admission; failed and disabled source
storage. Mojang's actual selected-stack method verifies both permission modes;
its TCP codecs decode Q/Ctrl+Q, reduced inventory and exact patched item metadata.
Actual Minecraft Java 26.3 via CUA, October 14:

- Release started 02:28:20; actual localhost join 02:28:34 displayed patched
  stone 7, egg 2 and offhand planks 4. The offline fixture was checkpointed through
  its leased writer, retaining source sequence 2. No world item was reseeded.
- Actual Q reduced stone 7 to HUD 6, rendered one glint model after backing away,
  and committed source sequence 3/world count 1. An instant Control+Q reduced
  HUD to 5, producing another single item (sequence 4). Holding Control+Q for
  250 ms emptied the slot and created the exact patched stack 5 (sequence 5).
  The instantaneous chord is not evidence of the whole-stack action: the vanilla
  client consumes the click in its tick and queries currently held Control keys.
  Private client bytecode inspection of `Minecraft.hasControlDown` and the key
  binding loop explains this timing. The client jar SHA-1
  `e877b6a07acd633fb3bb475002175cec036e7b87` matches its official Launcher metadata.
- Empty-hand Q created nothing. Actual hotbar key 2 then Q reduced egg 2 to 1,
  rendered an egg and advanced sequence 6. An initial fixed-time writer-stall
  fixture did not capture pending input and did not qualify the negative gate;
  that ordinary Q completed sequence 7, then selection/swap worked normally.
- Repeated the stall with its hold starting when the actual Q arrived. At source
  prepare, actual key 4/F were corrected to selected index 2, planks 4 and empty
  offhand. Movement remained live. A private owner capture confirms the pending
  prepare and unchanged slots/selection. After bounded auto-resume, one planks
  item committed (sequence 8), inventory retained 3, and a subsequent actual F
  moved those 3 into offhand. No duplicate entity or queued second drop appeared.
- Walking crossed region X=0. The six stable item UUIDs span two regions and
  contain stone counts 1/1/5, eggs 1/1 and planks 1; remaining offhand planks 3
  conserves all 13 initial fixture items. Owner/file checks verify exact patches,
  positions, source sequence 8/no outbox and no remaining delivery task.
- Actual reconnect 02:33:55 and full restart 02:34:20/rejoin 02:34:49 retained
  HUD offhand 3 and rendered items. Exact UUID/position/stack comparisons against
  the pre-restart records pass; no reseeding occurred. The numerical counts come
  from authoritative owner/file checks; screenshots establish HUD/rendering.
- Removed only the six pinned fixture UUIDs durably; actual rendering cleared.
  Actual Disconnect released the lease, then ordinary checkpoint/close restored
  original empty inventory/pose while retaining source sequence 8 and receipts.
  Final actual join 02:36:04 showed empty hands/hotbar and no item; the player file
  is 151 bytes. Existing block edits remain. No source-counter backup was restored.
- Private `.local/client-tests/VMC-019b3b/latest.log` has zero Network Protocol
  Error, DecoderException, EncoderException, Duplicate entity or ERROR entries.
  Initial observation needed app rebinding/exposed Raise. Audit/diff review pass.

These controls deliberately retain stationary entities: gravity/facing velocity,
pickup/merging/despawn/thrower/stats, crouched origin, menu/creative/disconnect
drop paths and complete vanilla compatibility remain unimplemented. The larger
VMC-019b3/VMC-035 milestones and full-server goal remain incomplete.

Subject:
`VMC-019b3b: connect keyboard drops to durable inventory transfers`.
Branch: `main`; earlier ancestor mouse-validation gates remain pending.
