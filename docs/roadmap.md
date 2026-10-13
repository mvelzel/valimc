# Vanilla compatibility roadmap

The current deliverable is the infrastructure and creative protocol preview described in README. Completing a survival replacement requires the following measurable stages.

| Stage | Work | Acceptance criterion |
|---|---|---|
| Public network compatibility | Online authentication, session verification, AES stream encryption, full component/registry/tag handling and protocol errors | Official-client login/authentication tests, malformed-input suites and encryption/compression interoperability |
| Player state | Persistent identity, inventory transactions, item components, movement validation, collision, gravity, game modes and respawn | Differential traces against vanilla for movement, inventory and lifecycle events |
| Vanilla storage and generation | Anvil read/write, region/chunk tickets, versioned NBT, biome/noise/structure generation and light propagation | Reproducible block-for-block generation comparisons and vanilla world round trips |
| Survival systems | Mining durations, drops, crafting, hunger, health, combat, mobs, AI and spawning | Deterministic scenario tests with vanilla reference outputs |
| Coupled world simulation | Fluids, redstone, scheduled/random ticks, block entities, explosions and neighbor interactions | Matching outcomes across region boundaries and under different scheduler counts |
| Entity ownership and recovery | Region-authoritative simulation, transfer fencing/epochs, handoffs, persistence and crash recovery | No duplicated/lost entities during transfers, region failure and reconnects |
| Extensibility | Supervised Elixir plugin API, bounded callbacks, permissions and versioned event contracts | Plugin isolation tests and documented mutation permissions |
| Performance qualification | Profiling and matched workload comparisons with vanilla, Paper/Folia, Pumpkin and SteelMC | Repeatable throughput, latency, memory and survival tick-cost measurements on the same hardware |

For concurrency work, prioritize state ownership and batching before adding processes. Keep simulation data dense inside its owner; use worker tasks for pure computation and dedicated processes for blocking I/O. Expand parallel ownership only when boundary interactions and failure semantics are defined.

The existing tick deadlines and benchmark harness are foundations for that work. Present load results measure networking, replication and a trivial flat generator. They cannot be used to claim survival TPS, vanilla parity or fastest-server status.
