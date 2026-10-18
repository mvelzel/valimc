# VMC-034e — Persistent cooking entries

Status: Storage and defensive owner loading implemented; full integration,
production and mixed-snapshot client baseline pending. No live cooking.

Acceptance: persist each furnace/smoker/blast-furnace's exact three slots, bounded
progress and recipe-use counters inside the existing region container authority.
A version3 container snapshot must round-trip mixed chest/cooking entries without
changing legacy1/2 bytes or source/typed receipt lanes. Corruption, invalid slots/
progress/recipe keys, stale revisions, capacity and byte exhaustion refuse whole.
The existing joint journal must retain every field across recovery.

Keep one owner, revision sequence and write lane for shared inventories. No extra
process/file/receipt authority for a furnace. Add explicit cooking entries to the
existing container format; old chest APIs remain fenced by entry shape. Sleeping
entries have no timer/process. World creation, removal/spill, GUI transfers and
active-work scheduling stay unadmitted until their complete protocols exist.

Test targeted codec/revision and joint-journal boundaries, then a frozen production
and dedicated direct-client chest baseline/reconnect. Storage alone cannot prove
actual smelting or furnace menus. Native processing behavior is established in
VMC-034a/b/c/d; persistence internals deliberately follow BEAM ownership.


October18: VMCCONTS3 adds explicit cooking entries to the same bounded map,
revision sequence and checksum. Each stores a Cooking state plus at most107
known recipe-use counters; three canonical stacks, timers/speed and total bytes
are validated before replacement. Mixed snapshots retain legacy chest shapes and
independent typed receipts. Snapshots without cooking entries still emit original
v1/v2 bytes; a frozene4c41cd capture across all six row layouts/patches/receipts
compares byte-for-byte (`.local/container-legacy-comparison.log`). No extra store,
process, journal authority or source counter is added.

41 affected checks pass(seed280432), then11 final journal/owner checks(seed613736)
after making the cooking crash fixture include its native lit-block change.
All eight partial block/item/container output subsets recover complete cooking
progress, output, remaining fuel, bucket overflow and recipe-use43; typed77 and
item-source1 remain independent. Cold/replacement owners retain exact mixed
entries. Raw edits refuse both occupied and blank processing entries until their
removal/spill protocol exists. Invalid kind/progress/recipe counts, stale views,
noncanonical stacks, corrupt/trailing/tagged payloads and exhaustion refuse whole.
Logs `.local/cooking-entry-targeted-final.log`,
`.local/cooking-entry-lifecycle-boundaries.log`. No physical/menu/cooking admission.

Client scenario: clone the stopped whole source110/typed109/item110+61 dataset,
add three paused processing entries and their unlit blocks beside the existing
empty chest, then test fresh native joins, rendering and chest open/close/reconnect.
Verify exact processor slots/progress/recipe uses and independent receipts before
and after. Raw removal refusal is a server check; actual smelting remains unclaimed.
