# VMC-077o — The command layer: registration, source, targets, text and box edits

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) (the audit and plan), [VMC-077a](VMC-077a.md)
(commands as jobs). Works beside VMC-077f/g (storage, `RegionData`) and
VMC-077k (living rules).

Before: `commands.ex` compiled a 396-entry table from full executable paths
to 159 handler functions, about 60 of them mode trampolines, into the tree,
so the command module depended at compile time on every handler. The
`Source` carried the connection state and used `self()` as identity, the
dimension came from the process dictionary, and RCON collected its reply
there too. Text had two codecs (`Command.ComponentCodec` and
`Protocol.TextComponent`), item components two decoders, and `NBT` item
lists five copies; Java number formatting, UUID text, the single/multiple
feedback and the bounds checks were repeated with drift. Gameplay depended
on `Command.*` for text, game rules and post effects. `/fill`, `/clone` and
`/place` wrote region by region and batch by batch, so a refused later batch
kept the earlier ones: `/clone … move` could clear the source without
writing the destination, and `/fill` applied partially while reporting
failure. Unloaded positions were loaded or generated rather than refused.

Scope: the command layer of VMC-077 phase 5. Not here: `execute` (only its
modifier slot), command targets other than players (M3's entity store),
one durable frame across owners (VMC-077f).

## What changed

- **Registration.** `Valimc.Commands.registry/0` maps each of the 54
  top-level commands (aliases included) to one `{module, fun}`, with
  optional `except:` and `only:` paths, `own: true` for ValiMC's own
  commands and `suggest: true` for a command whose `ask_server` nodes it
  answers (`suggest/3`). The tree is built from `tree.json` at start
  (`Commands.init!/0`, 11 ms) and kept in `:persistent_term`; it keeps
  redirect nodes and has a `modifier` slot for `execute`. The dispatcher
  passes the parsed literals after the command name to the handler, which
  dispatches on them. `commands.ex` is 245 lines and has no compile
  dependency on handler modules. The commands packet is byte-identical at
  permission levels 0 to 4 (`graph_payload/1`); the `Commands` beam fell
  from 302 KB to 29 KB and `Command.Tree` from 466 KB to 20 KB.
- **Source and sinks.** `Command.Source` is a plain value: level, the
  player it runs as (a projection with its connection's `pid`), name,
  dimension, position, rotation, anchor, sink, `silent` and kind. Sinks:
  `{:player, pid}`, `:log` (console) and `{:collect, pid, ref}` (RCON,
  collected after the command by `Source.collect/1`). No process
  dictionary, no `self()` identity and no handler touches a socket.
  `Source.owner/2` addresses a region as `{dimension, key}` and never
  starts one. Feedback renders through the sink in the order the command
  sends it; `Feedback.targets/5` is the one single/multiple tracker.
- **Targets.** `Command.Targets` resolves selectors over the published
  player projections (an ETS select of the fields commands need, not whole
  player maps) and, for a distance of at most 512 blocks, the spatial index.
  `world_limited` selectors stay in the source's dimension, `alive` (implied
  by `@e` and `@n`) reads the player's health (`living` or the older
  `health` row), and `/particle` viewers are the source's level only.
- **Text.** `Valimc.Text` (builders, `join/2` as
  `ComponentUtils.formatList`), `Text.Render` (English strings) and
  `Text.Codec` (the command `component` decoder and the item text
  components, one colour table) replace `Command.Text`, `Command.Render`,
  `Command.ComponentCodec` and `Protocol.TextComponent`; item text identity
  bytes are unchanged. `Text.Number` holds Java's `%.Nf` (shortest digits
  rounded half up) and `Float`/`Double.toString`; `Valimc.UUID` the text
  form. `NBT.items/1` replaces five copies. `Command.ItemComponents` is gone:
  `/give` and item arguments decode components with `ItemData`'s decoders,
  so every component `ItemData` knows is accepted. Game rules moved to
  `Valimc.GameRules` and post-effect state to `Player.PostEffects`, so
  gameplay no longer depends on the command layer.
- **Box edits.** `/setblock`, `/fill`, `/clone` and `/place` change blocks
  through `World.BoxEdit`. `read/3` reads a box with one `Region.read_box`
  per region (a Rust `ColumnStore::read_box`, at most 32,768 cells per call)
  and never generates. `commit/2` asks every owner to prepare its part: it
  compares the expected states, checks it can commit the edits and block
  entity records, and takes `:box_edit` locks in `Txn.Permits` over those
  cells, which block proposals and raw writes refuse. When all prepared they
  commit; otherwise every prepared part aborts and nothing changes. A busy
  owner answers `:retry`. A region not running or a chunk not generated
  fails with `argument.pos.unloaded`. `/clone` plans from the read and
  commits source and destination as one edit.

## Acceptance

- Commands packet identical at levels 0–4; every registered path resolves to
  a handler and every tree command runs (`Commands.init!/0` checks both).
- `/fill` over two regions where one owner refuses (a cell locked by
  another edit) changes neither, and the locked cell refuses other writes
  until that edit ends; `/clone … move` into a refused destination keeps its
  source; `read_box` agrees with single-cell reads; unloaded positions fail
  with `argument.pos.unloaded` without starting their region
  (`test/command_box_edit_test.exs`). Cells that changed after the read fail
  the prepare (compare-and-set), so nothing is overwritten unseen.
- `@e` and `@n` select only living players and `@a` the dead too; a
  world-limited selector stays in the source's dimension
  (`test/command_targets_test.exs`).
- RCON replies carry the collected text (`test/world_settings_test.exs`);
  give, kill and teleport count only targets that answered.
- Java number formatting: `%.6f` of 1.0000005 is 1.000001
  (`test/text_number_test.exs`).

Audit items fixed (`.local/code-audit/commands.md`): B1–B6, C2–C4, E1–E3,
E9–E13, E17 and E18.

Reference: Brigadier `CommandDispatcher`, `CommandNode` (redirect,
modifier), `CommandSourceStack` (`sendSuccess`, `sendFailure`,
`broadcastToAdmins`, `withSuppressedOutput`), `EntitySelector`
(`findPlayers`, `isWorldLimited`, `Entity::isAlive`),
`ServerLevel.sendParticles`, `ComponentUtils.formatList`, `FillCommand`,
`CloneCommand`, `SetBlockCommand`, `PlaceCommand`,
`BlockPosArgument.getLoadedBlockPos` (`argument.pos.unloaded`),
`RconConsoleSource`, `String.format("%f")`, `Float.toString` and
`Double.toString`.

Checks (October 22, 2026): the touched test files by name while working
(stages `commands`, `world_border`, `text`, `stack_identity`, `place`,
`locate`, `player_life`, `enchantment`, `tooltip`, `item_hover`,
`block_batch` and `placement` per step), then through `scripts/heavy.py` the
full `mix test`, 709 of 710 (104.5 s; the one failure was the block batch
test still expecting the old 4,096-edit limit, since fixed and passing), and
`check_vanilla.py --changed` from before the first commit: 131 of 131 stages
(`NBT`, `ItemStack` and the text modules reach nearly every stage).

Client: the VMC-077 interim run (release b8646a33) found two faults, both
fixed with server-side tests. Solid `/fill` wrote only the box's shell (a
binding in the plan's comprehension acted as a filter and dropped every
interior cell; hollow left its interior unchanged), so a filled water pool
was air on the server; `test/command_box_edit_test.exs` now reads every
cell of solid, hollow and outline fills. `/give` named the bare item
instead of the stack (`ItemData.display_name/1` is now vanilla's
`getDisplayName` for every stack). The milestone handoff still covers
`/clone … move` across regions, `/fill` in a region with activity and
`/give` with components.

Size: lib, native and config +2,423 / −2,854 lines over six commits; tests
+248 / −23. Gone: the path table and its trampolines, `Command.ComponentCodec`,
`Protocol.TextComponent`, `Command.ItemComponents`, four `NBT` item-list
copies, the per-module number and UUID helpers, the connection state in the
source and the region-by-region block writes.

Next / deferred:

- `fill_box` and `clone_box` as Rust calls: the plan is made in the command
  process from `read_box` and checked by compare-and-set under the lock, not
  evaluated inside the owner.
- The commits of several owners are separate durable frames; a crash between
  them can keep some (one frame across owners is VMC-077f's).
- `Text.Codec` keeps the command and item validation paths side by side in
  one module; deriving item identity from the normalised component is open.
- `/gamerule` serves the rules ValiMC models; a generated rule table owned by
  the environment owner waits for M3's rules.
- `execute` (modifier slot only) and targets over mobs (M3's entity store).
- `TickRate` still calls `Feedback.console` and `Packets.commands` reads the
  command catalog.
