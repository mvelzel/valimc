# VMC-032b — Double chests

Status: Done
Milestone: M3
Depends on: [VMC-032a](VMC-032a.md) (chests).

A chest placed beside a chest of the same facing joins it as vanilla does
(type left and right). Sneaking normally keeps chests single; a side click
can deliberately join the clicked chest. The large menu spans both halves,
including a section boundary. Breaking either half splits them. Sections
that can interact share a group, so both contents and the hosted player's
inventory use its existing atomic frame. Until owners merge, a joined menu
fails closed; it never treats another group's snapshot as authority.

Acceptance:

- Placement, menus and contents match vanilla on the real client,
  including across a group line.
- Contents persist through a restart.

## Implementation (October 24, 2026)

The shared generated placement and shape rules already choose joined states,
update the old half and split a remaining half on removal. Their former
admission guards are removed. Each ordinary chest block, single or joined,
keeps its own 27-slot entry and unpacks its own generated loot once.
`Chest.positions/3` derives the partner and right-before-left slot order
from the existing generated state facts. Trapped chests never join ordinary
ones; facing, complementary parts and both live entries must agree.

`World.ChestMenus` plans the 54-slot view and every click over the owning
group's resources. Both replacements validate before any is adopted. The
view carries both revisions and subscribes to both physical positions;
changes refresh either opener, and removal invalidates both lids. Either
half's roof can block opening. The existing cursor, drag, shift-click,
collect, throw, close and inventory engine serves the large menu. There
is no new permit, receipt, process or persistence format. Sounds originate
once at the joined center; the other half remains silent.

Hoppers and droppers use the same ordered view and split replacements back
into physical entries. Hoppers plan every sibling replacement before
adopting any; the group's shared frame includes all of them. The group
applies sibling effects between tick phases, so this tick's droppers are
visible before its hoppers run. Comparators read the combined fullness,
and a content change updates comparators beside both halves.
Preserved names, locks and other unsupported block-entity data never acquire
an empty owned container when preparing either half.

Reference: pinned Mojang 26.3 jar `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`,
`ChestBlock.getStateForPlacement`, `updateShape`, `getContainer`,
`DoubleBlockCombiner`, `CompoundContainer`,
`AbstractContainerMenu.getRedstoneSignalFromContainer` and
`ChestBlockEntity`'s opening sounds. The original access and sound oracles
now observe joined combinations, slot order, fullness and sound placement;
placement checks exercise the existing generated rules on neighbor contexts.

Focused owner tests cover joining, a collect across two sections, contents
through a reload, splitting, both roofs/lids, joined comparator fullness,
a dropper inserting through the other half, and two ordered hoppers taking
from opposite sections. Socket checks retain existing chest and loot flows.
The fast suite passes 539 checks. All 27 affected vanilla stages pass,
including 55,584 placement candidates (960 joined), 1,176 native container
combinations with slot order and fullness, and 24 half-sound traces. The
focused socket/owner checks pass. Private logs: `.local/double-chest-fast.log`,
`.local/double-chest-vanilla.log`, `.local/double-chest-machines-tests.log`
and `.local/m3-final-focused.log`.

Client scenario, batched with the next player-visible milestone: place two
chests, open either and move items through both halves of the large menu;
shift-click and collect across its midpoint. Check sneaking and a third
chest, block either roof, break each half in turn, and reconnect with the
contents retained. Repeat across x=128. Feed and empty it through either
half with hoppers, and check a comparator against a half-full large chest.
The finale batch below completes this graphical gate.

## Finale client finding (October 24, 2026)

The frozen `264113e1` client batch passes actual x=127/128 placement, the
six-row menu, items in both halves, and a fresh-client reconnect. An
isolated single click then reproduces a menu closing when the content
change also updates nearby comparators. The retained trace shows
`Player.Menus.refresh/2` receiving `{:error, {:retry, :chest_busy}}` from
`Region.menu/4`, immediately followed by `Menus.close/1`. The chest stays
intact. This is a transient write-plan conflict, not an invalid view.

The repair keeps its subscription and dirty view on the existing shared
retry error, so the next player tick refreshes it. The focused owner test
holds one half busy, checks no close or output, releases the plan and
checks the refreshed view; actual removal still closes it. All ten
chest/cooking/owner flow tests pass, as do the 559-check fast suite and the one affected vanilla stage (official-codec TCP). Logs:
`.local/double-chest-refresh-flow-tests.log`,
`.local/m3-gate-headroom-menu-fast.log` and
`.local/double-chest-refresh-retry-vanilla.log`. The combined runtime's
graphical recheck follows. Private evidence:
`.local/client-tests/M3-finale/chest-menu-trace.txt` and
`chest-single-click-after.txt`; the batch report retains the FAIL.

The combined repair build's fresh run-03 passes that exact single-click
reproduction after a full server restart. The retained six-row contents
reopen; a disclosed half-full stock isolates the retry. One actual click
keeps menu id 2 open with 64 carried and 26 full stacks; placing the stack
in the inventory and returning it also keep the view open. The comparator
output changes from seven to eight, with both halves visibly powering
their wires. Reviewed images and owner reads are under the same evidence
root: `chest-repaired-single-click.png`, `comparator-both-halves.png` and
`chest-repair-before.txt`, `chest-repair-after.txt`,
`chest-repair-returned.txt`. The original failure remains retained;
the remaining placement and split scenarios also pass below.

The completed batch passes actual sneaking ground placement as two singles,
deliberate sneaking side placement as a joined chest, and a third adjacent
chest remaining single. A roof over either half blocks opening from its
partner; removing it restores the six-row menu. Actual double-click collect
combines disclosed 20/30-stone stacks across the section line into 50, and
actual shift-click transfers work through both menu halves with the view
remaining open. Survival axe breaks of each half spill only that half's
stock and one chest item; the remaining three-row chest retains its own
gold or diamonds. Earlier hopper fixtures feed and extract through both
halves, including extraction through an empty physical half from its full
partner. Initial contents survive both a fresh-client reconnect and a full
server restart. These close the player-visible scope; they do not claim
every drag/overflow permutation or audible playback on the muted client.

The primary reviewed the tester's report and saved joined/single menus,
both-half comparator view, collect/shift counts and opposite-half spill/
survivor images. The full fixture limits and original failures remain in
`.local/client-tests/M3-finale/report.md`; images include
`chest-sneak-side-menu.png`, `chest-third-menu.png`,
`chest-collected50.png`, `chest-shift-lower-half.png`,
`chest-opposite-break.png` and `chest-opposite-survivor.png`.
The final parent fast suite passes 561 checks with the later shared dragon
repair, in `.local/dragon-motion-build-fast.log`.
