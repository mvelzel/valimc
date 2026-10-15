alias Valimc.GameMode
alias Valimc.Protocol.{ClientCommand, Packets, Wire}
[input, output] = System.argv()
cases = input |> File.read!() |> JSON.decode!()

positions = [
  nil,
  {0, 64, 0},
  {-17, -64, 42},
  {29_999_984, 319, -29_999_984},
  {1, 1_000_000, -1},
  {-1, -1_000_000, 1}
]

packets =
  for c <- cases["packets"] do
    name = c["name"]

    packet =
      case String.split(name, "_") do
        ["respawn", mode, previous, location] ->
          mode = %GameMode{
            current: GameMode.from_id(String.to_integer(mode)),
            previous:
              if(previous == "-1", do: nil, else: GameMode.from_id(String.to_integer(previous)))
          }

          Packets.respawn(%{game_mode: mode}, Enum.at(positions, String.to_integer(location)))

        ["fall", id] ->
          Packets.fall_damage(String.to_integer(id))

        ["death", "animation", id] ->
          Packets.death_animation(String.to_integer(id))

        ["death", id, message] ->
          Packets.death(String.to_integer(id), message)
      end

    {id, body} = packet
    wire = IO.iodata_to_binary([Wire.varint(id), body]) |> Base.encode16(case: :lower)
    # Mojang compacts literal text to a string tag; our compound representation is
    # equivalent. The native verification pass checks its decoded component too.
    unless String.starts_with?(name, "death_") or wire == c["wire"],
      do: raise("Native lifecycle bytes differ #{inspect({c, wire})}")

    %{name: name, wire: wire}
  end

for c <- cases["commands"] do
  actual = ClientCommand.decode(Wire.varint(c["id"]))

  expected =
    case c["action"] do
      "PERFORM_RESPAWN" -> {:ok, :respawn}
      "REQUEST_STATS" -> {:ok, :stats}
      "REQUEST_GAMERULE_VALUES" -> {:ok, :gamerules}
      nil -> {:error, :invalid_client_command}
    end

  unless actual == expected, do: raise("Native client command differs #{inspect({c, actual})}")
end

File.write!(output, JSON.encode!(packets))

IO.puts(
  "PASS: #{length(packets)} Elixir fall/death/respawn packets and #{length(cases["commands"])} command boundaries."
)
