# Source research

All nineteen checkouts are pinned in `research/sources.lock.json` and downloaded in ignored `research/sources/`. This is a subsystem-oriented survey; a repository's existence, activity, or benchmark is not evidence of vanilla 26.3 completeness. Its pinned README and the implementation paths below were inspected; benchmark claims were not independently reproduced.

| Project | Evidence and useful idea | Elixir application |
|---|---|---|
| [Pumpkin](https://github.com/Pumpkin-MC/Pumpkin) | Separate protocol, world, registry, generation and gameplay crates; explicit incomplete-feature tracking | Keep protocol and gameplay boundaries explicit and test compatibility in stages |
| [SteelMC](https://github.com/Steel-Foundation/SteelMC) | `steel-core/src/player/chunk_sender.rs` uses separate chunk-send pacing and a prepare/encode/commit pipeline; vanilla parity tests and documented workload limits | Bounded immutable encoding jobs, revision checks, acknowledgments and independent vanilla validation |
| [Paper](https://github.com/PaperMC/Paper) | Mature gameplay and plugin surface, performance work within vanilla-derived behavior | Treat behavior compatibility and reproducible regressions as the target, rather than assuming a language rewrite provides parity |
| [Folia](https://github.com/PaperMC/Folia) | Independently ticking regions with exclusive state ownership and explicit cross-region restrictions | Region owners and local deadlines; boundary simulation must be designed before parallel survival |
| [Spigot](https://hub.spigotmc.org/stash/projects/SPIGOT/repos/spigot/browse) | Bukkit/CraftBukkit patch repositories and the established plugin contract | Reference for expected server behavior/API scope; no Java plugin compatibility promised |
| [Minestom](https://github.com/Minestom/Minestom) | `ThreadDispatcherImpl` separates partitions and tickable entities and queues lifecycle updates | Separate lifecycle/admission from frequently updated state and independently scheduled ownership domains |
| [Valence](https://github.com/valence-rs/valence) | Bevy ECS framework and `valence_network/src/byte_channel.rs` byte limits | Bound network work and memory; batch dense data within an owner instead of assigning a process to every block |
| [FerrumC](https://github.com/ferrumc-rs/ferrumc) | Separate network codecs, world chunks and tick/performance modules | Versioned binary codec layer and observable resource counters |
| [MCProtocolLib](https://github.com/GeyserMC/MCProtocolLib) | Typed packet layouts and explicit protocol states; checkout currently targets 26.2 | Comparative reference, while verifying 26.3 changes independently |
| [minecraft-data](https://github.com/PrismarineJS/minecraft-data) | Versioned protocol and game data; 26.3 is listed as protocol 777, while full protocol data lags it | Pin protocol facts and validate current release data rather than reusing older packet layouts |
| [node-minecraft-protocol](https://github.com/PrismarineJS/node-minecraft-protocol) | Example server and configuration/login state handling | Cross-check handshake/configuration flow and keep wire compatibility tests independent |
| [Cuberite](https://github.com/cuberite/cuberite) | C++/Lua Java server; README targets 1.8–1.12.2; `src/WorldStorage/WSSAnvil.h` separates region-file and chunk storage operations | Storage/behavior engineering reference; verify modern NBT schemas and semantics independently |
| [Glowstone](https://github.com/GlowstoneMC/Glowstone) | Ground-up Java/Bukkit implementation; project describes incomplete vanilla/survival coverage and older client targets | Compare subsystem/API boundaries and historical compatibility tests; no current-version authority |
| [MCHPRS](https://github.com/MCHPR/MCHPRS) | Rust 1.20.4 creative redstone specialization; per-plot threads, graph compiler and tests in `crates/redpiler/`; compiled mode restricts edits and optimization can change results | Study dense circuit data/analysis and workload reduction after vanilla tick/order fixtures exist; acceleration needs equivalence checks |
| [Feather](https://github.com/feather-rs/feather) | README says inactive, 1.16.5; `docs/architecture.md` separates reusable world/types, ECS logic and plugin hosting; warns incomplete features distort benchmarks | Historical lessons on dense owner-local entity data and honest workload comparisons, not a Rust ECS port |
| [Go-MC](https://github.com/Tnze/go-mc) | Go protocol/client/server/NBT/region libraries; pinned README advertises 1.21 | Independent small codec/storage reference and useful test-client structure; verify 26.3 layouts against Mojang |
| [Flying Squid](https://github.com/PrismarineJS/flying-squid) | JavaScript ground-up server; `docs/README.md` lists 1.8–1.21, world/movement/edit/Anvil support; modular Prismarine libraries in `package.json` | Study protocol/data separation and integration fixtures; event-loop architecture and feature list do not establish full survival parity |
| [MultiPaper](https://github.com/MultiPaper/MultiPaper) | 1.20.1 Purpur fork/public beta; master grants chunk ticking ownership and routes readers to current owners | Later clustering reference for authoritative ownership vs replicated caches; no distributed master on the initial BEAM gameplay hot path |
| [Dragonfly](https://github.com/df-mc/dragonfly) | Go Bedrock implementation; `server/world/tx.go` explicitly restricts mutations to owner transaction callbacks and orders deferred work | Strong ownership/transaction API inspiration for region mutation boundaries; Bedrock protocol/gameplay differences require separate verification |

## Reference hierarchy and selected inspirations

1. **Protocol/gameplay reference: vanilla 26.3.** Pin its jar hash and inspect relevant codecs/classes, using differential fixtures and client observations. Decompile privately when needed. This does not require copying its runtime internals.
2. **Production engineering: Paper.** Preserve the vanilla player experience while freely optimizing BEAM ownership, region/chunk layout and scheduling. Paper, Pumpkin and SteelMC inform design without imposing internal or plugin compatibility contracts; record meaningful behavior tradeoffs and incomplete coverage.
3. **Parallel ownership: Folia and Dragonfly.** Region constraints and owner transaction APIs are especially relevant to BEAM processes. Adopt explicit ordering/fencing/bounded handoffs, not the source language's locking/thread model. Inspect their actual boundary rules before changing ValiMC's region protocol.
4. **Ground-up implementation structure: SteelMC and Pumpkin.** Study generation, protocol, inventories, pacing, persistence and tests, recording current omissions. Cross-check behavior with vanilla rather than choosing whichever rewrite is easier to port.
5. **Targeted engineering: Cuberite, MCHPRS, Minestom, Go-MC and the Prismarine ecosystem.** Storage, dense redstone representations, scheduling partitions and independent codecs/tests are valuable. Older versions, specialized modes and missing vanilla features restrict what they can prove.
6. **Historical/distributed tradeoffs: Feather, Glowstone, MultiPaper, Valence and FerrumC.** Learn from modularity, work bounds, ownership vs caches and incomplete-server measurements. Clustering and circuit compilation remain later experiments after semantics and failure recovery are tested.

The resulting Elixir design keeps dense simulation state within its region owner, stable connection processes, immutable binary caches, ETS observations, bounded pure workers and supervised I/O. A process is an ownership/lifecycle boundary, not a replacement for every Rust component or Java object. Data locality, packet volume and serial dependencies still need measurement.

SteelMC explicitly describes incomplete survival and emphasizes vanilla parity. Its published terrain benchmark is a specific generation workload; it does not establish overall server performance or predict this Elixir implementation's performance. [SteelMC introduction](https://steelmc.dev/blog/announcement/)

Folia's neighboring-region rules are especially relevant: adjacent simulation cannot safely proceed as unrelated owners. ValiMC applies the same rule at section size: sections whose loaded chunks come near share one group process (VMC-077j). [Folia overview](https://docs.papermc.io/folia/reference/overview/)

## Current version evidence

The pinned Mojang manifest selects Java **26.3**. The official jar's `version.json` reports network protocol **777**, data version **5023**, and Java **25**. The jar SHA-1 is `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`. The manifest response is saved in `research/mojang-version.json`; `priv/version.json` carries the pin for the code (VMC-068). [Minecraft 26.3 release](https://www.minecraft.net/en-us/article/minecraft-java-edition-26-3)

`net.minecraft.data.Main --reports` generated the current packet and registry reports. A development-only Java harness enumerated synchronized registry names/entry keys, then a TCP oracle used the official 26.3 codecs to validate the Elixir server. This caught changes in login session IDs, teleport confirmations, section fluid counts, palette storage, light bit sets and entity movement encoding that older libraries did not cover.

The graphical client's first connection exposed an additional gap: packet decoding alone does not check registry dependencies. Known-pack registry entries still need synchronized tags before the client can load dimensions, enchantments and other data. `ProtocolMetadata` now uses Mojang's server-data resource manager and tag loader to resolve 773 vanilla tags across 15 registries, with IDs matching the transmitted registry order. These generated facts are committed in `priv/protocol/tags.json`. The TCP oracle now feeds received registry entries and tags into Mojang's network registry loader; it reproduced the original failure and passes with the corrected tag packet.

Elixir **1.20.4** and Erlang/OTP **29.1.1** were verified against their current release metadata and installed using asdf. The project-local `.tool-versions` selects them without changing the global tool versions. [Elixir release](https://github.com/elixir-lang/elixir/releases/tag/v1.20.4), [OTP release](https://github.com/erlang/otp/releases/tag/OTP-29.1.1)

## Trigonometry reference

Vanilla takes `Math.sin` and `Math.cos` in a few generation paths (ores, icebergs,
end spikes, fancy oak branches, stronghold rings, the spawn search). `Math` may
differ between JVMs in the last place: this aarch64 HotSpot's intrinsics differ
from `StrictMath` on about 13% of arguments, and a platform's C library differs
from both, which moves a block whenever a coordinate lands on a boundary. The
oracles therefore run with HotSpot's sine and cosine intrinsics disabled
(`scripts/java_tool.py`), so `Math` gives `StrictMath`'s fdlibm results, and
Rust generation uses a port of the same algorithms (`worldgen::java::sin` and
`cos`): generation is the same on every platform and equals vanilla on a JVM
without those intrinsics.

## Provenance

The references are preserved as independent checkouts with their upstream license files. Pumpkin is GPL-3.0, SteelMC is AGPL-3.0-or-later, and other checkouts document their own terms. Paper/Folia/Spigot are patch-based repositories; generated Mojang gameplay source has not been checked into this project. The committed Elixir implementation uses original code and protocol facts, while reference source, the official jar, generated reports and Java tools stay separate from the runtime/release.

## Pumpkin and the Rust boundary

Pumpkin (commit `8c4d18c`, October 2026) targets the same 26.3/777 protocol. Its
crates are GPL-3.0, git-only and pre-1.0, so ValiMC neither depends on nor ports
them. Useful ideas, re-derived from vanilla rather than copied: a codegen-flattened
density-function router with per-chunk caches, stage-by-stage worldgen parity
hashes against vanilla dumps (its MIT-licensed Extractor mod produces such dumps),
homogeneous/heterogeneous section palettes, and Criterion benchmarks for
generation and chunk I/O. Its movement is client-authoritative and its lighting
has no parity tests, so neither is a model for ValiMC. The resulting boundary is
in [architecture](architecture.md#elixir-and-rust).
