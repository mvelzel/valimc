defmodule AuthProfileCheck do
  def key(property), do: {property["name"], property["value"], property["signature"]}
end

[path | output] = System.argv()
lines = File.read!(path) |> String.split("\n", trim: true)

encoded =
  for line <- lines do
    %{"body" => body, "expected" => expected} = :json.decode(line)
    {:ok, actual} = Valimc.Net.Auth.Profile.decode(body, "OracleOne")
    true = Base.encode16(actual.uuid, case: :lower) == expected["uuid"]
    true = actual.name == expected["name"]
    actual_keys = Enum.map(actual.properties, &{&1.name, &1.value, &1.signature}) |> Enum.sort()
    expected_keys = Enum.map(expected["properties"], &AuthProfileCheck.key/1) |> Enum.sort()
    true = actual_keys == expected_keys
    {_, info} = Valimc.Protocol.Packets.player_info(actual)

    login =
      IO.iodata_to_binary([
        actual.uuid,
        Valimc.Protocol.Wire.string(actual.name),
        Valimc.Protocol.Packets.properties(actual.properties),
        <<0::128>>
      ])

    :json.encode(%{
      expected: expected,
      login: Base.encode16(login, case: :lower),
      info: Base.encode16(IO.iodata_to_binary(info), case: :lower)
    })
    |> IO.iodata_to_binary()
  end

if output != [], do: File.write!(hd(output), Enum.join(encoded, "\n") <> "\n")

IO.puts(
  "PASS: #{length(lines)} native hasJoined UUIDs/requested names/exact signed and unsigned properties."
)
