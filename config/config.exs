import Config

config :valimc,
  ip: {127, 0, 0, 1},
  port: 25565,
  acceptors: 8,
  max_connections: 2048,
  max_players: 512,
  max_regions: 1024,
  # Factor on owner call budgets and request deadlines (VMC-073); tests on a loaded
  # host raise it.
  owner_call_scale: 1,
  # server.properties `view-distance` (2..32): clients track the distance they
  # request, at least 2 and at most this (VMC-070). `simulation-distance`: chunks
  # within it of a player (and within its view) tick (VMC-077e).
  view_distance: 10,
  simulation_distance: 10,
  # A region without tickets and work in flight saves and unloads after this long.
  region_unload_delay_ms: 10_000,
  region_size: 8,
  item_simulation: true,
  cooking_simulation: true,
  world_path: "world",
  # Terrain of new worlds (VMC-024d): :flat or :vanilla (overworld noise terrain
  # for `seed`, random when nil). Existing worlds keep the generator in their
  # world.json.
  generator: :flat,
  seed: nil,
  # A new vanilla world's generation settings (VMC-028a), as `server.properties`
  # gives them: `level-type` (a world preset), `generator-settings` (flat
  # settings JSON) and `generate-structures`.
  level_type: "minecraft:normal",
  generator_settings: nil,
  generate_structures: true,
  player_save_interval_ms: 30_000,
  motd: "ValiMC · Elixir/OTP · 26.3 development server",
  max_packet_bytes: 2_097_152,
  max_mailbox: 256,
  # Overloaded connections stop gracefully; a stuck one is killed after this delay.
  overload_kill_ms: 5_000,
  store_checkpoint_bytes: 32 * 1024 * 1024,
  # How long ordinary item motion stays unsaved before its owner checkpoints it.
  item_checkpoint_ms: 1000,
  # Region tick behaviours (VMC-066) and whether owners tick on a timer or by `Region.step/2`.
  tick_behaviours: [],
  region_ticks: :timer,
  # Whether player clocks tick on a timer or only on explicit ticks (tests, VMC-073).
  player_ticks: :timer,
  # The vanilla `randomTickSpeed` gamerule: random ticks per section per game tick.
  random_tick_speed: 3,
  # The vanilla `respawn_radius` gamerule: new players and respawns without a bed
  # appear within this many blocks of the world spawn (VMC-027e).
  respawn_radius: 10,
  # macOS `fsync` stops at the drive cache; flush through it (F_FULLFSYNC).
  full_fsync: match?({:unix, :darwin}, :os.type()),
  # Files the durability logs may hold open at once (VMC-074); nil: half of
  # the raised open-files limit after a reserve, between 8 and 1024.
  open_files_budget: nil,
  packets_per_second: 400,
  bytes_per_second: 4_194_304,
  compression_threshold: 256,
  encrypt_login: false,
  online_mode: false,
  default_game_mode: :creative,
  # Command operators (VMC-053): player names, or :all on a local test server.
  operators: [],
  operator_level: 4,
  # VMC-010a: the whitelist switches (vanilla's `white-list`, which 26.3
  # defaults to true, and `enforce-whitelist`) and `accepts-transfers`.
  white_list: false,
  enforce_whitelist: false,
  accepts_transfers: false,
  # VMC-010g: RCON, off unless enabled and given a password.
  rcon: false,
  rcon_port: 25_575,
  rcon_password: nil,
  rcon_clients: 16,
  broadcast_rcon_to_ops: true,
  # VMC-010f: commands from standard input; off in tests.
  console: config_env() != :test,
  # VMC-010c: minutes without a player action before the idle kick; 0 is off.
  player_idle_timeout: 0,
  session_service: Valimc.Auth.SessionService,
  discovery_service: Valimc.Auth.DiscoveryFetch,
  authentication_workers: 32,
  authentication_timeout_ms: 5000,
  crypto_workers: 32,
  key_exchange_timeout_ms: 5000,
  # How long a login waits for a free key-exchange or authentication slot.
  admission_call_ms: 1000,
  max_write_batch_bytes: 4_194_304,
  login_timeout_ms: 15_000,
  keepalive_interval_ms: 10_000,
  keepalive_timeout_ms: 30_000

config :logger, :console, format: "$time $metadata[$level] $message\n"

# Dev and test builds of the NIF (tests, oracle checks, `iex -S mix`) skip LTO and
# compile in parallel and incrementally into their own target directory, so a
# one-line Rust change rebuilds in seconds. Releases (`prod`) and benchmarks
# (`MIX_ENV=bench`) keep the full release profile of `native/Cargo.toml`.
if config_env() in [:dev, :test] do
  config :valimc, Valimc.Native,
    env: [
      {"CARGO_TARGET_DIR", Path.expand("../native/target/fast", __DIR__)},
      {"CARGO_PROFILE_RELEASE_LTO", "false"},
      {"CARGO_PROFILE_RELEASE_CODEGEN_UNITS", "16"},
      {"CARGO_PROFILE_RELEASE_INCREMENTAL", "true"}
    ]
end

import_config "#{config_env()}.exs"
