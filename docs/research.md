# Source research — 2026-10-13

All eleven checkouts are pinned in `research/sources.lock.json` and downloaded in `research/sources/`. This document records the ideas selected for the Elixir design.

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

SteelMC explicitly describes incomplete survival and emphasizes vanilla parity. Its published terrain benchmark is a specific generation workload; it does not establish overall server performance or predict this Elixir implementation's performance. [SteelMC introduction](https://steelmc.dev/blog/announcement/)

Folia's neighboring-region rules are especially relevant: adjacent simulation cannot safely proceed as unrelated owners. This preview has independent edits and lacks cross-border simulation. Future survival work must resolve that consistency problem, even on the BEAM. [Folia overview](https://docs.papermc.io/folia/reference/overview/)

## Current version evidence

Mojang's manifest identifies **26.3** as the stable Java release on October 13, 2026. The official jar's `version.json` reports network protocol **777**, data version **5023**, and Java **25**. The jar SHA-1 is `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`. The manifest response is saved in `research/mojang-version.json`. [Minecraft 26.3 release](https://www.minecraft.net/en-us/article/minecraft-java-edition-26-3)

`net.minecraft.data.Main --reports` generated the current packet and registry reports. A development-only Java harness enumerated synchronized registry names/entry keys, then a TCP oracle used the official 26.3 codecs to validate the Elixir server. This caught changes in login session IDs, teleport confirmations, section fluid counts, palette storage, light bit sets and entity movement encoding that older libraries did not cover.

The graphical client's first connection exposed an additional gap: packet decoding alone does not check registry dependencies. Known-pack registry entries still need synchronized tags before the client can load dimensions, enchantments and other data. `ProtocolMetadata` now uses Mojang's server-data resource manager and tag loader to resolve 773 vanilla tags across 15 registries, with IDs matching the transmitted registry order. These generated facts are committed in `priv/protocol/tags.json`. The TCP oracle now feeds received registry entries and tags into Mojang's network registry loader; it reproduced the original failure and passes with the corrected tag packet.

Elixir **1.20.4** and Erlang/OTP **29.1.1** were verified against their current release metadata and installed using asdf. The project-local `.tool-versions` selects them without changing the global tool versions. [Elixir release](https://github.com/elixir-lang/elixir/releases/tag/v1.20.4), [OTP release](https://github.com/erlang/otp/releases/tag/OTP-29.1.1)

## Provenance

The references are preserved as independent checkouts with their upstream license files. Pumpkin is GPL-3.0, SteelMC is AGPL-3.0-or-later, and other checkouts document their own terms. Paper/Folia/Spigot are patch-based repositories; generated Mojang gameplay source has not been checked into this project. The committed Elixir implementation uses original code and protocol facts, while reference source, the official jar, generated reports and Java tools stay separate from the runtime/release.
