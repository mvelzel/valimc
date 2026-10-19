# VMC-006a — Registered world clocks and time synchronization

Status: Done
Note: Done — core clocks validated, local. Updated: October 14, 2026. Depends on pinned registries, play initialization and bounded replication.

## Scope and acceptance

Before: play sends no time packet and owns no advancing/persistent world clocks.
After: game time and both core-pack clocks advance at 20 delivered ticks/second;
login and periodic synchronization use the actual 26.3 clock-map packet. Trusted
host APIs set ticks, pause clocks and control advance-time for development/admin
integration. Weather, time-marker commands, complete gamerules, dimensions, idle
server pause and authoritative region gameplay phases remain separate work.

- Native long game time, registered holder IDs, VarLong clock totals, float32
  fractions/rates and paused/global advance behavior must match Mojang. Use its
  actual ClockInstance.tick and codecs as independent oracles. Runtime rate
  admission is bounded at 1,024 clock ticks per game tick; this is an explicit
  preview guard, not complete vanilla command parity.
- One supervised world-clock owner holds this shared world state. Connections
  sample an immutable cached packet in protected ETS; no per-player tick messages,
  fan-out queue or gameplay calls through a global coordinator. Region mutation
  remains independent. Use one fenced absolute-deadline timer; stalls do not
  advance simulation by elapsed wall time or enqueue unlimited catch-up work.
- Linked storage performs bounded read/checksum validation and atomic synced
  writes outside the ticking owner. Keep at most one pending checkpoint, matching
  acknowledgment/deadline fences, save the latest state on graceful shutdown and
  preserve corrupted files. Missing files initialize defaults; no offline catch-up.
- Meaningful tests cover fractional arithmetic, independent pause, global stop,
  stale timer/reply fencing, slow/failing writes, persistence/corruption and actual
  TCP initialization/periodic updates. Run format, suite, release, full Mojang
  oracle, public audit and exact diff review.

Actual Minecraft 26.3 via CUA: reconnect to the new release; trusted host fixtures
freeze advance-time and set Overworld day, night and day again. Observe sky/world
changes from real set-time packets, continuing world/command responsiveness and
restored controls. Reconnect and full restart must retain a paused pinned clock,
then unpause and observe advancing game/clock totals without reseeding. Restore
normal default clock controls and original pose/inventory. Host fixture controls
are explicit; this does not prove unimplemented vanilla time commands or weather.

## References and design

Pinned Mojang 26.3 SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`ClientboundSetTimePacket`, `ClockNetworkState`, `ServerClockManager`,
`ServerClockInstance`, `ClockState`, `WorldClock` and negotiated core-pack holders.
Private bytecode remains under ignored `research/disassembly/VMC006a-*`.
Minecraft 26.3 uses clock-map synchronization rather than the legacy day-time
long/boolean packet. Rate accumulation rounds after each float operation.

## Verification

October 14: format check, all **263 ExUnit tests** (seed 133886), production release,
full Mojang oracle and public-tree audit pass. ClockOracle invokes the actual
native clock tick and value codec for **3,600** cases, including float32 rounding,
fractional rates, independent pause, global advance-time and signed-long wrap.
Mojang decodes all 3,600 Elixir network values. Its full TCP protocol decoder checks
both negotiated holders, initial clocks and periodic 20-tick updates.
Private automated logs: `.local/vmc006a-{tests,release,oracle}.log`.

Nine new tests cover records, controls, early/stale tick fencing, actual delivered
time, one immutable save while storage is suspended, newer dirty revisions,
stale acknowledgments/deadlines, graceful recovery, corruption preservation,
failed writes and a physical-commit/withheld-ack recovery fixture. The TCP test
also verifies paused rates and continued command response. An initial test used
the wrong TestClient helper signature; the fixture was corrected to stop after
play login and capture the initial clock packet. Corrupt-start testing uses the
supervisor boundary rather than linking a deliberately failed owner to the test.

Clock storage uses unique temporary filenames; old interrupted writes cannot
reuse a replacement writer's temporary file. Fatal/uncertain termination never
flushes older memory and waits for writer termination before owner replacement.
A current login packet is published each tick separately from the cached periodic
packet/version, so joining players do not receive a one-second-old snapshot.

Actual **Minecraft 26.3**, `ValiMC computer-use test`, app
`local.valimc.minecraft-client`, localhost production release starting **07:59:47
CEST**: CUA rejoined, switched to third person and observed host fixtures setting
6000 daylight, 18000 midnight (dark sky/stars/ground), then 6000 daylight again.
`/stats` responded during global advance-time stop. Independent Overworld pause
held exactly 6000 while game time and the End clock advanced. Normal disconnect/
rejoin retained daylight and the pinned paused state.

A full release restart at **08:03:57 CEST** recovered the exact Overworld clock,
pause/rate/fraction and advance-time control without reseeding. CUA rejoined and
observed retained daylight. Unpause resumed Overworld totals and game time;
`/stats` still responded. At **08:05:33 CEST**, game time was 6913 and Overworld
total 6986 with normal rates, unpaused clocks and advance-time enabled. Original
player pose/empty inventory, nil outbox and source sequence 29 stayed intact.
First-person view was restored and the client left paused. The private client log
`.local/client-tests/VMC-006a/latest.log` has zero ERROR/DecoderException entries;
context is `/tmp/valimc-vmc006a-context.etf`.

No runtime repairs were required during graphical validation. This validates End
clock data/codecs, not unimplemented End dimension gameplay. Full weather,
gamerules/time-marker commands, idle pause, data-pack clocks, native saved-data
NBT and deterministic coupled region simulation remain incomplete.
