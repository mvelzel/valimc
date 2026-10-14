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
