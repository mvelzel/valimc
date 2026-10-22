# VMC-026a: the shape updates ValiMC implements in code (fire, soul fire,
# chorus plants and flowers; redstone wire, stairs, fences, bars, panes, walls,
# doors and coral blocks, VMC-025f) equal vanilla's on
# random neighbourhoods
# (`ShapeOracle code`): the new state and the ticks scheduled (position, kind
# and type; proto chunks keep no delays).
[cases_path] = System.argv()
cases = cases_path |> File.read!() |> JSON.decode!() |> Map.fetch!("cases")

{:ok, _} = Application.ensure_all_started(:crypto)

input =
  Enum.map(cases, fn [state, direction, cells | _] ->
    {state, direction, Enum.map(cells, fn [x, y, z, id] -> {x, y, z, id} end)}
  end)

{:ok, outcomes} = Valimc.Native.worldgen_shape_cases(Valimc.Worldgen.registry(), input)

name = fn id -> Valimc.Data.Blocks.name(Valimc.Data.Blocks.block_id(id)) end

vanilla_ticks = fn ticks ->
  ticks
  |> Enum.map(fn tick ->
    [x, y, z, kind, id | _] = tick |> String.split(",") |> Enum.map(&String.to_integer/1)
    {x, y, z, kind == 1, id}
  end)
  |> Enum.sort()
end

failures =
  cases
  |> Enum.zip(outcomes)
  |> Enum.reject(fn {[_, _, _, want, want_ticks], {ours, ticks}} ->
    ours == want and Enum.sort(ticks) == vanilla_ticks.(want_ticks)
  end)
  |> Enum.map(fn {[state, direction | _] = row, outcome} ->
    {name.(state), direction, row, ours: outcome}
  end)

if failures != [] do
  for failure <- Enum.take(failures, 8), do: IO.inspect(failure, limit: 40)

  IO.puts(
    "FAIL: #{length(failures)} of #{length(cases)} shape update cases differ from vanilla's"
  )

  System.halt(1)
end

changed = Enum.count(cases, fn [state, _, _, want, _] -> state != want end)
ticking = Enum.count(cases, fn [_, _, _, _, ticks] -> ticks != [] end)

IO.puts(
  "PASS: #{length(cases)} shape update cases of fire, soul fire, chorus, redstone wire, connecting blocks, doors and coral equal vanilla's " <>
    "(#{changed} change the state, #{ticking} schedule ticks)"
)
