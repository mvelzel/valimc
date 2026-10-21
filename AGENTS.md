# ValiMC development

Target the full vanilla Minecraft Java **26.3 / protocol 777** player experience on
Elixir/OTP, with Rust NIFs where native code measurably wins. The server is a
creative flat-world preview; the current milestone is **foundations first**
(see the [roadmap](docs/roadmap.md)).

## Start selectively

Read the [roadmap](docs/roadmap.md), the active ticket and only its relevant
code. Consult [development](docs/development.md) for checks and Git,
[architecture](docs/architecture.md) for ownership and the Elixir/Rust boundary.
Do not load the whole backlog, completed index or unrelated tickets; use `rg`.
Standing docs describe the current state in plain prose. They are not changelogs.
Evidence (counts, seeds, runs) belongs in the ticket, never in the roadmap.

## Correctness and sources

- Compatibility means vanilla gameplay and unmodified-client interoperability,
  not matching upstream internals. Pinned Mojang 26.3 behavior is the reference.
  Paper, Pumpkin, SteelMC and others are inspirations, not contracts.
- Prefer generated data (Mojang data reports, the oracle extractors) over
  hand-written tables. One generated fact source per concept.
- Record revisions/classes and conclusions in the ticket; see
  [research](docs/research.md) and `research/sources.lock.json`. Write original code;
  preserve upstream licenses and keep reference sources out of the tree.
- Jars, decompiler output, upstream checkouts, logs/captures and test worlds stay
  ignored. `scripts/audit_public_tree.py` (which also lints docs) runs before every
  commit; review the exact diff too.

## Architecture rules

- Processes represent ownership, lifecycle or blocking I/O, never individual blocks
  or entities. No global gameplay process on a hot path; no unbounded mailbox,
  queue, packet, task pool or write.
- Owners hold dense state; readers use published immutable snapshots (ETS,
  `:persistent_term`, refc binaries). Observations never grant authority.
- Cross-owner effects use the shared transaction and fencing primitives, not a new
  per-feature permit/receipt/transfer set. Define ordering, fencing and recovery.
- Disk and CPU-heavy work run outside sensitive owners; durable writes are batched
  (group commit), never one fsync per gameplay action, and never pause simulation.
- Rust NIFs: pure or resource-owned work only, each call under ~1 ms or on a dirty
  scheduler; state lives in a `ResourceArc` owned by one Elixir process; every NIF
  has Elixir-side parity tests. See [architecture](docs/architecture.md).
- Use the pinned asdf Elixir/Erlang (`.tool-versions`) and rustup's stable Rust (at
  least `rust-version` in `native/Cargo.toml`). Follow the user's pnpm-only policy for
  JavaScript tools.

## Work and verification

- Work milestone by milestone. A ticket is one coherent slice (roughly 300–1,500
  lines), at most two nesting levels below its backlog ID, with acceptance criteria.
  `Status:` is one of Planned, In progress, Foundation, Awaiting client, Done or
  Parked. **Done** means the behavior is live in play; unused building blocks are
  **Foundation**.
- Per commit: format changed files and run the affected tests (`mix test --stale`
  or named files). Use `mix test.fast` (no socket suites) for broader quick checks.
  Run the full `mix test`, `scripts/check_vanilla.py` and a production build at a
  milestone or parent-ticket boundary, in the background, and fix failures.
- Actual-client testing happens at player-visible milestones, not per subticket,
  docs edit or unused foundation. Batch the milestone's scenarios into one handoff.
  Always delegate it to one dedicated tester (Codex: subagent with
  `reasoning_effort: "medium"`, `fork_turns: "none"`; Claude Code: the
  `minecraft-tester` agent) that reads [client testing](docs/client-testing.md) and
  the [pointer guide](docs/mouse-testing.md) first. Only it drives CUA; the primary
  continues independent work and reviews its PASS/FAIL report.
- Launch Java 26.3 with `scripts/minecraft_client.py --evidence
  .local/client-tests/TICKET/run-01` as a tracked background process; it joins only
  local ValiMC by Quick Play with a fresh game directory and the dedicated SDL app
  `local.valimc.minecraft-client`. Reconnect means a fresh launch. Never use the
  Launcher, saved-server list or connection menus; keep the small window. The SDL
  pointer backend is mandatory. Unavailable CUA leaves the gate pending, not the
  backlog halted.
- The test client/world are disposable. Accounts, credentials and unrelated
  resources are not. Preserve journal/receipt consistency; reset a whole dataset
  rather than one side of a committed transfer.

## Git and performance

Review the diff and audit, update the ticket and roadmap, then commit coherent
checkpoints directly to `main`. Push validated work with normal pushes; keep
client-pending player-visible work unpushed unless authorized. Amend only unpushed
commits; never force-push without permission.

Benchmark performance changes with matched workloads and retained raw results; see
[measurements](docs/performance.md). Empty-world or unequal workloads cannot
establish fastest-server status.
