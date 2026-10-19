# VMC-034l — Atomic owned cooking batches

Status: Foundation
Note: Done within unused atomic-batch scope at `c10988f`/7cdb21e; accepted baseline `bfac2bb`.

Acceptance: one bounded proposal advances owned furnace-family entries,
retains all receipts and joins fuel consumption/remainders, input/output, recipe
uses and facing-preserving lit changes. A capacity/unsupported-context refusal
keeps that entire processor unchanged without stopping unrelated entries.
Progress-only steps retain the content revision so they cannot invalidate an
otherwise current menu exchange. Content/recipe changes allocate fresh revisions.

Run outside the owner in existing bounded workers. The future owner must fence
epoch/token/block observations and serialize admission, then journal all changed
items/blocks/containers before publication. No new process, timer, global tick or
live scheduling is introduced by this kernel. Do not equate a proposal with cooking
in gameplay; active scheduling and durability are the next slice.

References: pinned 26.3 AbstractFurnaceBlockEntity.serverTick/consumeFuel,
Containers.dropItemStack, existing 15,630 native tick cases and native block-state
facts. Fuel overflow uses the already-verified container scatter and stable item
records; remainder/item capacity must never consume fuel on refusal.

Verify all native tick compositions, mixed-batch limits/refusals/revision behavior,
exact recipe counters and joint-writer recovery with all eight output subsets.
Actual acceptance can combine this unused kernel with the next live scheduler;
K's immutable client release must not be replaced.

October 18: the bounded original kernel composes all 15,630 pinned native tick
observations with exact slots/heat/progress/speed, recipe uses, lit state and
remainder quantities (`.local/cooking-batch-native-comparison.log`). All 48 native
lit/facing pairs match. Progress keeps the content revision; item/recipe changes
advance it. Returned journal changes include unchanged block fences for content
changes, permitting the existing joint WAL even when a burning model stays lit.

26 affected checks pass(seed58691), `.local/cooking-batch-targeted-final.log`:
full 64-entry deterministic quantum, exact no-op/round-trip, whole-step recipe/
revision/item-capacity refusals, unaffected neighboring progress, native remainder
scatter and existing journal recovery. The writer's cooking fixture now uses the
actual batch plan; all eight partial block/item/container output subsets retain
recipe use 43 and exactly one bucket without altering independent receipts.
No live caller or scheduling claim. Production and combined client gate pass.
VMC-034m raises the quantum from 64 to the 1,024-entry storage bound after measuring
repeated whole-snapshot overhead; the native transition behavior is unchanged.

Accepted unused-kernel actual 26.3 baseline on immutablebfac2bb (October 18): all
three retained processor menus, ordinary chest, E/HUD/movement and fresh reconnect
pass without gestures or fixture edits. Full inventory/Containers/block values
stay exact; source/typed40/storage47/item18 and nil outbox unchanged. Clients
stopped 143 and server 73003 flushed/stopped0. Stopped audit and 1,160 frozen-blob/
eight world hashes `.local/cooking-batch-publication-proof.json`; report
`.local/client-tests/VMC-034l/report.md`. L's gate is closed; do not repeat it.
M's live scheduler, elapsed cooking and XP gates remain separate and open.
