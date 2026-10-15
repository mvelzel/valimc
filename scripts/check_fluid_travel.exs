alias Valimc.Physics.FluidMotion
alias Valimc.{PlayerInput, PlayerKinetics, PlayerMotion}
alias Valimc.Physics.{BlockScan, Box, CollisionQuery, PlayerPose}
[path] = System.argv()
data = path |> File.read!() |> :json.decode()
fields = Map.keys(Map.from_struct(%FluidMotion{})) -- [:kind, :falling]
bits = fn v -> for n <- Tuple.to_list(v), do: <<n::float-64>> end

check = fn c ->
  initial = List.to_tuple(c["initial"])
  resolved = List.to_tuple(c["resolved"])

  facts =
    fields
    |> Map.new(&{&1, Map.fetch!(c, Atom.to_string(&1))})
    |> Map.merge(%{kind: String.to_existing_atom(c["kind"]), falling: elem(initial, 1) <= 0})
    |> then(&struct!(FluidMotion, &1))

  {:ok, result} = FluidMotion.prepare(resolved, facts)
  query = if c["escape_query"], do: List.to_tuple(c["escape_query"])

  unless (query == nil and result.escape_query == nil) or
           (query != nil and result.escape_query != nil and
              bits.(query) == bits.(result.escape_query)),
         do: raise("Native fluid escape query mismatch #{inspect(c)} #{inspect(result)}")

  actual = FluidMotion.finish(result, c["free"])
  expected = List.to_tuple(c["velocity"])

  unless bits.(actual) == bits.(expected),
    do: raise("Native fluid travel mismatch #{inspect(c)} #{inspect(actual)}")

  # The native escape also samples a prospective translated body. Prove the
  # live acquired frame contains every collision candidate for these fixtures.
  if abs(c["old_y"]) <= 1_000_000 do
    {:ok, geometry} = PlayerPose.geometry(:standing, {0.5, c["old_y"], 0.5})

    player = %{
      motion: %PlayerMotion{velocity: initial},
      input: %PlayerInput{},
      yaw: 0.0,
      game_mode: Valimc.GameMode.new(:creative)
    }

    {:ok, envelope} = PlayerKinetics.query_box(geometry.box, player)
    {:ok, acquired} = BlockScan.plan(envelope, CollisionQuery.frame_cell_limit())
    positions = MapSet.new(acquired, &elem(&1, 0))
    {:ok, movement} = BlockScan.plan(Box.expand_towards(geometry.box, initial))

    escape =
      if query do
        moved =
          Box.move(geometry.box, {elem(initial, 0), c["new_y"] - c["old_y"], elem(initial, 2)})

        {:ok, escaped} = BlockScan.plan(Box.move(moved, query))
        escaped
      else
        []
      end

    unless Enum.all?(movement ++ escape, &MapSet.member?(positions, elem(&1, 0))),
      do: raise("Native fluid movement/escape outside acquired frame #{inspect(c)}")
  end

  actual
end

Enum.each(data["cases"], check)

for trace <- data["traces"] do
  Enum.reduce(trace, nil, fn c, previous ->
    if previous != nil and bits.(previous) != bits.(List.to_tuple(c["initial"])),
      do: raise("Broken native fluid trace boundary")

    check.(c)
  end)
end

IO.puts(
  "PASS: #{length(data["cases"])} native fluid travel cases, 3x200 transition traces and live frame coverage within player Y bounds."
)
