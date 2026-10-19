# ValiMC development

Target the full vanilla Minecraft Java **26.3 / protocol 777** player experience in
Elixir/OTP. The current server is a
creative flat-world preview.

## Start selectively

Read the short [roadmap](docs/roadmap.md), the active ticket and only its relevant
code/references. Consult [development](docs/development.md) for workflow changes;
do not load the whole backlog, completed index or unrelated tickets.
The roadmap is editable planning, not a fixed implementation order.
Keep README small; put feature evidence in its ticket. Use `rg` to retrieve details.
Standing docs describe the current state, not dated policy changes or a changelog.
Replace superseded instructions; keep checkpoint-specific evidence in tickets.

## Correctness and sources

- Compatibility means vanilla gameplay and unmodified-client interoperability;
  it does not require matching upstream internals or plugin APIs. Use pinned Mojang
  26.3 codecs/behavior as the correctness reference. Paper, Pumpkin, SteelMC and
  other servers are inspirations, not compatibility contracts; verify incomplete
  examples. Freely redesign ownership, regions/chunks, ticks and scheduling around
  Elixir/OTP for measured performance while preserving the vanilla player experience.
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
- Keep connection/session state per socket; choose simulation ownership boundaries
  to suit gameplay and BEAM concurrency, without prescribing an upstream region or
  tick model. Use ETS for observations, bounded pools for pure work, shared immutable
  binaries and batched replication. No global gameplay process on the hot path.
- Define consistency, ordering, transfers, fencing and recovery where gameplay
  crosses owners. Published observations are not gameplay authority.
- Bound mailboxes, queues, packets/decompression, rates, tasks, regions and socket
  writes. Keep CPU jobs and disk I/O outside sensitive owners.

## Work and verification

- Implement one slice at a time with acceptance criteria and a client scenario
  first. Park automated-verified work awaiting GUI checks; continue independent
  work. Tested dependencies may be used without calling their tickets Done.
- Per commit, run changed-file formatting and affected tests/native probes only.
  Run full tests/native integration and a production build after a larger coherent
  block; fix integration failures. Subtickets never count as larger blocks: use a
  parent-ticket or milestone boundary. Run broad checks in the background while
  continuing independent work. Do not repeat them per commit. Use meaningful
  boundary regressions.
- Always delegate actual Minecraft validation to one dedicated testing subagent.
  Use medium reasoning with a focused fresh handoff (Codex: `reasoning_effort:
  "medium"`, `fork_turns: "none"`; Claude Code: the `minecraft-tester` agent).
  Only it drives CUA; the primary continues independent work.
  Hand off exact checkpoint/release, dataset, scenarios and evidence paths. Require
  the tester to read [client testing](docs/client-testing.md) and the
  [pointer guide](docs/mouse-testing.md) before its first input.
  Coordinate restarts and fixtures; never replace a release under test.
- The tester owns actual-client verification and reports PASS/FAIL per scenario,
  checked actions and limits. Failures include reproduction steps, expected versus
  observed behavior, exact checkpoint/dataset and diagnostic logs/traces sufficient
  to debug and retest. The primary reviews the report before Done/publication and
  turns failures into fix/retest tasks; do not duplicate visual verification.
  Use CUA observations as needed. Routine saved screenshots and image hashes are
  unnecessary; save images only for useful failure diagnosis or when requested.
- Launch Java 26.3 directly with `scripts/minecraft_client.py --evidence
  .local/client-tests/TICKET/run-01` as a tracked background process with native
  macOS GUI access. It joins only local ValiMC using Quick Play, a fresh game
  directory and the dedicated SDL app `local.valimc.minecraft-client`. Test in the
  background with the harness tools in [client testing](docs/client-testing.md),
  then interrupt that process and wait for it to shut down its JVM. Reconnect
  means a fresh launch; never use the Launcher, saved-server list or manual
  connection menus. Keep the default small windowed size; do not maximize. Try even while the
  Mac is locked; access is authorized. Unavailable CUA leaves the gate pending,
  not the backlog halted. Repair the prerequisite while independent work continues.
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
