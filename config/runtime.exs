import Config

case System.get_env("VALIMC_GAME_MODE") do
  nil -> :ok
  "survival" -> config :valimc, default_game_mode: :survival
  "creative" -> config :valimc, default_game_mode: :creative
  "adventure" -> config :valimc, default_game_mode: :adventure
  "spectator" -> config :valimc, default_game_mode: :spectator
  _ -> raise "VALIMC_GAME_MODE must be survival, creative, adventure or spectator"
end

case System.get_env("VALIMC_ONLINE_MODE") do
  nil -> :ok
  "true" -> config :valimc, online_mode: true
  "false" -> config :valimc, online_mode: false
  _ -> raise "VALIMC_ONLINE_MODE must be true or false"
end

case System.get_env("VALIMC_ENCRYPTION") do
  nil -> :ok
  "true" -> config :valimc, encrypt_login: true
  "false" -> config :valimc, encrypt_login: false
  _ -> raise "VALIMC_ENCRYPTION must be true or false"
end

case System.get_env("VALIMC_OPERATORS") do
  nil ->
    :ok

  "*" ->
    config :valimc, operators: :all

  names ->
    config :valimc, operators: names |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

for {variable, key} <- [
      {"VALIMC_WHITE_LIST", :white_list},
      {"VALIMC_ENFORCE_WHITELIST", :enforce_whitelist},
      {"VALIMC_ACCEPTS_TRANSFERS", :accepts_transfers},
      {"VALIMC_CONSOLE", :console},
      {"VALIMC_RCON", :rcon},
      {"VALIMC_BROADCAST_RCON_TO_OPS", :broadcast_rcon_to_ops}
    ] do
  case System.get_env(variable) do
    nil -> :ok
    "true" -> config :valimc, [{key, true}]
    "false" -> config :valimc, [{key, false}]
    _ -> raise "#{variable} must be true or false"
  end
end

if port = System.get_env("VALIMC_RCON_PORT") do
  config :valimc, rcon_port: String.to_integer(port)
end

if password = System.get_env("VALIMC_RCON_PASSWORD") do
  config :valimc, rcon_password: password
end

if minutes = System.get_env("VALIMC_PLAYER_IDLE_TIMEOUT") do
  config :valimc, player_idle_timeout: String.to_integer(minutes)
end

if port = System.get_env("VALIMC_PORT") do
  config :valimc, port: String.to_integer(port)
end

if ip = System.get_env("VALIMC_BIND") do
  {:ok, address} = :inet.parse_address(String.to_charlist(ip))
  config :valimc, ip: address
end

if path = System.get_env("VALIMC_WORLD") do
  config :valimc, world_path: path
end

case System.get_env("VALIMC_GENERATOR") do
  nil -> :ok
  "flat" -> config :valimc, generator: :flat
  "vanilla" -> config :valimc, generator: :vanilla
  _ -> raise "VALIMC_GENERATOR must be flat or vanilla"
end

if level_type = System.get_env("VALIMC_LEVEL_TYPE") do
  config :valimc, level_type: level_type
end

if generator_settings = System.get_env("VALIMC_GENERATOR_SETTINGS") do
  config :valimc, generator_settings: generator_settings
end

case System.get_env("VALIMC_GENERATE_STRUCTURES") do
  nil -> :ok
  "true" -> config :valimc, generate_structures: true
  "false" -> config :valimc, generate_structures: false
  _ -> raise "VALIMC_GENERATE_STRUCTURES must be true or false"
end

if budget = System.get_env("VALIMC_OPEN_FILES_BUDGET") do
  case Integer.parse(budget) do
    {value, ""} when value > 0 -> config :valimc, open_files_budget: value
    _ -> raise "VALIMC_OPEN_FILES_BUDGET must be a positive integer"
  end
end

if seed = System.get_env("VALIMC_SEED") do
  case Integer.parse(seed) do
    {value, ""} when value >= -9_223_372_036_854_775_808 and value <= 9_223_372_036_854_775_807 ->
      config :valimc, seed: value

    _ ->
      raise "VALIMC_SEED must be a 64-bit integer"
  end
end

for {variable, key} <- [
      {"VALIMC_VIEW_DISTANCE", :view_distance},
      {"VALIMC_SIMULATION_DISTANCE", :simulation_distance}
    ],
    distance = System.get_env(variable) do
  case Integer.parse(distance) do
    {value, ""} when value in 2..32 -> config :valimc, [{key, value}]
    _ -> raise "#{variable} must be an integer in 2..32"
  end
end

if radius = System.get_env("VALIMC_RESPAWN_RADIUS") do
  case Integer.parse(radius) do
    {value, ""} when value in 0..2_147_483_647 -> config :valimc, respawn_radius: value
    _ -> raise "VALIMC_RESPAWN_RADIUS must be a non-negative integer"
  end
end

if speed = System.get_env("VALIMC_RANDOM_TICK_SPEED") do
  case Integer.parse(speed) do
    {value, ""} when value in 0..4096 -> config :valimc, random_tick_speed: value
    _ -> raise "VALIMC_RANDOM_TICK_SPEED must be an integer in 0..4096"
  end
end
