# VMC-023b: ValiMC's noises return vanilla's samples bit for bit (NoiseOracle):
# registry noises built from the committed noise facts, the legacy nether climate
# noises and blended noise octave sets, at points (3D and 2D) and over volumes.
[samples_path] = System.argv()
cases = (samples_path |> File.read!() |> JSON.decode!())["cases"]
facts = "priv/worldgen/noises.json" |> File.read!() |> JSON.decode!()

double = fn hex ->
  <<value::float-64>> = <<String.to_integer(hex, 16)::64>>
  value
end

normalize = fn
  false -> 0.0
  true -> 1.0
  "legacy" -> 2.0
end

params = fn
  %{"params" => params} ->
    Enum.map(params, double)

  %{"id" => id} ->
    noise = Map.fetch!(facts, id)

    [
      Map.get(noise, "base_amplitude", 1.0),
      noise["base_octave"],
      Map.get(noise, "octave_count", 1),
      normalize.(Map.get(noise, "normalize", true)) | Map.get(noise, "amplitude_modifiers", [])
    ]
    |> Enum.map(&(&1 * 1.0))
end

bits = fn hexes -> Enum.map(hexes, &String.to_integer(&1, 16)) end

{mismatches, compared} =
  Enum.reduce(cases, {[], 0}, fn row, {mismatches, compared} ->
    points =
      row["points"] |> Enum.map(double) |> Enum.chunk_every(3) |> Enum.map(&List.to_tuple/1)

    volumes =
      Enum.map(row["volumes"], &{&1["volume"], double.(&1["xz"]), double.(&1["y"])})

    random = {row["kind"], String.to_integer(row["seed"]), row["source"]}

    {:ok, {actual, actual_2d, actual_volumes}} =
      Valimc.Native.worldgen_noise_samples(random, row["noise"], params.(row), points, volumes)

    expected =
      [bits.(row["results"]), bits.(row["results_2d"])] ++
        Enum.map(row["volumes"], &bits.(&1["values"]))

    found = [actual, actual_2d] ++ actual_volumes
    label = "#{row["noise"]} #{row["id"]} #{row["kind"]} seed #{row["seed"]}"

    bad =
      for {{a, e}, kind} <-
            Enum.zip(found, expected) |> Enum.zip(~w(points points_2d volume volume)),
          {x, y, i} <- Enum.zip([a, e, Stream.iterate(0, &(&1 + 1))]),
          x != y,
          do: {label, kind, i, Integer.to_string(x, 16), Integer.to_string(y, 16)}

    {[bad | mismatches], compared + Enum.sum(Enum.map(expected, &length/1))}
  end)

mismatches = mismatches |> Enum.reverse() |> List.flatten()

if mismatches != [] do
  raise "#{length(mismatches)} of #{compared} noise samples differ; first (noise, path, index, ValiMC, vanilla): " <>
          inspect(hd(mismatches))
end

IO.puts(
  "PASS: #{length(cases)} noises, #{compared} samples (points, 2D points, volumes) equal vanilla's bit for bit"
)
