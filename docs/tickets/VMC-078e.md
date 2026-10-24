# VMC-078e — Keep item merge plans fenced through their tick

Status: Done
Milestone: M3
Parent gate: [VMC-078](VMC-078.md).

The combined M3 suite finds a cross-owner item merge that never completes.
The entity phase starts its merge worker, then item travel changes the copied
store's unsaved simulation marker. The existing stale-plan fence correctly
rejects that result on every attempt. Item and orb movement now wait while the
planning slot holds their store, including when a merge took it earlier in the
same tick. The fence still protects against intervening combat or explosions;
there is no relaxed comparison, new transaction protocol or queue.

Acceptance:

- A merge started during a real owner's tick leaves its worker's copied store
  unchanged until adoption, and delivers exactly once through the existing
  durable handoff and receipt.
- Existing item merges, owner recovery, portal transfers and explosion checks
  pass. The combined automated M3 gates pass on the final runtime.
- Graphical M3 testing remains deferred at the user's request.

The original full run passes 843 of 844 checks; the merge timeout also fails
alone with the same seed. A manual-tick regression observes the copied-store
mismatch before the repair. With the repair, all ten affected owner/socket
checks pass, including durable totals and the receipt after an explicit owner
tick. The first manual fixture omitted the enclosing tick's commit; its
corrected version advances both real owners until delivery completes.

A subsequent full run exposes an unrelated asynchronous chest fixture's fixed
200-ms placement deadline while the native gate is busy. Both placement fixture
deadlines now use the existing test-scaled permit window. These checks assert
block/container atomicity and recovery; they do not assert production latency.
The production deadline policy is unchanged.

Private evidence: `.local/m3-family-auto-full-tests.log`,
`.local/m3-family-auto-transfer-{recheck,regression-before,complete}.log`,
`.local/m3-family-auto-final-full-tests.log` and
`.local/m3-family-auto-placement-tests.log`. The parent records the final
combined results and the exact frozen runtime manifest.

The final complete suite passes all 845 checks in 122 seconds, including all
nine properties and 836 tests, with active checkpoint tracing and no failed
WAL reads. All five native rechecks pass: `tcp`, `item_merge`, `item_travel`,
`item_burn` and the separate export-fixture recheck. The isolated production
release also builds and loads its normal NIF while refusing a parity entry
point. Final logs and the one/eight-player budget evidence are recorded by the
parent. This closes the automated repair; the parent's deferred graphical
survival gate remains open.
