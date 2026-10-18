# Measured prototype behavior

[Cooking planning](tickets/VMC-034m.md): identical1,024-processor steps,
100 alternating samples, tiled64 p50/p95=81.762/118.045ms; one1,024-entry proposal
9.117/13.789ms. Pure planner only; disk/publication/player simulation excluded.
Raw workloads/revisions and host-load limits live in the ticket.

Contact-hazard comparison: matched128-player static-water samples and
the512-player reverse pair pass; the initial512 baseline has469 movement corrections.
[VMC-017b5](tickets/VMC-017b5.md) records all six samples and limits. The existing
worker-admission/host-load finding remains open; no stable512 capacity is established.

The samples below use this macOS ARM64 host with **10 BEAM schedulers**, Elixir 1.20.4 and OTP 29.1.1. These are short development measurements, not production capacity limits or cross-server comparisons.

A separate Python process opens real loopback TCP connections, completes compressed Minecraft 26.3 login/configuration, loads nine flat spawn chunks, acknowledges batches and keepalives, and sends 100 movement packets per client. Both runs use view distance **1**; normal development configuration uses **3**, requiring 49 spawn chunks per client.

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
