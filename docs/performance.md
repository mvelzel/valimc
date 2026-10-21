# Measured prototype behavior

[Section storage](tickets/VMC-062.md) (`bench/section_storage.exs`, 30-sample
medians, one chunk packet before compression): Rust paletted sections versus the
former Elixir edit map and encoder. One edit 3.7 ms → 0.10 ms; 4,096 random edits
20.5 ms → 0.20 ms; a terrain-like chunk (49,152 varied blocks) 93.6 ms → 0.23 ms
with block memory 3.0 MB → 75 KB. Untouched chunks keep the cached flat packet.

[Chunk biomes](tickets/VMC-023.md) (`bench/worldgen_biomes.exs`, matched with
vanilla's own code: the same 256 overworld chunks, one thread, ten timed passes
after warm-up): the climate volumes and 1,536 biome lookups per chunk take a
median 222 µs in ValiMC against 388 µs in vanilla.

[Terrain generation](tickets/VMC-024.md) (`bench/worldgen_terrain.exs`, matched
with vanilla and Pumpkin: the same 64 overworld chunks at seed 20261020, one
thread, ten timed passes after warm-up; medians over runs). The noise fill
with aquifers takes 2.5–2.8 ms per chunk in ValiMC, 2.4–2.5 ms in Pumpkin and
3.6 ms in vanilla. Terrain through carvers (chunk biomes, noise, surfaces,
carvers) takes 5.7–5.9 ms in ValiMC and 5.7–5.9 ms in Pumpkin; Pumpkin's
blocks differ from vanilla's in 28 of 6.3 million. The ticket explains why
vanilla's 12.5 ms for the whole step is not a matched number.

[Decoration](tickets/VMC-025.md) (`bench/worldgen_decoration.exs`, matched with
vanilla's own features: 64 chunks at seed 20261020, one thread, terrain
excluded): all 171 overworld placed features take a median 0.78–0.79 ms per
chunk against 2.4–2.7 ms in vanilla. Pumpkin's features stage on the same
chunks takes 0.83 ms; it also places structure pieces, so the comparison is
matched apart from structures.

[Live decoration](tickets/VMC-025.md) (`bench/worldgen_live.exs`, seed
20261020, a fresh decorated world finalizing 2 × 2 regions at once through its
proto owners: 400 terrain chunks, 324 decorated, 256 final, every proto log
write durable; 10 dirty schedulers). Measured only on a host at load average
42–47 from other work, where plain terrain alone took 34–57 ms per chunk on
one thread instead of the matched 5.7–5.9 ms, so absolute numbers are not
comparable with the entries above or with Pumpkin; a matched run on a quiet
host is pending. Ratios from the same runs: encoding a chunk as a proto chunk
adds 18% to its terrain, and decoration over encoded chunks (decode, decorate,
encode the touched ones) takes 1.8 × the decoration alone; full chunks add
about 7% of the terrain's cost. Throughput was 18–58 final chunks per second
across those runs.

[Structure starts](tickets/VMC-025.md) (`bench/worldgen_structures.exs`,
matched with vanilla's own generator: the overworld's 40 × 40 chunks around the
origin at seed 20261020 through `createStructures`, one thread, thread CPU time
on a host loaded by other sessions): 46–49 µs per chunk in ValiMC, 105–121 µs in
vanilla and 373–437 µs in Pumpkin's structure start stage.

[Fresh terrain](tickets/VMC-071.md) (`bench/fresh_terrain.exs`, one loopback
client at view distance 10 teleported three times into terrain no region has
generated, alternating runs on the same 10-core host under other load): with one
locked worldgen state the first new chunk took a median 4.1 s and the whole
473-chunk view 7.7 s; with a state per dirty scheduler, parallel batches and the
nearest regions first, 0.86 s and 3.1 s. Each fresh view generates 1,024 chunks
(whole regions).

[Cooking activity indexing](tickets/VMC-034m.md): 1,024 stored processors,
100 alternating equal-result samples. With 64 active, p50/p95 falls from
8.295/11.967 to 6.942/9.078 ms; with 1,024 active, from 44.097/51.686 to
32.751/39.619 ms. Pure worker work only; disk/publication/player simulation
excluded. Raw workloads, revisions and limits live in the ticket.

Contact-hazard comparison: matched 128-player static-water samples and
the 512-player reverse pair pass; the initial 512 baseline has 469 movement corrections.
[VMC-017b5](tickets/VMC-017b5.md) records all six samples and limits. The existing
worker-admission/host-load finding remains open; no stable 512 capacity is established.

The samples below use this macOS ARM64 host with **10 BEAM schedulers**, Elixir 1.20.4 and OTP 29.1.1. These are short development measurements, not production capacity limits or cross-server comparisons.

A separate Python process opens real loopback TCP connections, completes compressed Minecraft 26.3 login/configuration, loads its flat spawn chunks, acknowledges batches and keepalives, and sends 100 movement packets per client. Both runs used view distance **1** (nine chunks); since VMC-070 the vanilla minimum is **2** (49 chunks), which the loader now uses, and the default server view distance **10** sends up to 473 chunks per client.

| Scenario | Connected clients | Disconnects | Movement packets sent | Measured movement interval | Login p95 | Final BEAM memory |
|---|---:|---:|---:|---:|---:|---:|
| Co-located players, mutually visible | 128 | 0 | 12,800 | 5.109 s | 23.53 ms | 104.2 MiB |
| Players spread into separate regions | 512 | 0 | 51,200 | 5.786 s | 128.36 ms | 425.2 MiB |

Raw samples include timestamps, counters, scheduler/process counts and an implementation SHA-256 fingerprint: [dense 128](benchmarks/dense-128.json), [spread 512](benchmarks/spread-512.json). The final fingerprint for both is `4e525f4b138dcd203e9e20822d2674465610e2a5808d0fa6a5fc3a81988e65ef`. Library code, configuration and protocol facts are included in that fingerprint.

These historical runs predate client-tick admission. The current driver sends a
`client_tick_end` after every position and records its own hash and delimiter
count. New samples therefore have a different packet workload; retain that context
when comparing them with the archived numbers below.

The driver also now verifies every final authoritative position and fails on any
movement correction. Spread players start at saved spawn fixtures. Current runs
include sampled movement/pose geometry, so they are not comparable to the old
unvalidated-movement timings. [VMC-014c4](tickets/VMC-014c4.md) records the admission
finding, fix and 128-player checks; raw development samples remain ignored.

The historical spread scenario joined everybody at spawn before moving them apart.
It ended with 515 resident region owners and 4,617 encoded chunks. The dense run
reused nine encoded spawn chunks across 128 clients and produced roughly 1.6
million outbound packets. Dense visibility has substantial replication/bandwidth
cost even with compact peer views, batching and concurrent observers.

## What the numbers measure

Login latency includes initial nine-chunk delivery. The driver requests 20 movement updates per second; the actual elapsed interval is reported because scheduling overhead can extend it. Counter snapshots are sampled every 100 ms and may lag the final input. Memory is the BEAM's reported total at the final sample, not peak RSS. Python client memory is separate, although both processes share the same physical host.

The world is a cached, trivial flat generator with sparse edits. There is no survival simulation, AI, redstone, fluid propagation, collision checking, online authentication, encryption or Internet latency in these runs. Region tick counters measure scheduling callbacks; they are not evidence of meaningful survival TPS. These short samples do not establish long-term memory stability or a maximum supported player count.

## Reproduce

```sh
python3 bench/load.py --players 128 --seconds 5 --output bench/results/dense-128.json
python3 bench/load.py --players 512 --seconds 5 --scatter --output bench/results/spread-512.json
```

Run scenarios sequentially on an otherwise quiet machine. The driver starts an isolated server on a free port with a temporary world, reports metrics, and shuts it down. Longer runs up to 60 seconds are supported. Any disconnected clients make the benchmark fail instead of silently counting the surviving clients as a successful result.

Archived sources report a null Git revision rather than borrowing a parent
checkout's revision. Retain their frozen manifest alongside the implementation hash.

Add `--fluid` for static source-water pools and loaded sprint input. The driver
requires every participant's observed swimming flag/pose before and after the
interval. Positions remain scripted; this measures the fluid geometry/simulation
path, not client prediction, propagation or survival. Keep this workload separate
from dry results. [VMC-015d3](tickets/VMC-015d3.md) records its verification;
[VMC-015g](tickets/VMC-015g.md) records the controlled slowing-pipeline comparison.

The next useful performance work is sustained tests with larger view distances, adversarial input, edits during encoding, generation without a shared flat baseline, and finally matched vanilla survival workloads. Comparing the same behaviors, seed, dimensions, client positions and hardware is required before making claims against Paper/Folia, Pumpkin or SteelMC.

[Owner-local block batches](tickets/VMC-011a3.md) now have a separate bounded
commit/replication microbenchmark in `bench/block_batch.exs`. Its local subscriber
workload measures batching, not network rendering or survival capacity.

## Test suite wall time

ExUnit runs async modules first, then sync modules one at a time, so serial
modules add their full duration. Region and player-store tests now read a
per-owner world path and toggles (`Valimc.config/2`) instead of swapping app env,
and 24 of the 41 serial non-socket modules run concurrently. Same 10-core Mac,
same 1,563 tests, `/usr/bin/time` wall time with ExUnit's async/sync split:

| Run | Before (818b952) | After |
|---|---|---|
| `mix test.fast` | 41.2 s (17.1 + 24.1), 46.3 s (19.8 + 26.5) | 28.9–30.9 s over five runs (≈15 + 14.5) |
| `mix test --only tcp` | 76.7 s, 80.4 s | 70.7 s (unchanged suites; run noise) |
| `mix test` | not measured cleanly (see below) | 97.3 s (19.2 + 78.1), 100.6 s wall |

The one full baseline run used `--slowest-modules`, which implies `--trace`, so it
ran fully serial: 94.8 s (12.7 + 82.0). Its async phase was shorter than the
concurrent one (15–19 s), so that phase is contended rather than short of
parallelism. Lowering concurrency did not help `test.fast` (`--max-cases 10`:
31.8 s, `5`: 39.8 s); this was not investigated further.

The socket suites stay serial. A trial running 12 of them concurrently took 124.7 s
with 17 of 108 tests failing, against 12.8 s serially. They share the listener,
the connection supervisor, the global player list and broadcast chat, and several
log in more than one player. Raw logs stay in `.local/perf/test-suite-concurrency/`.

Most of the remaining serial non-socket time came from six modules, each serial
because of one to seven tests that saturate a global worker pool or assert a global
`Metrics` delta. Those tests now sit in a `Serial` module at the end of their file,
sharing the async module's setup; the other 57 tests run concurrently. Same
machine, same 1,003 `test.fast` tests:

| `mix test.fast` | Wall | Async | Sync |
|---|---|---|---|
| Before (1460118) | 30.7 s, 32.9 s | 13.2 s, 14.6 s | 14.3 s, 14.5 s |
| After | 27.7 s, 21.9 s | 18.3 s, 13.9 s | 4.6 s, 4.7 s |

The serial phase drops by about 10 s. Two runs cannot tell whether the wider async
spread afterwards is machine noise or added contention; the six files alone also
varied, 4.7–12.3 s async across five runs. Raw logs stay in
`.local/perf/test-suite-split/`.
