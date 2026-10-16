# VMC-004b2e — Initial chunk-stream readiness

Status: Targeted-verified; native/client block checks pending. October16,2026.

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
