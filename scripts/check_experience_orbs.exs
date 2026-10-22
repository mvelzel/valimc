[input, output] = System.argv()
raw = JSON.decode!(File.read!(input))
alias Valimc.Protocol.{EntityPackets, Wire}
alias Valimc.Entity.ExperienceOrbs
true = raw["version"] == "26.3"
true = raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"
true = length(raw["splits"]) == 16_458
true = length(raw["entities"]) == 39

for row <- raw["splits"] do
  expected = Map.new(row["groups"], fn {value, count} -> {String.to_integer(value), count} end)
  {:ok, ^expected} = ExperienceOrbs.split(row["amount"])
  true = Enum.sum(Enum.map(expected, fn {value, count} -> value * count end)) == row["amount"]
end

entities =
  Enum.map(raw["entities"], fn row ->
    [x, y, z] = row["position"]

    entity = %{
      entity_id: row["id"],
      uuid: <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>,
      x: x,
      y: y,
      z: z,
      on_ground: false,
      velocity: List.to_tuple(row["velocity"])
    }

    packets = %{
      "spawn" => EntityPackets.spawn_experience_orb(entity),
      "metadata" =>
        EntityPackets.metadata(row["id"], no_gravity: true, experience_value: row["value"]),
      "motion" => EntityPackets.motion(row["id"], entity.velocity),
      "position" => EntityPackets.position(entity),
      "remove" => EntityPackets.remove([row["id"]])
    }

    wires =
      Map.new(packets, fn {name, {id, body}} ->
        {name, Base.encode16(IO.iodata_to_binary([Wire.varint(id), body]), case: :lower)}
      end)

    true = wires == row["wires"]
    Map.put(row, "wires", wires)
  end)

File.write!(output, JSON.encode!(%{entities: entities}))
IO.puts("PASS: 16,458 native XP histograms and 195 exact orb packets; no live orb/pickup claim.")
