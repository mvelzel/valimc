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

Choose the smallest check that covers the change. Broad checks are rare: they
cost minutes of every core, and several sessions share one 10-core Mac.

| Change | Run |
|---|---|
| Docs, tickets, scripts only | `scripts/audit_public_tree.py` (includes docs lint) |
| One module and its callers | The module's test files and the tests that name it (`rg -l ModuleName test`) |
| Several modules, no shared owner/protocol change | `mix test --stale` |
| Pure kernels (physics, codecs, worldgen) | Their test files plus `check_vanilla.py --changed` (or `--only <stage>`) |
| Rust in `native/` | `cargo test -p <crate>`, `cargo clippy --all-targets`, plus the Elixir tests of the touched NIFs |
| Region owner, connection, persistence or protocol core | The test files of the touched flows by name (socket suites included) |
| Finished parent ticket | `mix test.fast` and `check_vanilla.py --changed` |
| Milestone boundary | Full `mix test`, every vanilla stage and a production release, through `scripts/heavy.py` in the background |

`mix test.fast` leaves out the socket suites (`@moduletag :tcp`) and the
live-generation and portal suites (`@moduletag :slow`); `mix test` runs everything.

Heavy commands go through `scripts/heavy.py`, which runs at most two of them on
the host at once (across every checkout and worktree) at low priority and queues
the rest; `--status` shows who holds the slots. Start them in the background and
keep working; read the result instead of running them again.

```sh
python3 scripts/heavy.py mix test
python3 scripts/heavy.py python3 scripts/check_vanilla.py
python3 scripts/heavy.py --status
```

Dev and test builds compile the NIF without LTO, in parallel and incrementally,
into `native/target/fast`, so a Rust change rebuilds in seconds. Releases and
benchmarks (`MIX_ENV=bench`) keep the full release profile in `native/target`.

```sh
mix format --check-formatted lib/valimc/physics/pose_fit.ex test/pose_fit_test.exs
mix test test/pose_fit_test.exs
mix test --stale
```

`mix test --stale` runs only tests whose dependencies changed since the last stale
run. Untrusted-input decoders get StreamData properties (`test/codec_property_test.exs`;
`STREAM_RUNS=5000` for a deeper run). Micro-benchmarks use Benchee (`bench/*.exs`);
scenario benchmarks of a running server stay custom. Each test run uses a private
temporary directory.

Tests that start region owners or player stores run `async: true` with unique
region keys: `Valimc.TestScope.isolate/2` gives the owners of those keys (and
player UUIDs) a private world path or simulation toggle, read through
`Valimc.config/2`, instead of changing app env. Cleanup uses `TestScope.kill/1`,
since a graceful `terminate_child` holds the shared supervisor. Modules stay
`async: false` when they saturate a global worker pool, assert global `Metrics`
or owner counts, assert production latency deadlines, change global clock state,
or drive sockets; the comment under `use ExUnit.Case` says which. When only a few
tests touch global state, they move into a `Module.Serial` module at the end of the
same file, which imports the async module's public helpers and reuses its setup
through `setup {Module, :scope}`, so the rest of the file stays concurrent.
Socket suites whose player ticks only the test drives use `Valimc.TestPlayer`
(`test/support/client.ex`) for the private world, login, clock parking and ticks.

Rust code lives in `native/` (`valimc_core` pure crate, `valimc_nif` Rustler shim,
built by `use Rustler` in `Valimc.Native`). Run `cargo fmt --check` there too.

Vanilla oracles compare Elixir output with the pinned Mojang jar. Run the stages
a change affects, named stages, or every stage in parallel (logs under
`.local/vanilla-checks/`):

```sh
python3 scripts/check_vanilla.py --changed
python3 scripts/check_vanilla.py --changed --list
python3 scripts/check_vanilla.py --only player_fit,player_pose
python3 scripts/check_vanilla.py --only 'worldgen_structure_placement*' --only tcp
python3 scripts/check_vanilla.py --audit
```

`--changed [REV]` runs the stages that the changes since REV (default: the merge
base with `origin/main`), committed or not, can affect, and prints why each was
chosen; with `--list` it only prints them. It follows each stage's scripts, oracle
sources and declared inputs, the facts it compares, and the global inputs (build
files, the runner, the pin), which select everything. For ValiMC's code it uses what
the stage's checks ran: every passing stage records the functions (NIFs included)
its checks executed and the git tree it ran on, in the main checkout's
`.local/oracle-cache/coverage/`. A change selects the stage when it touches one of
those functions, the module that holds them outside a function, a module they need
at compile time, or a `priv/` file such a module reads. When nothing it ran changed
since its record, it is not selected. Without a record, or when its scripts, oracles
or inputs changed since, or when only changes older than REV touched what it ran,
the stage falls back to a static clause-level call graph (from the build's debug
info, following message tags into callbacks), which reaches much more: checks that
start region owners reach most of the server. `tcp` always uses the static graph.
`--only` takes exact stage names, comma-separated or repeated;
only a name with `*`, `?` or `[` is a glob, a name that matches no stage is an error,
and merged stages keep their old names as aliases. `tcp` is the official-codec
session against plain and encrypted servers.

Vanilla's side of a stage is cached by content in the main checkout's
`.local/oracle-cache/`, shared by every worktree: an oracle run's key covers the
pinned jar and libraries, the JDK and its flags, the oracle's source and every
source it names, its arguments and environment variables, the repo files it
declares (`INPUTS` in `vanilla_stages.py`) and the earlier oracle outputs it reads.
Oracles run in a directory holding only their declared inputs, so an undeclared
read fails, and `--audit` fails on a repo path an oracle names but does not
declare. Steps that read ValiMC's output, and every check, always run. Identical
oracle runs within one run happen once. `--no-cache` reruns every oracle;
`VALIMC_ORACLE_CACHE_GB` (default 8) bounds the cache. Classes compile once per
source tree into `.local/oracle-cache/classes/`.

Fact extraction that only feeds comparisons with committed facts (`regen` steps:
the pin, registries, worldgen facts, survival and shape tables, command trees) runs
from the cache; when its key is not cached (a version bump, an extractor change),
the run reports it as not verified, and `--regen` runs it. Small warm stages run in
groups whose checks share one BEAM; a check that fails there reruns alone, and that
result counts (`--no-batch` gives every check its own BEAM). Stages start longest
first from earlier runs' durations (`.local/oracle-cache/timings.json`); the
all-core oracles run one at a time, sized to the cores the other jobs leave. A run
of more than six stages takes a heavy-job slot itself; smaller runs take none.

Register every new `scripts/*Oracle.java` or `scripts/check_*.exs` in
`scripts/vanilla_stages.py` and declare the repo files an oracle reads; `--audit`
fails otherwise. The runner compiles into a private build directory, so editing
code during a run cannot change its result. A worktree without its own
`research/vanilla-bundle`, server jar or JDK uses the main checkout's.

At a milestone boundary, run the broad gate in the background and fix failures:

```sh
mix format --check-formatted
python3 scripts/heavy.py mix test
python3 scripts/check_vanilla.py
MIX_ENV=prod python3 scripts/heavy.py mix release --overwrite
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

The release pin is `priv/version.json` (name, data version, protocol, jar SHA-1),
read by `Valimc.Version` and `scripts/pinned.py`; `research/mojang-version.json`
must name the same release. `prepare_vanilla.py` verifies/extracts the pinned jar; `java_tool.py NAME ARGS`
runs one oracle (all sources compile together, only when changed). Use `javap -c -p`
first. Keep decompiler tools, dumps and raw outputs under ignored `research/` or
`.local/`; record jar/tool hashes and classes/methods in the ticket. Publish no
Mojang code, assets or jars.

## Measurement

Benchmark performance changes with matched workloads. Preserve raw data, revision,
hardware/schedulers, tick time, latency, failures and memory. See
[measurements](performance.md). Optimize measured bottlenecks.
