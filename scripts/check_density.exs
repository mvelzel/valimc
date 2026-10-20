# VMC-023c: ValiMC's compiled density functions return vanilla's samples bit
# for bit (DensityOracle): every router, aquifer and registry function of every
# noise settings entry, from the committed worldgen facts, over three seeds, at
# points and volumes, through uncached and cached sampling contexts.
[samples_path] = System.argv()
cases = (samples_path |> File.read!() |> JSON.decode!())["cases"]
facts = fn name -> "priv/worldgen/#{name}.json" |> File.read!() |> JSON.decode!() end

{:ok, registry} =
  Valimc.Native.worldgen_registry(
    facts.("noises"),
    facts.("density_functions"),
    facts.("noise_settings")
  )

states =
  cases
  |> Enum.map(&{&1["seed"], &1["settings"]})
  |> Enum.uniq()
  |> Map.new(fn {seed, settings} = key ->
    {:ok, state} = Valimc.Native.worldgen_new(registry, String.to_integer(seed), settings)
    {key, state}
  end)

{mismatches, compared} =
  Enum.reduce(cases, {[], 0}, fn row, {mismatches, compared} ->
    state = Map.fetch!(states, {row["seed"], row["settings"]})

    {:ok, actual} =
      Valimc.Native.worldgen_density_samples(state, row["function"], row["cached"], row["ops"])

    expected =
      Enum.map(row["results"], fn values -> Enum.map(values, &String.to_integer(&1, 16)) end)

    label = "#{row["settings"]} seed #{row["seed"]} #{row["function"]} cached=#{row["cached"]}"

    bad =
      for {{a, e}, op} <- Enum.zip(actual, expected) |> Enum.zip(row["ops"]),
          {x, y, i} <- Enum.zip([a, e, Stream.iterate(0, &(&1 + 1))]),
          x != y,
          do: {label, op, i, Integer.to_string(x, 16), Integer.to_string(y, 16)}

    {[bad | mismatches], compared + Enum.sum(Enum.map(expected, &length/1))}
  end)

mismatches = mismatches |> Enum.reverse() |> List.flatten()

if mismatches != [] do
  by_function =
    mismatches
    |> Enum.frequencies_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(12)

  raise "#{length(mismatches)} of #{compared} density samples differ; first (case, op, index, ValiMC, vanilla): " <>
          "#{inspect(hd(mismatches))}; most affected: #{inspect(by_function)}"
end

IO.puts(
  "PASS: #{length(cases)} density cases (#{map_size(states)} seed and settings pairs), " <>
    "#{compared} samples equal vanilla's bit for bit"
)
