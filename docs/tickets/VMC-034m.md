# VMC-034m — Live regional cooking

Status: Implementing after VMC-034l; K's client checkpoint remains immutable.

Acceptance: loaded owned processors consume fuel, advance/cool, complete items,
publish native progress/lit states and retain recipe uses across restart. Admit
fuel/remainders/completion/recipe counters atomically before publication. Keep
menus responsive and coherent across concurrent transfers and owner replacement.
XP-bearing output keeps its explicit refusal until a complete award protocol exists;
this slice cannot close the whole furnace feature.

Use one existing region clock and bounded work on existing workers, without
per-processor processes/timers. A native logical step must cover every eligible
processor without repeatedly encoding the same region snapshot in small tiles.
Bound the proposal by the existing1,024-entry storage limit. Keep owner ordering,
generation/fencing and disk acknowledgements explicit.

Progress-only changes may remain owned memory with a bounded checkpoint cadence;
item/recipe/lit changes require joint durability. A crash may rewind uncheckpointed
heat/progress, never duplicate inputs, outputs, fuel remainders or recipe awards.
Observers need a coalesced progress generation separate from content revisions.
Define active/sleeping transitions and transient capacity refusal retrying so stable
empty/blocked processors do no continuous work and no processor starves neighbors.

Client scenario: all three types actually ignite/cook, correct relative cook times,
input depletion, full-output pause, invalid fuel, water bucket/sponge, menu refresh,
close/reopen and restart conservation. Verify only implemented output/award scope.

October18 measured scheduling prerequisite:27 affected tests pass(seed820030),
including a complete1,024-processor step with preserved item revisions. The
existing64-entry limit would require16 whole-snapshot validations for that logical
step. With identical1,024 occupied processors/receipts and exact equal final state,
100 alternating matched samples show tiled64 p50/p95=81.762/118.045ms versus
whole1,024=9.117/13.789ms. Ten warmups, ten BEAM schedulers; a separate graphical
client was running. This is pure planning, excluding I/O/publication/players;
no whole-server capacity or cross-server speed claim.

Baselinec10988f; candidate changes only the bound. Raw workload/baseline source/
samples are `.local/cooking-batch-bench-whole.exs`, `cooking-batch64-bench.exs` and
`cooking-batch-bench-whole.json` (SHA256d32fb298b89c59c396891a03b68e72d48c240fdbd42812d7e95e83f830760d5d).
The first implementation uses one bounded whole-region proposal, not a task per
processor. Runtime admission, progress generations, checkpointing and actual
cooking validation remain; no scheduler is enabled yet.

Progress observation checkpoint:43 affected checks pass(seed665206),
`.local/cooking-progress-viewers-targeted-final.log`. One pending notice coalesces
1,000 timer generations independently of content changes; neither acknowledgment
can clear a newer observation in the other lane. Owner/session refs fence stale
notifications. An actual TCP menu refresh publishes new progress with the same
item revision/source and acknowledges the right generation; ordinary chest and
all cooking exchange regressions pass. The harness now consumes the asynchronous
initial subscription snapshot before checking later progress. No live timer sender
or automatic cooking is enabled by this checkpoint.

Next implementation: run one owned batch from the existing regional clock, using
existing bounded workers/write lane. Compute activity and candidate encodings off
owner; serialize epoch/token/content checks and durable publication. Keep normal
menu admission responsive while planning, and fence any canceled proposal. Bound
progress generations by owned entries and clear them on removal. Timer checkpoints
must share write ordering with item changes; uncertainty retires the owner rather
than publishing speculative state. Actual cooking/XP gates remain open.
