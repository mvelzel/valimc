# VMC-034j — Cooking transfer journal foundation

Status: Done within transfer-journal foundation scope at5105393. Live menu admission belongs to VMC-034k.

Acceptance: bounded v2 container requests carry cooking kind/three expected slots
and produce deterministic player/region decisions. Retain v1 bytes and old player
outbox bytes. Reuse reserved receipt slots, source counters, revision fencing and
player prepare/seal/recovery. Different payloads must not reuse an accepted receipt.
Reject output withdrawal while recipe-use records need an unimplemented XP award.

Requests fence content revision/slots/kind, not observed progress. The owning region
must apply external edits to its authoritative cooking state; observations cannot
overwrite timers. Tick/completion admission will define separate progress handling.
No new process, generic grant relaxation or automatic cooking is introduced here.

Capture old request bytes before editing. Test codec corruption/limits, old chest
regressions, cooking edits/replays/stale rejection and player item conservation.
Actual client: frozen baseline while no live caller exists. Live grants/open/menu
exchange and award behavior need separate feature acceptance before enabling them.

October18: v2 retains the95-byte bounded header and existing maximum; the kind
tag selects three cooking slots. V1 generic requests keep their original layout.
All48 pre-extension v1 request and wrapped player outbox byte strings remain exact
(`.local/container-request-legacy-{capture,comparison}.log`). Canonical decode
rejects foreign regions, unknown kinds, truncation/trailing bytes and forged fields.

47 affected checks pass(seed598134), `.local/cooking-transfer-targeted-final.log`:
all three kinds, receipt replay/conflict/stale rejection, player prepare/restore/
seal in both permissions and both outcomes, owner progress preservation, XP-bearing
output refusal, existing chest/storage/connection recovery and cold-owner grants.
Cooking edits use the current owned state and retain all recipe-use records.
A real cold owner refuses cooking admission without changing counters or items.
No live permission widened; rejection/recovery still writes a terminal receipt.
Formatting and legacy comparison pass.

Frozen5105393 production and both current native TCP transports pass
(`.local/cooking-transfer-{production,native-tcp}.log`). Combined G/H/I/J baseline
passes on that exact checkpoint against a whole stopped F clone with an added
empty chest. The immutable release was retained throughout.

October18: accepted combined G/H/I/J actual26.3 baseline on frozen5105393.
Actual ordinary chest deposit/withdraw restores exact slots/cursor; source18→20,
typed20, independent item18 and storage23→25 remain consistent through fresh
reconnect. Three occupied processor entries remain exact. Both clients stopped143;
server20532 flushed/stopped0. Report `.local/client-tests/VMC-034j/report.md`,
stopped audit `.local/cooking-transfer-final-audit.log`,1,149 unchanged frozen blobs
and eight whole-dataset file hashes `.local/cooking-transfer-publication-proof.json`.
This closes the unused-foundation baseline, not live cooking/menu/XP gameplay.
