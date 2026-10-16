# VMC-004b2e — Initial chunk-stream readiness

Status: Done within readiness scope (`c8a8a13`). October16,2026.

Observed in VMC-033f2 run02 on `6ec31a9`: a fresh26.3 client intermittently
disconnects while loading with an outbound-protocol encoder error for chunk
batch feedback. Run03 succeeds; do not erase the failed attempt. Evidence:
`.local/client-tests/VMC-033f2/report.md` and `run-02/`.

Pinned installed26.3 client `ClientConfigurationPacketListenerImpl` installs
inbound play, sends configuration acknowledgement, then installs outbound play.
`ClientPacketListener.handleChunkBatchFinished` can respond on the network
thread during that gap. Teleport handling runs on the main packet processor and
confirms with a play packet. Private inspection:
`.local/client-{configuration,packet}-bytecode.txt`. These support an initial
streaming race; the failed log alone does not prove its cause.

Acceptance: queue chunks until valid teleport confirmation proves outbound play
readiness. Reuse existing bounded pending/batch state, without sleeps or per-client
timing guesses. Early chunk feedback cannot unlock streaming; accepted confirmation
resumes it. Test actual TCP holding acknowledgement, early feedback and resumed
chunks, existing login/teleport regressions and native transports. Dedicated client
tester runs repeated fresh joins and verifies retained crafting state. Close the
VMC-033f2 reconnect limitation only after this gate passes.

Implemented the existing teleport fence in chunk admission; a first accepted
confirmation schedules streaming once. No additional process, queue or timing
constant. The regression withholds real TCP acknowledgement, forces stream work,
sends premature feedback and verifies no chunk frames until confirmation, then
loads the world normally. It fails against `6ec31a9` with an actual first four-
chunk batch (`.local/initial-stream-before.log`) and passes the fixed owner.
32 affected login/recovery/lifecycle/inventory/mode/crafting checks pass
(seed702816; `.local/initial-stream-targeted.log`). A cold-start fixture needed
to await player publication rather than assuming it followed the welcome frame.

October16 actual26.3/protocol777 readiness PASS on frozen production checkpoint
`c8a8a139b5ca7c40e65f7298bca6f6f972928f91` (710 Git blobs verified;
live Connection/Inventory/Packets paths and loaded MD5 match frozen prod BEAMs).
Exactly three planned fresh direct QuickPlay launches rendered the flat world;
all three E inventories retained saved bundle1/string1/oak_planks8/leather1 in
physical36–39 with empty grid/result/cursor, matching RPC. Each had accepted
teleport readiness and nonempty chunks. Run01 also exercised W and `/spawn`,
then continued rendering with readiness confirmed; run03 used the dedicated SDL
empty-slot click. No fresh log had the outbound-protocol encoder exception.
Earlier VMC-033f2 failed attempt remains recorded; no retries were needed here.

All three wrappers/JVMs stopped before next launch; final zero players. Full
original saved snapshot restored through lease with source61/nil preserved;
all61 complete region records and all receipt maps remained term-exact, four
regions flushed. Server/dataset unchanged beyond the restored disposable player
fixture. Evidence `.local/client-tests/VMC-004b2e/report.md`, run01–03 logs and
restore.log; dataset `/tmp/valimc-table-block-client-20261016` (12-file clone).
Sole tester used default small dedicated SDL client and CUA. This closes the
scoped readiness/retained-inventory baseline only; no live3x3/table/reach claim.
Primary accepted the report. Frozen710 source blobs were independently rehashed
after validation. The coherent foundation block passes933 full tests (seed141105),
full native integration including plaintext and continuous AES-CFB8 TCP, and a
production release. Evidence `.local/table-block-{full-tests,full-native,production}.log`
and `.local/table-foundation-block-proof.json`. This closes VMC-033f2's initial
join gate; the historical failed attempt remains available.
