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

if seed = System.get_env("VALIMC_SEED") do
  case Integer.parse(seed) do
    {value, ""} when value >= -9_223_372_036_854_775_808 and value <= 9_223_372_036_854_775_807 ->
      config :valimc, seed: value

    _ ->
      raise "VALIMC_SEED must be a 64-bit integer"
  end
end

if speed = System.get_env("VALIMC_RANDOM_TICK_SPEED") do
  case Integer.parse(speed) do
    {value, ""} when value in 0..4096 -> config :valimc, random_tick_speed: value
    _ -> raise "VALIMC_RANDOM_TICK_SPEED must be an integer in 0..4096"
  end
end
