alias Valimc.Protocol.{EntityPackets, Wire}
[input, output] = System.argv()
cases = input |> File.read!() |> JSON.decode!()
unless length(cases) == 300, do: raise("Incomplete native position observations")

rows =
  Enum.map(cases, fn row ->
    entity = %{
      entity_id: row["id"],
      x: row["x"],
      y: row["y"],
      z: row["z"],
      yaw: row["yaw"],
      pitch: row["pitch"],
      on_ground: row["ground"]
    }

    {id, payload} = EntityPackets.position(entity)
    wire = IO.iodata_to_binary([Wire.varint(id), payload]) |> Base.encode16(case: :lower)
    unless wire == row["wire"], do: raise("Native position differs #{inspect(row)}")
    Map.put(row, "wire", wire)
  end)

File.write!(output, JSON.encode!(rows))

IO.puts(
  "PASS:300 exact native linear position packets, variable IDs, world/float boundaries, rotations and grounded flags."
)
