# ValiMC

A Minecraft Java **26.3 / protocol 777** server written in Elixir/OTP.
The goal is full vanilla compatibility. Today it generates and serves vanilla
worlds; survival gameplay beyond the player's own body (mobs, combat, most
redstone) is incomplete. No fastest-server claim is made.

## Run

```sh
asdf install
mix deps.get
mix run --no-halt
```

Join `localhost:25565` with Java 26.3. The default is loopback/offline mode.
Elixir 1.20.4 and OTP 29.1.1 are pinned in `.tool-versions`. Building also needs
Rust 1.99+ (rustup's stable toolchain): `mix deps.get && mix compile` builds the `native/` crates
(chunk section storage) through Rustler, a build-time Hex dependency. The built-in
profiler uses Phoenix LiveView with Bandit for local HTTP/WebSockets. Java 25 is
used only by development reference tools; the server has no JVM dependency.

It supports login with encryption and optional online authentication, vanilla
generation of the overworld, the Nether and the End (flat worlds by default),
portals, Anvil import and export, validated movement, survival mining,
placement and block updates, crafting, chests and furnaces, items and
experience orbs, and the vanilla command tree. Mobs, combat, most redstone and
fluids remain unfinished. See [compatibility](docs/compatibility.md) for scope.

## Develop

Start with [current work](docs/roadmap.md), then the relevant ticket.
[AGENTS.md](AGENTS.md) defines the workflow; [development](docs/development.md)
explains targeted checks and delegated Minecraft validation.

- [Configuration](docs/configuration.md)
- [Profiling while playing](docs/profiling.md) with the built-in `/spark` commands
- [Trial hosting on Fly](docs/hosting.md), server terminal and IPv6/proxy access
- [Ownership and architecture](docs/architecture.md)
- [Reference research](docs/research.md) and [measurements](docs/performance.md)
- [Feature backlog](docs/backlog.md) and [completed checkpoints](docs/history/completed.md)

The Elixir code is original. Reference checkouts, Mojang jars/assets/decompiled
source and private test data stay ignored and are not bundled in the runtime.
