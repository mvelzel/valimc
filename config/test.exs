import Config

config :valimc,
  item_simulation: false,
  cooking_simulation: false,
  port: 0,
  world_path: nil,
  acceptors: 2,
  view_distance: 1

config :logger, level: :warning
