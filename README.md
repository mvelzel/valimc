# ValiMC

A Minecraft Java **26.3 / protocol 777** server written in Elixir/OTP.
The goal is full vanilla compatibility. Today it is a **creative flat-world
preview**; survival gameplay is incomplete. No fastest-server claim is made.

## Run

```sh
asdf install
mix run --no-halt
```

Join `localhost:25565` with Java 26.3. The default is loopback/offline mode.
Elixir 1.20.4 and OTP 29.1.1 are pinned in `.tool-versions`; the runtime has no
JVM, Rust or Hex dependencies. Java 25 is used only by development reference tools.

The preview supports login/encryption/optional online authentication, flat chunks,
creative edits, nearby players, supported inventory transactions and persistence.
Player movement enforcement, survival, crafting, mobs, terrain generation,
lighting, redstone and Anvil storage remain unfinished.
See [compatibility](docs/compatibility.md) for scope and pending validation.

## Develop

Start with [current work](docs/roadmap.md), then the relevant ticket.
[AGENTS.md](AGENTS.md) defines the workflow; [development](docs/development.md)
explains targeted checks and delegated Minecraft validation.

- [Configuration](docs/configuration.md)
- [Ownership and architecture](docs/architecture.md)
- [Reference research](docs/research.md) and [measurements](docs/performance.md)
- [Feature backlog](docs/backlog.md) and [completed checkpoints](docs/history/completed.md)

The Elixir code is original. Reference checkouts, Mojang jars/assets/decompiled
source and private test data stay ignored and are not bundled in the runtime.
