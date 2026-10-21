import Config

config :valimc,
  item_simulation: false,
  cooking_simulation: false,
  port: 0,
  world_path: nil,
  acceptors: 2,
  view_distance: 2,
  # Owners stay loaded unless a test scope lowers this (VMC-077e).
  region_unload_delay_ms: 600_000,
  # A loaded host (parallel suites, other work) can take seconds to answer (VMC-073).
  owner_call_scale: 20,
  # Fixtures expect fresh players at the spawn block.
  respawn_radius: 0,
  region_read_gates: true,
  full_fsync: false,
  overload_kill_ms: 200,
  operators: :all

config :logger, level: :warning
config :stream_data, max_runs: String.to_integer(System.get_env("STREAM_RUNS", "100"))
