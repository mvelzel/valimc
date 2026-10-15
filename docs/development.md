# Development workflow

Read [AGENTS.md](../AGENTS.md), [current work](roadmap.md) and the active ticket.
Use [backlog](backlog.md) or [completed index](history/completed.md) only to locate
needed details. Feature-specific evidence belongs in `tickets/VMC-*.md`, not here.

## One slice, targeted checks

1. Define behavior, dependencies, ownership, acceptance criteria and a real-client
   scenario in the ticket. Use [the template](tickets/TEMPLATE.md).
2. Establish the vanilla player experience from pinned codecs/behavior and actual
   clients. Other servers inform design; their internals are not contracts. Freely
   use BEAM concurrency/performance. Record reference revisions and tradeoffs.
3. Implement original bounded Elixir code. Test changed behavior and failure boundaries.
4. Run changed-file formatting, affected tests and relevant native probes. For example:

   ```sh
   mix format --check-formatted lib/valimc/physics/pose_fit.ex test/pose_fit_test.exs
   mix test test/pose_fit_test.exs
   python3 scripts/java_tool.py PlayerFitOracle /tmp/pose-fit.json
   mix run --no-start scripts/check_pose_fit.exs /tmp/pose-fit.json
   ```

5. Review diff and public-tree audit; make a local checkpoint with GUI gates pending.
   Delegate actual client validation and continue the next independent slice.
6. Review its verification report, fix/retest failures, update the queue/ticket
   and publish the validated checkpoint. Never infer a graphical pass from a codec or fixture.

After a larger coherent block, run broader integration once and fix failures:

```sh
mix format --check-formatted
mix test
python3 scripts/check_vanilla.py
MIX_ENV=prod mix release --overwrite
```

Never overwrite a release under client test. Use a separate `MIX_BUILD_PATH` for
an integration build while the tester owns another release. Individual commits
need targeted checks, not this whole block (user instruction, October 15, 2026).
Docs-only edits need relevant link/retrieval checks and baseline client smoke.

## Client handoff

Give the dedicated tester ticket/checkpoint, immutable release, dataset, scenarios
and private evidence paths. It owns CUA and coordinated restarts/fixtures. The
primary works independently and reviews the tester's PASS/FAIL report, checked
actions, failure reasons and limits. The tester owns visual verification; routine
saved screenshots, image hashes and duplicate primary visual checks are unnecessary.
See [client testing](client-testing.md) and [pointer backend](mouse-testing.md).

Test worlds are disposable; preserve journal/counter/receipt consistency within a
dataset. Never restore only a source inventory/counter after destination commit.
Start a fresh whole dataset when resetting recovery tests. Account/launcher
credentials and unrelated resources are outside fixture permission.

## Git

Use direct commits and normal pushes to `main`; no PR/review branch is required.
Before every commit/push:

```sh
python3 scripts/audit_public_tree.py
git diff --check
git diff --cached
```

Stage explicit paths. Local checkpoints may precede GUI validation; retain pending
scenarios and withhold them from publication unless the user explicitly overrides.
Push validated prefixes while later checkpoints remain local. Amend only unpushed
commits; no force-push without permission. Existing published inventory gesture
checkpoints keep their unfinished gates. Report actual push outcomes.

## Private vanilla inspection

`prepare_vanilla.py` verifies/extracts the pinned jar; `java_tool.py` runs original
Java 25+ probes. Use `javap -c -p` first. Keep decompiler tools, dumps/source and
raw outputs under ignored `research/` or `.local/`; record jar/tool hashes and
classes/methods in the ticket. Preserve upstream licenses; publish no Mojang code,
assets or jars. These probes do not launch vanilla or accept its EULA.

## Measurement

Benchmark performance changes with matched workloads/coverage. Preserve raw data,
revision, hardware/schedulers, density, tick work, latency, failures and memory.
See [measurements](performance.md). Optimize measured bottlenecks; define ownership
and recovery before adding native acceleration or clustering.
