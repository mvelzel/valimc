# VMC-053o: `/locate structure` finds what vanilla's `findNearestMapStructure`
# finds (LocateOracle): per seed, position and target (every structure and
# structure tag, tags through ValiMC's own command facts), the locate position
# and structure, or nothing.
[cases_path] = System.argv()
cases = cases_path |> File.read!() |> JSON.decode!()

{:ok, _} = Application.ensure_all_started(:crypto)

facts =
  Application.app_dir(:valimc, "priv/commands/facts.json") |> File.read!() |> JSON.decode!()

members = fn
  "#" <> tag -> Map.fetch!(facts["structure_tags"], tag)
  id -> [id]
end

states = :ets.new(:states, [:set])

state = fn seed ->
  case :ets.lookup(states, seed) do
    [{_, state}] ->
      state

    [] ->
      {:ok, state} = Valimc.Worldgen.new(seed)
      :ets.insert(states, {seed, state})
      state
  end
end

{failures, found} =
  Enum.reduce(cases, {[], 0}, fn row, {failures, found} ->
    seed = String.to_integer(row["seed"])
    [x, y, z] = row["pos"]

    {:ok, ours} =
      Valimc.Native.worldgen_structure_locate(
        state.(seed),
        "minecraft:overworld",
        members.(row["target"]),
        {x, y, z},
        100
      )

    ours = with {a, b, c, id} <- ours, do: [a, b, c, id]

    if ours == row["found"],
      do: {failures, found + if(ours, do: 1, else: 0)},
      else: {[{seed, row["pos"], row["target"], want: row["found"], got: ours} | failures], found}
  end)

if failures != [] do
  for failure <- Enum.take(Enum.reverse(failures), 10), do: IO.inspect(failure)
  IO.puts("FAIL: #{length(failures)} of #{length(cases)} locate results differ")
  System.halt(1)
end

IO.puts("PASS: #{length(cases)} locate results equal vanilla's (#{found} found)")
