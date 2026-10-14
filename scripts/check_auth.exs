defmodule AuthProfileCheck do
  def key(property), do: {property["name"], property["value"], property["signature"]}
end

[path] = System.argv()
lines = File.read!(path) |> String.split("\n", trim: true)

for line <- lines do
  %{"body" => body, "expected" => expected} = :json.decode(line)
  {:ok, actual} = Valimc.Auth.Profile.decode(body, "OracleOne")
  true = Base.encode16(actual.uuid, case: :lower) == expected["uuid"]
  true = actual.name == expected["name"]
  actual_keys = Enum.map(actual.properties, &{&1.name, &1.value, &1.signature}) |> Enum.sort()
  expected_keys = Enum.map(expected["properties"], &AuthProfileCheck.key/1) |> Enum.sort()
  true = actual_keys == expected_keys
end

IO.puts(
  "PASS: #{length(lines)} native hasJoined UUIDs/requested names/exact signed and unsigned properties."
)
