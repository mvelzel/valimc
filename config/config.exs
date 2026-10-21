import Config

config :valimc,
  ip: {127, 0, 0, 1},
  port: 25565,
  acceptors: 8,
  max_connections: 2048,
  max_players: 512,
  max_regions: 1024,
  # server.properties `view-distance` (2..32): clients track the distance they
  # request, at least 2 and at most this (VMC-070). `simulation-distance` is what
  # clients are told; regions still simulate every loaded chunk.
  view_distance: 10,
  simulation_distance: 10,
  region_size: 8,
  item_simulation: true,
  cooking_simulation: true,
  world_path: "world",
  # Terrain of new worlds (VMC-024d): :flat or :vanilla (overworld noise terrain
  # for `seed`, random when nil). Existing worlds keep the generator in their
  # world.json.
  generator: :flat,
  seed: nil,
  player_save_interval_ms: 30_000,
  motd: "ValiMC · Elixir/OTP · 26.3 development server",
  max_packet_bytes: 2_097_152,
  max_mailbox: 256,
  # Overloaded connections stop gracefully; a stuck one is killed after this delay.
  overload_kill_ms: 5_000,
  store_checkpoint_bytes: 32 * 1024 * 1024,
  # Region tick behaviours (VMC-066) and whether owners tick on a timer or by `Region.step/2`.
  tick_behaviours: [],
  region_ticks: :timer,
  # The vanilla `randomTickSpeed` gamerule: random ticks per section per game tick.
  random_tick_speed: 3,
  # The vanilla `respawn_radius` gamerule: new players and respawns without a bed
  # appear within this many blocks of the world spawn (VMC-027e).
  respawn_radius: 10,
  # macOS `fsync` stops at the drive cache; flush through it (F_FULLFSYNC).
  full_fsync: match?({:unix, :darwin}, :os.type()),
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
  session_service: Valimc.Auth.SessionService,
  discovery_service: Valimc.Auth.DiscoveryFetch,
  authentication_workers: 32,
  authentication_timeout_ms: 5000,
  crypto_workers: 32,
  key_exchange_timeout_ms: 5000,
  max_write_batch_bytes: 4_194_304,
  login_timeout_ms: 15_000,
  keepalive_interval_ms: 10_000,
  keepalive_timeout_ms: 30_000

config :logger, :console, format: "$time $metadata[$level] $message\n"
import_config "#{config_env()}.exs"
