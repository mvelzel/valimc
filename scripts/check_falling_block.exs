# VMC-050a2: falling blocks against vanilla's (`FallingBlockOracle`): which
# states they fall into, each tick's motion through the physics kernel, and
# what they do where they land.
alias Valimc.Blocks.FallingBlock
alias Valimc.Data.{BlockFacts, Blocks}
alias Valimc.Physics.Kernel
Valimc.Data.BlockFacts.install!()

[path] = System.argv()
raw = path |> File.read!() |> JSON.decode!()

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

free = for state <- 0..(Blocks.state_count() - 1), FallingBlock.free?(state), do: state

unless free == raw["free"] do
  raise "free states differ: ours not vanilla's #{inspect(Enum.take(free -- raw["free"], 8))}, " <>
          "vanilla's not ours #{inspect(Enum.take(raw["free"] -- free, 8))}"
end

stone = Blocks.default_state("stone")

scene = fn layout ->
  for x <- -8..8, y <- 58..76, z <- -8..8, into: %{} do
    state =
      cond do
        y == 63 and abs(x) <= 6 and abs(z) <= 6 ->
          stone

        layout == 1 and {x, y, z} == {0, 64, 0} ->
          Blocks.default_state("torch")

        layout == 2 and {x, y, z} == {0, 64, 0} ->
          Blocks.default_state("oak_slab")

        layout == 3 and abs(x) <= 1 and abs(z) <= 1 and y in 64..65 ->
          Blocks.default_state("water")

        true ->
          0
      end

    {{x, y, z}, state}
  end
end

directions = [
  {0, 1, 0, :down},
  {0, 0, -1, :south},
  {0, 0, 1, :north},
  {-1, 0, 0, :east},
  {1, 0, 0, :west}
]

for fall <- raw["falls"] do
  block = fall["block"]
  states = scene.(fall["layout"])
  # The start cell keeps its fluid when the block falls (air here).
  states =
    Enum.reduce(
      fall["placed_on_fall"],
      states,
      &Map.put(
        &2,
        &1["position"] |> Enum.map(fn v -> trunc(v) end) |> List.to_tuple(),
        &1["state"]
      )
    )

  view = Valimc.World.View.of(states)

  for tick <- fall["ticks"] do
    b = tick["before"]
    a = tick["after"]

    input =
      {List.to_tuple(b["position"]), List.to_tuple(b["velocity"]), b["on_ground"], false,
       :falling_block}

    {:ok, [{:ok, position, velocity, on_ground, _}]} = Kernel.block_bodies(view, [input], nil)
    expected = List.to_tuple(a["position"])

    # A tick that lands also slows the body before it goes; only its move compares.
    unless position == expected and on_ground == a["on_ground"] and
             (a["removed"] or velocity == List.to_tuple(a["velocity"])) do
      raise "falling block #{block} (layout #{fall["layout"]}) differs at time #{b["time"]}: " <>
              "#{inspect({position, velocity, on_ground})}, vanilla #{inspect(a)}"
    end
  end

  last = List.last(fall["ticks"])["after"]
  {x, y, z} = last["position"] |> Enum.map(&floor/1) |> List.to_tuple()
  cell = Map.fetch!(states, {x, y, z})

  sides =
    for {dx, dy, dz, toward} <- directions do
      neighbour = Map.fetch!(states, {x + dx, y + dy, z + dz})
      {neighbour, BlockFacts.flag?(neighbour, :"sturdy_#{toward}")}
    end

  outcome = FallingBlock.landing(block, cell, Map.fetch!(states, {x, y - 1, z}), sides)

  expected =
    case {fall["placed"], fall["drops"]} do
      # Concrete powder places, then hardens (`onLand`): the last placement holds.
      {[_ | _] = placed, []} -> {:place, List.last(placed)["state"]}
      {[], [_]} -> :drop
    end

  unless outcome == expected do
    raise "falling block #{block} (layout #{fall["layout"]}) lands as #{inspect(outcome)}, vanilla #{inspect(expected)}"
  end
end

IO.puts(
  "PASS: #{length(raw["free"])} free states and #{length(raw["falls"])} falls " <>
    "(motion, landing and drops) equal vanilla's"
)
