# Run and configure

`config/config.exs` sets runtime bounds/defaults; `config/runtime.exs` reads:

| Variable | Meaning |
|---|---|
| `VALIMC_BIND` | Listen address; default `127.0.0.1` |
| `VALIMC_PORT` | TCP port; default `25565` |
| `VALIMC_WORLD` | Custom preview storage directory; default `world` |
| `VALIMC_GENERATOR` | Terrain of a new world: `flat` (default) or `vanilla`; recorded in its `world.json` |
| `VALIMC_SEED` | Seed of a new vanilla world (64-bit integer); random by default |
| `VALIMC_VIEW_DISTANCE` | Server view distance (`view-distance`, 2..32, default 10): each client gets the distance it requests, at least 2 and at most this |
| `VALIMC_SIMULATION_DISTANCE` | Simulation distance clients are told (`simulation-distance`, 2..32, default 10); regions still simulate every loaded chunk |
| `VALIMC_RESPAWN_RADIUS` | The `respawn_radius` game rule: new players and bedless respawns appear within this many blocks of the world spawn; default 10 |
| `VALIMC_GAME_MODE` | New/legacy player mode: survival, creative, adventure, spectator |
| `VALIMC_ENCRYPTION` | Offline RSA/AES transport test; does not authenticate accounts |
| `VALIMC_ONLINE_MODE` | Mojang account verification; login uses encryption |
| `VALIMC_OPERATORS` | Command operators: comma-separated names added to `ops.json` at startup, or `*` for every player; none by default, everyone under `mix run` in development |
| `VALIMC_WHITE_LIST` | Whether only operators and whitelisted players may join (`false` by default; `/whitelist on` and `off` save their choice in the world) |
| `VALIMC_ENFORCE_WHITELIST` | Whether whitelist changes disconnect players who are no longer listed (`false`) |
| `VALIMC_ACCEPTS_TRANSFERS` | Whether players sent here by `/transfer` on another server may join (`false`) |
| `VALIMC_PLAYER_IDLE_TIMEOUT` | Minutes without a player action before the player is disconnected; `0` (default) is off; `/setidletimeout` saves its own value in the world |
| `VALIMC_CONSOLE` | Whether commands are read from standard input (`true` outside tests) |

Operators get their `ops.json` level (4, `operator_level`, for `/op`) and the
commands of that level; other players get level 0. The world directory holds
vanilla's `ops.json`, `whitelist.json`, `banned-players.json`, `banned-ips.json`
and `usercache.json`. Saved modes take precedence. Non-creative gameplay remains incomplete. Online and
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
