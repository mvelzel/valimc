import Config

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
