# VMC-034g — Cooking menu presentation foundation

Status: Foundation and client baseline pass; coherent native integration pending. No live menu admission.

Acceptance: native furnace/smoker/blast menu IDs, three storage addresses plus
36 player cells, exact open/content bodies and four progress properties. Preserve
hidden player inventory and storage on an empty-cursor close. Reject malformed
views. This pure presentation layer has no authority, clicks, ticking or XP award.

Reference: pinned26.3 AbstractFurnaceMenu, furnace-family constructors,
AbstractFurnaceBlockEntity.dataAccess and ClientboundContainerSetDataPacket.
Original probes execute native constructors and codecs; controlled world recipe
lookup is empty because recipe selection/clicks are outside this slice. Keep
javap/raw output ignored. Reuse existing inventory codecs and bounded Cooking.

Verify affected layout/packet boundaries and native body comparisons. Dedicated
baseline uses the immutable checkpoint; live menu interaction is a later gate.

October18: native constructors expose menu IDs14/22/10,117 slot addresses,
three open/content bodies and180 progress contexts/720 property bodies. The
actual block-entity data access maps remaining/total fuel then elapsed/total cook
time. All comparisons pass. Empty-cursor native close retains all three storage
cells. Scalar UI properties fit signed16-bit within the supported20,000/200 tick
bounds; no extra speed property. Raw `.local/cooking-menu-{native,comparison}.log`.

10 affected layout/storage checks pass(seed921657), including hidden inventory,
invalid timer/slot shapes and progress wire bounds. Formatting passes. No live
caller. Production and the combined checkpoint baseline pass; native integration
remains pending.

Frozene9d7227 coherent physical/menu block passes1,580 full tests and production
(`.local/cooking-physical-menu-full-tests.log`, `.local/cooking-menu-production.log`).
Full native integration is running against its unchanged checkpoint. The combined
G/H/I/J actual26.3 baseline passes at5105393: ordinary chest deposit/withdraw and
fresh reconnect preserve exact items/receipts and three occupied processors.
Accepted report `.local/client-tests/VMC-034j/report.md`; stopped audit and1,149
frozen blob hashes `.local/cooking-transfer-publication-proof.json`. No live
processor interaction is claimed.
