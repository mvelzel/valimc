# Light cost of installing generated chunks and of loading a region (VMC-077c),
# over terrain regions of seed 20261020. Each region's 64 chunks are generated
# up front, then installed in batches of four nearest its centre first, as a
# view fills it: per batch the owner's install call (`Blocks.put_columns/2`).
# Then a region load from the 64 column images: the light work it does. The
# script runs against the API before VMC-077c too, for a matched baseline:
# there the region is lit from scratch before the first install (as its first
# chunk request did) and every install relights the region and its ring.
#
#     VALIMC_PORT=0 MIX_ENV=bench mix run bench/light_install.exs OUT.json [regions]
alias Valimc.World.{Blocks, Generator}

[output | rest] = System.argv()
regions = rest |> Enum.at(0, "4") |> String.to_integer()
seed = 20_261_020
size = Valimc.config(:region_size)
Code.ensure_loaded!(Blocks)
per_chunk = function_exported?(Blocks, :new, 4)
now = fn -> System.monotonic_time(:microsecond) end

percentile = fn values, p ->
  sorted = Enum.sort(values)
  Enum.at(sorted, min(length(sorted) - 1, trunc(p * length(sorted))))
end

samples =
  for r <- 1..regions do
    {rx, rz} = key = {r * 7, -r * 5}
    chunks = for x <- 0..(size - 1), z <- 0..(size - 1), do: {rx * size + x, rz * size + z}
    {mx, mz} = {rx * size + size / 2, rz * size + size / 2}
    order = Enum.sort_by(chunks, fn {x, z} -> (x + 0.5 - mx) ** 2 + (z + 0.5 - mz) ** 2 end)
    raw = Generator.columns({:vanilla, seed}, chunks)

    # Lighting each chunk alone happens in the generation job, off the owner.
    {alone_us, images} =
      if per_chunk,
        do: :timer.tc(fn -> Blocks.lit_images(raw, true) end),
        else: {0, raw}

    {:ok, blocks} =
      if per_chunk, do: Blocks.new(key, %{}, %{}, chunks), else: Blocks.new(key)

    unless per_chunk, do: apply(Blocks, :light_compute, [blocks])

    installs =
      for batch <- Enum.chunk_every(order, 4) do
        started = now.()
        {:ok, _} = Blocks.put_columns(blocks, Map.take(images, batch))
        now.() - started
      end

    {load_us, _} =
      :timer.tc(fn ->
        if per_chunk do
          {:ok, _} = Blocks.new(key, %{}, images, [])
        else
          {:ok, loaded} = Blocks.new(key, %{}, images)
          apply(Blocks, :light_compute, [loaded])
        end
      end)

    IO.puts(
      "region #{inspect(key)}: install p50 #{percentile.(installs, 0.5)} µs, " <>
        "max #{Enum.max(installs)} µs; load light #{load_us} µs; " <>
        "alone #{div(alone_us, 64)} µs per chunk"
    )

    %{key: Tuple.to_list(key), install_us: installs, load_us: load_us, alone_us: alone_us}
  end

installs = Enum.flat_map(samples, & &1.install_us)
loads = Enum.map(samples, & &1.load_us)

summary = %{
  install_p50_us: percentile.(installs, 0.5),
  install_p95_us: percentile.(installs, 0.95),
  install_max_us: Enum.max(installs),
  install_total_us_per_region: div(Enum.sum(installs), regions),
  load_p50_us: percentile.(loads, 0.5),
  alone_us_per_chunk: div(Enum.sum(Enum.map(samples, & &1.alone_us)), regions * 64)
}

IO.puts("summary: #{inspect(summary)}")

record = %{
  recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
  revision: System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim(),
  per_chunk_light: per_chunk,
  seed: seed,
  region_size: size,
  load_average: System.cmd("sysctl", ["-n", "vm.loadavg"]) |> elem(0) |> String.trim(),
  summary: summary,
  regions: samples
}

File.mkdir_p!(Path.dirname(output))
File.write!(output, JSON.encode!(record))
