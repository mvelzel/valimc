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

Per commit, format the changed files and run the affected tests:

```sh
mix format --check-formatted lib/valimc/physics/pose_fit.ex test/pose_fit_test.exs
mix test --stale
mix test test/pose_fit_test.exs
```

`mix test.fast` runs everything except the socket suites (`@moduletag :tcp`), in
about 35 seconds. Each test run uses a private temporary directory.

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
