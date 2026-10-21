import Config

config :valimc,
  item_simulation: false,
  cooking_simulation: false,
  port: 0,
  world_path: nil,
  acceptors: 2,
  view_distance: 2,
  # Fixtures expect fresh players at the spawn block.
  respawn_radius: 0,
  region_read_gates: true,
  full_fsync: false,
  overload_kill_ms: 200,
  operators: :all

config :logger, level: :warning
config :stream_data, max_runs: String.to_integer(System.get_env("STREAM_RUNS", "100"))
