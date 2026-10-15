# ValiMC development

Target full Minecraft Java **26.3 / protocol 777** gameplay compatibility in
Elixir/OTP, accepting Paper-compatible differences. The current server is a
creative flat-world preview.

## Start selectively

Read the short [roadmap](docs/roadmap.md), the active ticket and only its relevant
code/references. Consult [development](docs/development.md) for workflow changes;
do not load the whole backlog, completed index or unrelated tickets.
The roadmap is editable planning, not a fixed implementation order.
Keep README small; put feature evidence in its ticket. Use `rg` to retrieve details.

## Correctness and sources

- Use pinned Mojang 26.3 codecs/behavior for protocol/gameplay and Paper as the
  production behavior reference. Paper-compatible differences are acceptable.
  Region/chunk layout, tick scheduling and other runtime internals need no 1:1
  vanilla parity: prioritize measured performance and BEAM concurrency. Pumpkin,
  SteelMC and other rewrites also inform design; verify their incomplete behavior.
- Record revisions/classes and conclusions in the ticket; see
  [research](docs/research.md) and `research/sources.lock.json`. Implement original
  Elixir code, preserve upstream licenses and keep reference sources separate.
- Jars, decompilers/source/dumps, upstream checkouts, logs/captures and test worlds
  stay ignored. Run `/usr/bin/python3 scripts/audit_public_tree.py` before every
  commit/push; review the exact diff too.

## BEAM ownership

- Processes represent ownership, lifecycle or blocking I/O, never individual blocks
  or a copied Java/Rust threading/ECS model. Use pinned asdf Elixir/Erlang and prefer
  the standard library. Follow the user's pnpm-only policy for JavaScript tools.
- Keep connection/session state per socket, mutable simulation with region/domain
  owners, observations in ETS and pure work in bounded pools. Share immutable
  binaries and batch replication. No global gameplay process on the hot path.
- Define tick order, boundaries, transfers, fencing and recovery before parallel
  coupled gameplay. Published observations are not gameplay authority.
- Bound mailboxes, queues, packets/decompression, rates, tasks, regions and socket
  writes. Keep CPU jobs and disk I/O outside sensitive owners.

## Work and verification

- Implement one slice at a time with acceptance criteria and a client scenario
  first. Park automated-verified work awaiting GUI checks; continue independent
  work. Tested dependencies may be used without calling their tickets Done.
- Per commit, run changed-file formatting and affected tests/native probes only.
  Run full tests/native integration and a production build after a larger coherent
  block; fix integration failures. Do not repeat broad checks for every commit
  (user instruction, October 15, 2026). Use meaningful boundary regressions.
- Always delegate actual Minecraft validation to one dedicated testing subagent.
  Only it drives CUA; the primary continues independent work. Hand off exact
  checkpoint/release, dataset, scenarios and evidence paths. Coordinate restarts
  and fixtures; never replace a release under test. Review its report before Done
  or publication; failures become fix/retest tasks.
- Use `mcp__cua_repl`, app `local.valimc.minecraft-client`, Launcher installation
  **ValiMC computer-use test**, Java 26.3. Try even while the Mac is locked; access
  is authorized. Unavailable CUA leaves the gate pending, not the backlog halted.
  Repair the access prerequisite while independent work continues.
- The dedicated SDL pointer backend is mandatory: no modes, fallbacks, backward
  compatibility, desktop-coordinate diagnostics or cursor-position unit tests.
  Validate actual use; keyboard input can still activate the window.
- The test client/world are disposable, including user builds/items/pose. Accounts,
  credentials and unrelated resources are not. Preserve journal/counter/receipt
  consistency; reset the whole dataset rather than one side of a committed transfer.
- Record date/version/actions/results/checks/limits in the ticket; raw evidence
  stays ignored. Native oracles cannot replace graphical tests. Docs/research use
  baseline smoke; feature tests exercise changed behavior and relevant negatives.

## Git and performance

Review diff/audit, update the ticket/current queue, then commit coherent local
checkpoints. Keep pending client work unpushed unless explicitly authorized;
publication never changes an unfinished gate to Done. Existing published pending
inventory gestures retain their gates. Amend only unpushed commits. Use direct
commits and normal pushes to `main`; no PR is required. Never force-push without
permission. Publish validated prefixes while later checkpoints remain local.

Benchmark when performance/measurement changes. Retain raw workload/results,
revision and comparable feature coverage; empty-world or unequal workloads cannot
establish fastest-server status. See [measurements](docs/performance.md).
