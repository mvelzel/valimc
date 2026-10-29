# VMC-081c — Generation on every core, below the game

Status: Awaiting client
Milestone: M3, at the user's request
Parent: [VMC-081](VMC-081.md).
Depends on: [081a](VMC-081a.md).

Capture 11 stalled exploration on the two-vCPU host: the generation pool was
dirty CPU schedulers minus two, so one job at a time, and it shared both
vCPUs with the game at the same priority. About 1,000 chunks a minute arrived
and the player's own chunk was missing 9 times for 12.8 s in all.

## Background generation threads

Generation jobs do their native work on background threads, one per core
(`:worldgen_threads`, `VALIMC_WORLDGEN_THREADS`), at nice 10 on Linux (QoS
utility on macOS). Each generation NIF has a `_background` twin that queues
the work and sends `{tag, :ok, value}` or `{tag, :raise, reason}` to the
caller; `Valimc.Native.background/1` waits for it in the job's process, so the
scheduler, its slots and its results are unchanged. Decoration, full chunks,
decoding and spills go before queued terrain. A full chunk is lit alone in the
same job. The pool runs two jobs more than there are threads, so a thread
never waits for the scheduler to start the next; terrain leaves the last slot
to finishing work. Commands (`/locate`, `/place`, growth) still make dirty
calls from their slot.

The release's idle schedulers sleep instead of spinning (`+sbwt none` and its
dirty twins in `rel/vm.args.eex`): spinning takes the CPU the threads would use.

The twins equal their dirty NIFs (`worldgen_background_test.exs`: terrain,
decoration, encoding, decoding and full chunks, and the raise).

## Measuring on two cores

`bench/tick_budget.Dockerfile` builds the harness in a Linux container. Runs
pin it to two cores (`--cpuset-cpus=0,1`): a CPU quota (`--cpus=2`) stops every
thread once it is spent, schedulers included, so OS priorities cannot protect
the tick there as they do on the VPS's vCPUs. The harness now reports the
generation and region counters over its window and, while the flying client
waits in a chunk it lacks, why (`Scheduler.where/3`: section not loaded, not
wanted, generating and at which status, waiting for credit, delivered, or
published and not sent).

The first template had lost its generation snapshot (a killed `prepare`), so
every chunk beside the saved area was made alone over fresh terrain and so was
every chunk after it, about five times the work per chunk. A live server does
this only after a crash (captures 10 and 11 had no alone jobs), but then for
every chunk generated outward from the saved area, never recovering: a
follow-up should let a blocked decoration run over fresh terrain for its
frozen neighbours, so only one ring is made alone. The template
was regenerated with its snapshot (`template-20261020b`); the harness defaults
to the production proto cap and takes `FLY_SPEED` and `PROTO_CELLS`.

## Proto cells

The hosted cap (`VALIMC_WORLDGEN_PROTO_CELLS`) was 128, set for view 4. At
view 32 the cells in flight exceed it, so most cells spilled and were read
back: 3,226 spills a minute at 20 blocks per second before, 9,731 with more
jobs in flight. At 512 (about 100 MiB at 200 KiB a cell) there were 64.

## Results

Two pinned cores of the development Mac's Linux VM, 60 seconds, the same
template; the baseline is 13373b2d. At 20 blocks per second both keep up
with the player (4,621 against 5,046 chunks), so the comparison flies at 60:

| Fly 60 blocks/s | Base, 128 cells | Base, 512 | 081c, 512 |
|---|---:|---:|---:|
| Chunks generated | 4,511 | 4,850 | 6,783 |
| Time the client waited in a missing chunk | 32.8 s | 30.9 s | 21.4 s |
| Blocks flown | 1,641 | 1,755 | 2,325 |
| Completed TPS (mean / lowest second) | 20.0 / 18.7 | 20.0 / 19.0 | 20.0 / 18.9 |

The client waited 21.5 s in a later 081c run: 16.9 s for chunks being made
(decorated, waiting for their neighbours' decorations or the full job), 3.5 s
for chunks published but not sent yet (their frame's durability, on the
container's slow bind mount) and 0.1 s for credit. Combat is unchanged: tick
mean 20.4 against 21.1 ms, entity phase 15.5 ms in both, 20 TPS.

The VPS's cores are about three times slower, so it falls behind the player
at 20 blocks per second, where these runs keep up; it now generates on both
vCPUs instead of one dirty scheduler. A user capture confirms.

The owner's install of delivered chunks was 28% of its sampled time at 60
blocks per second: `put_columns_lit` (light installed and crossed into the
neighbours) 19%, the chunks' first creatures 7% and light halos 6%. Moving
that light into the generation pipeline is the next slice.

## Generation priority

Wanted chunks are already ordered by the nearest player (urgent calls first,
then the own chunk, then squared distance weighted by heading: ahead counts a
quarter, behind seven quarters), re-scored when a player crosses a chunk, and
chunks that leave every view stop being goals and are never made. A chunk
needs terrain for its 5 × 5 and decoration for its 3 × 3 before it is final.

Acceptance:

- Generation and its order unchanged; the background twins equal the dirty NIFs.
- Matched two-core runs before and after: more chunks per minute, the tick
  no slower.
- A user capture of exploration on the VPS.

Checks: worldgen background (new), scheduler, frontier, proto, structures,
spawn search, generator pool, region generation, decorated world, growth,
place, dragon, region and Anvil light and imported region tests pass; native
builds and clippy add no warnings. `check_vanilla.py --changed` selects all
261 stages (a configuration change); all pass, with world-settings
extraction still not verified (no cached regeneration).

Deployed `6b75bae680039e42227a2974825f97acd154d2ce` to the Hetzner host on
October 29 with the same `valimc_data:/data` volume, view 32, simulation 10
and public diagnostic origin. The running release has two generation threads
at nice 10, the sleeping-scheduler flags and 512 proto cells; the server
listens on 25565 and readiness returns HTTP 200. This verifies deployment,
not gameplay; the user takes the exploration capture. The log is in ignored
`.local/hetzner/deploy-081c.log`.
