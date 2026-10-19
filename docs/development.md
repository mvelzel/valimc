# Development workflow

Read [AGENTS.md](../AGENTS.md), the [roadmap](roadmap.md) and the active ticket.
Use the [backlog](backlog.md) or [completed index](history/completed.md) only to
locate details. Feature evidence belongs in `tickets/VMC-*.md`.

## One slice at a time

1. Write or update the ticket from [the template](tickets/TEMPLATE.md): behavior,
   ownership, acceptance criteria and, for player-visible work, the client scenario
   that the milestone handoff will include.
2. Establish vanilla behavior from pinned codecs/behavior and generated data.
   Record reference revisions and tradeoffs in the ticket.
3. Implement original, bounded code. Test changed behavior and failure boundaries.
4. Run targeted checks, review the diff and commit.

## Checks

On a 10-core Mac `mix test.fast` takes about 30 seconds and the full suite about
100 seconds, most of it the serial socket suites; neither is a routine check.
Choose the smallest check that covers the change.

| Change | Run |
|---|---|
| Docs, tickets, scripts only | `scripts/audit_public_tree.py` (includes docs lint) |
| One module and its callers | The module's test files and the tests that name it (`rg -l ModuleName test`) |
| Several modules, no shared owner/protocol change | `mix test --stale` |
| Pure kernels (physics, codecs) | Their test files plus only the matching `check_vanilla.py --only <stage>` |
| Rust in `native/` | `cargo test`, `cargo clippy --all-targets`, plus `test/blocks_test.exs` |
| Region owner, connection, persistence or protocol core | The test files of the touched flows by name (socket suites included); `mix test.fast` once per finished parent step, not per edit |
| Milestone boundary (at most once per milestone) | Full `mix test`, then full `check_vanilla.py` (about 15 minutes) in the background |

```sh
mix format --check-formatted lib/valimc/physics/pose_fit.ex test/pose_fit_test.exs
mix test test/pose_fit_test.exs
mix test --stale
```

`mix test --stale` runs only tests whose dependencies changed since the last stale
run. Untrusted-input decoders get StreamData properties (`test/codec_property_test.exs`;
`STREAM_RUNS=5000` for a deeper run). Micro-benchmarks use Benchee (`bench/*.exs`);
scenario benchmarks of a running server stay custom. `mix test.fast` runs everything except the socket suites (`@moduletag :tcp`). Each test run uses a private temporary directory.

Tests that start region owners or player stores run `async: true` with unique
region keys: `Valimc.TestScope.isolate/2` gives the owners of those keys (and
player UUIDs) a private world path or simulation toggle, read through
`Valimc.config/2`, instead of changing app env. Cleanup uses `TestScope.kill/1`,
since a graceful `terminate_child` holds the shared supervisor. Modules stay
`async: false` when they saturate a global worker pool, assert global `Metrics`
or owner counts, assert production latency deadlines, change global clock state,
or drive sockets; the comment under `use ExUnit.Case` says which.

Rust code lives in `native/` (`valimc_core` pure crate, `valimc_nif` Rustler shim,
built by `use Rustler` in `Valimc.Native`). Run `cargo fmt --check` there too.

Vanilla oracles compare Elixir output with the pinned Mojang jar. Run one stage,
or every stage in parallel (compiles all oracles once, collects every failure,
logs under `.local/vanilla-checks/`):

```sh
python3 scripts/check_vanilla.py --only pose_fit
python3 scripts/check_vanilla.py --jobs 6
python3 scripts/check_vanilla.py --audit
```

Register every new `scripts/*Oracle.java` or `scripts/check_*.exs` in
`scripts/vanilla_stages.py`; `--audit` fails otherwise. The runner compiles into a
private build directory, so editing code during a run cannot change its result.

At a milestone or parent-ticket boundary, run the broad gate in the background and
fix failures:

```sh
mix format --check-formatted
mix test
python3 scripts/check_vanilla.py
MIX_ENV=prod mix release --overwrite
```

Never overwrite a release under client test; use a separate `MIX_BUILD_PATH`.

## Client validation

The dedicated tester validates player-visible milestones with one batched
handoff: ticket(s), checkpoint/release, dataset, scenarios and private evidence
paths. The primary keeps working and reviews the PASS/FAIL report. Docs-only edits
and unused foundations need no client run. See [client testing](client-testing.md)
and the [pointer backend](mouse-testing.md).

Keep graphical test worlds at noon: pause `minecraft:overworld`, set its ticks to
6000 through `Valimc.World.Clock.configure/1`, then `flush/0`. Test worlds are
disposable; preserve journal/receipt consistency within a dataset and reset the
whole dataset rather than one side of a committed transfer.

## Git

Commit directly to `main`. Before every commit or push:

```sh
python3 scripts/audit_public_tree.py
git diff --check
git diff --cached
```

The audit also runs `scripts/lint_docs.py` (ticket status values, roadmap length,
readable prose, links). Stage explicit paths. Push validated work with normal
pushes; never force-push without permission. Report actual push outcomes.

## Private vanilla inspection

`prepare_vanilla.py` verifies/extracts the pinned jar; `java_tool.py NAME ARGS`
runs one oracle (all sources compile together, only when changed). Use `javap -c -p`
first. Keep decompiler tools, dumps and raw outputs under ignored `research/` or
`.local/`; record jar/tool hashes and classes/methods in the ticket. Publish no
Mojang code, assets or jars.

## Measurement

Benchmark performance changes with matched workloads. Preserve raw data, revision,
hardware/schedulers, tick time, latency, failures and memory. See
[measurements](performance.md). Optimize measured bottlenecks.
