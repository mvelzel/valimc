# VMC-050a: the physics kernel's primed TNT tick against vanilla's
# (`TntTravelOracle`), each tick from vanilla's own state before it.
alias Valimc.Physics.Kernel
alias Valimc.Data.Blocks
Valimc.Data.BlockFacts.install!()

[path] = System.argv()
raw = path |> File.read!() |> JSON.decode!()

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

stone = Blocks.default_state("stone")

world = fn floor, layout ->
  for x <- -14..14, y <- 60..70, z <- -14..14, into: %{} do
    state =
      cond do
        y == 63 and abs(x) <= 12 and abs(z) <= 12 -> floor
        layout == 1 and x == 2 and y in 64..67 and abs(z) <= 12 -> stone
        layout == 2 and y == 66 and abs(x) <= 12 and abs(z) <= 12 -> stone
        true -> 0
      end

    {{x, y, z}, state}
  end
  |> Valimc.World.View.of()
end

views =
  raw["rows"]
  |> Enum.map(&{&1["floor"], &1["layout"]})
  |> Enum.uniq()
  |> Map.new(fn {floor, layout} = key -> {key, world.(floor, layout)} end)

for row <- raw["rows"] do
  b = row["before"]
  a = row["after"]

  input =
    {List.to_tuple(b["position"]), List.to_tuple(b["velocity"]), b["on_ground"], b["no_gravity"],
     :tnt}

  {:ok, [{:ok, position, velocity, on_ground, _}]} =
    Kernel.block_bodies(views[{row["floor"], row["layout"]}], [input], nil)

  expected = {List.to_tuple(a["position"]), List.to_tuple(a["velocity"]), a["on_ground"]}

  unless {position, velocity, on_ground} == expected do
    raise "TNT tick differs (floor #{row["floor"]}, layout #{row["layout"]}, tick #{row["tick"]}): " <>
            "#{inspect({position, velocity, on_ground})}, vanilla #{inspect(expected)} from #{inspect(b)}"
  end
end

IO.puts("PASS: #{length(raw["rows"])} primed TNT ticks equal vanilla's")
