defmodule Valimc.Worldgen.Frontier.Runners do
  @moduledoc """
  The closures generation jobs run, anywhere (VMC-077n): terrain makes a
  chunk's cell, a decoration decorates its 3 × 3 (over fresh terrain where
  a chunk of it was handed over), a full job makes a final
  cell full, an alone job makes a chunk over fresh terrain of its 3 × 3 with
  only its own decoration, a flat job a flat-layer column. Spilled cells are
  read back from the scratch file by the job that needs them, and a
  decoration hands them back with its result. A full chunk carries its
  column as a handle (`:column`) besides its image, decoded and checked by
  the job, which its owner and neighbours install without decoding.

  The native work runs on the low-priority background threads (VMC-081c);
  the job's process waits for it.
  """
  alias Valimc.Native
  alias Valimc.World.Blocks
  alias Valimc.Worldgen.Frontier.{Dependencies, Memory}
  alias Valimc.Worldgen.Generator

  @doc "The closure of `job` (`%{kind, chunk}`) over the state of `f`."
  def runner(f, %{kind: :terrain, chunk: {x, z}}) do
    {worldgen, source, starts} = {f.worldgen, f.source, f.starts}

    fn ->
      Native.background(&Native.gen_terrain_background(&1, worldgen, source, starts, x, z))
    end
  end

  # A chunk of the 3 × 3 handed over (no cell) gets fresh terrain in its
  # place, which the decoration writes into and the job then drops.
  def runner(f, %{kind: :decorate, chunk: center}) do
    {worldgen, source, starts, scratch} = {f.worldgen, f.source, f.starts, f.scratch}
    cells = Enum.map(Dependencies.around(center, 1), &{&1, get_in(f.chunks, [&1, :cell])})

    fn ->
      with {:ok, restored} <- load(worldgen, scratch, cells),
           {:ok, stand_ins} <- stand_ins(worldgen, source, starts, cells),
           cells =
             Enum.map(cells, fn {chunk, cell} ->
               Map.get(restored, chunk) || Map.get(stand_ins, chunk, cell)
             end),
           {:ok, _lenient} <-
             Native.background(
               &Native.gen_decorate_background(&1, worldgen, source, starts, center, cells)
             ),
           do: if(restored == %{}, do: :ok, else: {:ok, restored})
    end
  end

  # A spilled cell stays spilled: making it full changes nothing in it.
  def runner(f, %{kind: :full, chunk: chunk}) do
    {worldgen, cell, sky, scratch} = {f.worldgen, f.chunks[chunk].cell, f.sky, f.scratch}
    packet = f.packet

    fn ->
      with {:ok, restored} <- load(worldgen, scratch, [{chunk, cell}]),
           do: full(worldgen, Map.get(restored, chunk, cell), sky, packet)
    end
  end

  def runner(f, %{kind: :alone, chunk: {x, z} = chunk}) do
    {worldgen, source, structures, sky} = {f.worldgen, f.source, f.starts != nil, f.sky}
    packet = f.packet

    fn ->
      with {:ok, cells} <-
             Native.background(
               &Native.gen_reference_background(
                 &1,
                 worldgen,
                 source,
                 {x - 1, z - 1},
                 3,
                 [chunk],
                 structures
               )
             ),
           do: full(worldgen, Enum.at(cells, 4), sky, packet)
    end
  end

  def runner(f, %{kind: :flat, chunk: {x, z}}) do
    {spec, sky, packet} = {f.flat, f.sky, f.packet}

    fn ->
      {:ok, image} = Native.column_layers_image(spec.layers, spec.biome)

      full = %{
        x: x,
        z: z,
        image: image,
        block_entities: [],
        block_ticks: [],
        fluid_ticks: [],
        marks: [],
        entities: []
      }

      with_column(lit(full, sky), packet)
    end
  end

  # Fresh terrain for the chunks among `cells` without one (handed over).
  defp stand_ins(worldgen, source, starts, cells) do
    stand_ins =
      for {{x, z} = chunk, nil} <- cells, into: %{} do
        {:ok, cell} =
          Native.background(&Native.gen_terrain_background(&1, worldgen, source, starts, x, z))

        {chunk, cell}
      end

    {:ok, stand_ins}
  end

  # The spilled cells among `cells` (`{chunk, cell}`), decoded from the scratch
  # file: `{:ok, %{chunk => cell}}`.
  defp load(worldgen, scratch, cells) do
    Enum.reduce_while(cells, {:ok, %{}}, fn
      {chunk, {:spilled, offset, size}}, {:ok, acc} ->
        with {:ok, bytes} <- Memory.read_spilled(scratch, offset, size),
             {:ok, cell} <-
               Native.background(&Native.gen_decode_background(&1, worldgen, bytes)) do
          {:cont, {:ok, Map.put(acc, chunk, cell)}}
        else
          error -> {:halt, {:error, {:scratch, error}}}
        end

      _, acc ->
        {:cont, acc}
    end)
  end

  # A full chunk, its image with its light alone stored in it (VMC-077c).
  defp full(worldgen, cell, sky, packet) do
    biomes = Generator.protocol_biomes()

    with {:ok, full} <-
           Native.background(&Native.gen_full_background(&1, worldgen, cell, biomes, sky)),
         do: with_column(full, packet)
  end

  # Its column decoded and checked here, once, as the owner installs it, and
  # its packet's parts encoded (VMC-081c2).
  # Its post-processing goes frozen (VMC-081k).
  defp with_column(full, packet) do
    {:ok, handle} = Blocks.column_handle(full.image, {:background, {full.x, full.z}, packet})
    {:ok, full |> Map.put(:column, handle) |> Valimc.Worldgen.FullChunk.compact()}
  end

  # A flat column's image lit alone.
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
