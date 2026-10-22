defmodule Valimc.Worldgen.Frontier.Runners do
  @moduledoc """
  The closures generation jobs run, anywhere (VMC-077n): terrain makes a
  chunk's cell, a decoration decorates its 3 × 3, a full job makes a final
  cell full, an alone job makes a chunk over fresh terrain of its 3 × 3 with
  only its own decoration, a flat job a flat-layer column. Spilled cells are
  read back from the scratch file by the job that needs them, and a
  decoration hands them back with its result.
  """
  alias Valimc.Native
  alias Valimc.World.Blocks
  alias Valimc.Worldgen.Frontier.{Dependencies, Memory}
  alias Valimc.Worldgen.Generator

  @doc "The closure of `job` (`%{kind, chunk}`) over the state of `f`."
  def runner(f, %{kind: :terrain, chunk: {x, z}}) do
    {worldgen, source, starts} = {f.worldgen, f.source, f.starts}
    fn -> Native.gen_terrain(worldgen, source, starts, x, z) end
  end

  def runner(f, %{kind: :decorate, chunk: center}) do
    {worldgen, source, starts, scratch} = {f.worldgen, f.source, f.starts, f.scratch}
    cells = Enum.map(Dependencies.around(center, 1), &{&1, f.chunks[&1].cell})

    fn ->
      with {:ok, restored} <- load(worldgen, scratch, cells),
           cells = Enum.map(cells, fn {chunk, cell} -> Map.get(restored, chunk, cell) end),
           {:ok, _lenient} <- Native.gen_decorate(worldgen, source, starts, center, cells),
           do: if(restored == %{}, do: :ok, else: {:ok, restored})
    end
  end

  # A spilled cell stays spilled: making it full changes nothing in it.
  def runner(f, %{kind: :full, chunk: chunk}) do
    {worldgen, cell, sky, scratch} = {f.worldgen, f.chunks[chunk].cell, f.sky, f.scratch}

    fn ->
      with {:ok, restored} <- load(worldgen, scratch, [{chunk, cell}]),
           {:ok, full} <-
             Native.gen_full(
               worldgen,
               Map.get(restored, chunk, cell),
               Generator.protocol_biomes()
             ),
           do: {:ok, lit(full, sky)}
    end
  end

  def runner(f, %{kind: :alone, chunk: {x, z} = chunk}) do
    {worldgen, source, structures, sky} = {f.worldgen, f.source, f.starts != nil, f.sky}

    fn ->
      with {:ok, cells} <-
             Native.gen_reference(worldgen, source, {x - 1, z - 1}, 3, [chunk], structures),
           {:ok, full} <-
             Native.gen_full(worldgen, Enum.at(cells, 4), Generator.protocol_biomes()),
           do: {:ok, lit(full, sky)}
    end
  end

  def runner(f, %{kind: :flat, chunk: {x, z}}) do
    {spec, sky} = {f.flat, f.sky}

    fn ->
      {:ok, image} = Native.column_layers_image(spec.layers, spec.biome)

      full = %{
        x: x,
        z: z,
        image: image,
        heights: [],
        block_entities: [],
        block_ticks: [],
        fluid_ticks: [],
        marks: []
      }

      {:ok, lit(full, sky)}
    end
  end

  # The spilled cells among `cells` (`{chunk, cell}`), decoded from the scratch
  # file: `{:ok, %{chunk => cell}}`.
  defp load(worldgen, scratch, cells) do
    Enum.reduce_while(cells, {:ok, %{}}, fn
      {chunk, {:spilled, offset, size}}, {:ok, acc} ->
        with {:ok, bytes} <- Memory.read_spilled(scratch, offset, size),
             {:ok, cell} <- Native.gen_decode(worldgen, bytes) do
          {:cont, {:ok, Map.put(acc, chunk, cell)}}
        else
          error -> {:halt, {:error, {:scratch, error}}}
        end

      _, acc ->
        {:cont, acc}
    end)
  end

  # A full chunk's image with its light alone stored in it (VMC-077c).
  defp lit(full, sky) do
    lit = Blocks.lit_images(%{{full.x, full.z} => full.image}, sky)
    %{full | image: Map.fetch!(lit, {full.x, full.z})}
  end

  @doc "Run a job's closure; a raise is a deterministic error."
  def safe(run) do
    run.()
  rescue
    error -> {:error, {:generation, Exception.message(error)}}
  end
end
