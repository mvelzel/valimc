defmodule Valimc.Anvil.Import do
  @moduledoc """
  Import a vanilla 26.3 world into a new ValiMC world directory (VMC-021d).

  Every full overworld chunk becomes a column image in its ValiMC region's log
  (`Store.import_columns/3`); chunks of other statuses are left out (ValiMC shows
  flat terrain there until generation exists). The spawn comes from `level.dat`.
  Region files convert in parallel, one bounded task per file. Block entities,
  entities, light, POI and the other dimensions are not imported yet (VMC-021e).

  Run with the server stopped, into a new or empty directory:

      mix valimc.import VANILLA_WORLD VALIMC_WORLD
      bin/valimc eval 'Valimc.Anvil.Import.cli(["VANILLA_WORLD", "VALIMC_WORLD"])'
  """
  alias Valimc.Anvil.{Chunk, RegionFile}
  alias Valimc.{NBT, Native}
  alias Valimc.World.{Schema, Spawn, Store}

  @overworld "dimensions/minecraft/overworld/region"
  @max_errors 20

  @doc "Import `source` into `destination`; returns a report or an error."
  def run(source, destination) do
    started = System.monotonic_time(:millisecond)

    with :ok <- empty(destination),
         {:ok, spawn} <- read_spawn(source),
         {:ok, files} <- region_files(source) do
      converted =
        files
        |> Task.async_stream(&convert/1, ordered: false, timeout: :infinity)
        |> Enum.map(fn {:ok, result} -> result end)

      images = for %{images: images} <- converted, image <- images, do: image
      File.mkdir_p!(destination)

      written =
        images
        |> Enum.group_by(fn {chunk, _} -> Valimc.World.region_key(chunk) end)
        |> Task.async_stream(
          fn {key, columns} ->
            {key, Store.import_columns(destination, key, Map.new(columns))}
          end,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      case for({key, {:error, reason}} <- written, do: {key, reason}) do
        [] ->
          {position, yaw} = spawn
          :ok = Spawn.write(destination, position, yaw)

          {:ok,
           %{
             regions: length(written),
             chunks: length(images),
             skipped:
               Enum.reduce(converted, %{}, &Map.merge(&2, &1.skipped, fn _, a, b -> a + b end)),
             errors: converted |> Enum.flat_map(& &1.errors) |> Enum.take(@max_errors),
             error_count: Enum.sum(Enum.map(converted, &length(&1.errors))),
             spawn: position,
             milliseconds: System.monotonic_time(:millisecond) - started
           }}

        failures ->
          {:error, {:region_writes_failed, failures}}
      end
    end
  end

  defp empty(destination) do
    case File.ls(destination) do
      {:ok, []} -> :ok
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :destination_not_empty}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_spawn(source) do
    with {:ok, bytes} <- File.read(Path.join(source, "level.dat")),
         {:ok, level} <- NBT.read_compressed(bytes, :gzip),
         {:ok, _} <- Schema.check(:level, level),
         {:compound, %{"Data" => {:compound, data}}} <- level,
         {:compound, spawn} <- data["spawn"],
         {:int_array, <<x::signed-32, y::signed-32, z::signed-32>>} <- spawn["pos"] do
      yaw =
        case spawn["yaw"] do
          {:float, <<yaw::float-32>>} -> yaw
          _ -> 0.0
        end

      {:ok, {{x, y, z}, yaw}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_level_dat}
    end
  end

  defp region_files(source) do
    dir = Path.join(source, @overworld)

    case File.ls(dir) do
      {:ok, names} ->
        {:ok,
         for(
           name <- Enum.sort(names),
           match?({:ok, _}, RegionFile.coords(name)),
           do: Path.join(dir, name)
         )}

      {:error, reason} ->
        {:error, {:no_overworld_regions, reason}}
    end
  end

  # One region file: column images of its full chunks, skipped statuses, errors.
  defp convert(path) do
    case RegionFile.chunks(path) do
      {:ok, chunks} ->
        {acc, _cache} =
          Enum.reduce(chunks, {%{images: [], skipped: %{}, errors: []}, %{}}, fn
            {_pos, :absent}, acc ->
              acc

            {pos, {:error, reason}}, {acc, cache} ->
              {%{acc | errors: [{pos, reason} | acc.errors]}, cache}

            {pos, {:ok, bytes}}, {acc, cache} ->
              {result, cache} =
                case NBT.read(bytes) do
                  {:ok, tag} -> Chunk.column(tag, cache)
                  error -> {error, cache}
                end

              {add(acc, pos, result), cache}
          end)

        acc

      {:error, reason} ->
        %{images: [], skipped: %{}, errors: [{path, reason}]}
    end
  end

  defp add(acc, _pos, {:ok, %{chunk: chunk, sections: sections}}) do
    case Native.column_image_of(sections) do
      {:ok, image} -> %{acc | images: [{chunk, image} | acc.images]}
      {:error, reason} -> %{acc | errors: [{chunk, reason} | acc.errors]}
    end
  end

  defp add(acc, _pos, {:skip, status}),
    do: %{acc | skipped: Map.update(acc.skipped, status, 1, &(&1 + 1))}

  defp add(acc, pos, {:error, reason}), do: %{acc | errors: [{pos, reason} | acc.errors]}

  @doc "Command-line entry: prints the report; exits non-zero on failure."
  def cli([source, destination]) do
    Valimc.Protocol.Data.load!()
    Valimc.World.Blocks.init!()

    case run(Path.expand(source), Path.expand(destination)) do
      {:ok, report} ->
        IO.puts(
          "Imported #{report.chunks} chunks into #{report.regions} regions in #{report.milliseconds} ms"
        )

        IO.puts("Skipped (not full): #{inspect(report.skipped)}; errors: #{report.error_count}")
        if report.errors != [], do: IO.puts("First errors: #{inspect(report.errors)}")
        IO.puts("Spawn: #{inspect(report.spawn)}")

      {:error, reason} ->
        IO.puts(:stderr, "Import failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  def cli(_) do
    IO.puts(:stderr, "usage: Valimc.Anvil.Import.cli([vanilla_world, valimc_world])")
    System.halt(2)
  end
end
