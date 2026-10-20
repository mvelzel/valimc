# Run and configure

`config/config.exs` sets runtime bounds/defaults; `config/runtime.exs` reads:

| Variable | Meaning |
|---|---|
| `VALIMC_BIND` | Listen address; default `127.0.0.1` |
| `VALIMC_PORT` | TCP port; default `25565` |
| `VALIMC_WORLD` | Custom preview storage directory; default `world` |
| `VALIMC_GENERATOR` | Terrain of a new world: `flat` (default) or `vanilla`; recorded in its `world.json` |
| `VALIMC_SEED` | Seed of a new vanilla world (64-bit integer); random by default |
| `VALIMC_GAME_MODE` | New/legacy player mode: survival, creative, adventure, spectator |
| `VALIMC_ENCRYPTION` | Offline RSA/AES transport test; does not authenticate accounts |
| `VALIMC_ONLINE_MODE` | Mojang account verification; login uses encryption |
| `VALIMC_OPERATORS` | Command operators: comma-separated names, or `*` for every player; none by default, everyone under `mix run` in development |

Operators get permission level 4 (`operator_level`) and vanilla's gamemaster
commands; other players get level 0. Saved modes take precedence. Non-creative gameplay remains incomplete. Online and
offline UUID saves are separate; mode changes do not migrate files. Signed chat,
proxy-IP policy and duplicate-session replacement remain unfinished.

```sh
VALIMC_PORT=25566 VALIMC_WORLD=/tmp/valimc-world mix run --no-halt
iex -S mix
# In IEx: Valimc.Metrics.snapshot()
# Graceful shutdown: System.stop()
```

A release uses `bin/valimc start`, `rpc`, and `stop`. Stop gracefully so dirty
state can save; verify the process/release before shutdown. Do not replace the
release assigned to a tester. Storage failure can prevent the final save.
