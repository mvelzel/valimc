# ValiMC development instructions

Build a Minecraft Java 26.3 (protocol 777) survival server in Elixir/OTP. This is
currently a creative flat-world preview, not a finished survival implementation.
Read `README.md`, `docs/roadmap.md`, `docs/development.md`, and the active ticket
under `docs/tickets/` before changing behavior. Keep these records updated.

## Behavior and research

- Mojang's pinned 26.3 implementation and actual vanilla-client behavior define
  compatibility. Use its codecs, bytecode, or private decompiled source as needed.
  An alternative server's implementation is not proof of correctness.
- Paper is a useful compatibility/edge-case reference; distinguish its deliberate
  behavior changes from vanilla. Pumpkin, SteelMC, and other servers provide
  architectural ideas and have incomplete feature coverage.
- Consult `docs/research.md` and `research/sources.lock.json`. Record source
  revisions/classes and design conclusions in tickets. Preserve upstream licenses;
  implement original Elixir code rather than copying reference sources.
- Keep upstream checkouts, Mojang jars, dumps, decompiled source, decompiler tools,
  client logs/captures and test worlds in ignored paths. Run
  `python3 scripts/audit_public_tree.py` before every commit/push.

## BEAM architecture

- Use processes for ownership, independent lifecycle, supervision, or blocking
  I/O; do not create one per block or copy Rust ECS/Java threading arrangements.
- Keep socket/session state per connection, mutable simulation inside region
  owners, published observations in ETS, and pure CPU jobs in bounded worker pools.
  Share immutable binaries and batch network replication.
- Define tick order, boundaries, transfers, fencing, and recovery before
  parallelizing coupled gameplay. Eventually consistent replication is not
  authoritative gameplay state. No global gameplay GenServer on the hot path.
- Bound mailboxes, queues, packet/decompression sizes, rates, tasks, loaded
  regions, and socket writes. Keep CPU work and disk I/O out of sensitive owners.
- Use the pinned asdf Elixir/Erlang versions. Prefer the standard library until a
  dependency has a concrete purpose. For any JavaScript tooling follow the user's
  pnpm-only instructions; never create a repository-local pnpm store.

## Tickets, verification, and Git

- Implement one ticket at a time. Park automated-verified checkpoints that await
  manual validation and proceed to the next implementable slice, as the user
  explicitly requested (October 13, 2026). Keep each pending client scenario;
  dependencies may use tested code without claiming that the ticket is Done.
  Split large backlog entries into reviewable slices
  before implementation. Write acceptance criteria and a real-client scenario
  first. Never mark a partially implemented subsystem complete.
- Run `mix format --check-formatted`, `mix test`, and a production release build.
  Add meaningful behavior/failure-boundary regression tests. Protocol changes also
  require `python3 scripts/check_vanilla.py` with Mojang's 26.3 codecs/registry loader.
- Manually test every completed piece through actual Minecraft 26.3 with computer
  use. On this Mac use the `ValiMC computer-use test` Launcher installation and
  app ID `local.valimc.minecraft-client`. Use `mcp__cua_repl` for UI actions.
- Record date, version, actions, observed results, checks, and limitations in the
  ticket. The codec oracle cannot replace a graphical client test. If computer use
  is unavailable, leave the ticket unverified and fix that prerequisite.
- Review the exact diff and public-tree audit, update the roadmap, then make a
  coherent local commit after automated checks. The user explicitly permits local
  checkpoints before manual validation (October 13, 2026). Mark remaining GUI
  checks pending and keep these commits unpushed until client validation passes.
  Unpushed checkpoints may be amended after validation; never rewrite already
  pushed commits without authorization. Use a `codex/` branch; do not merge or
  force-push without authorization. Report actual commit/push outcomes.
- Computer-use validation is paused while the user's MacBook is locked. Continue
  independent code/research/automated work; resume GUI validation only after it
  is unlocked. Do not mark a ticket Done while its required GUI checks remain.
  A paused GUI gate must not halt the broader server implementation backlog.
- Research/docs/workflow pieces use the baseline client smoke scenario. Feature
  pieces must exercise their changed behavior and relevant negative cases.
- Benchmark only when performance/measurement changes. Preserve raw results,
  workload, fingerprint/revision and comparable feature coverage. Never infer
  fastest-server status from empty worlds or unequal workloads.
