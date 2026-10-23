defmodule Valimc.World.Growth do
  @moduledoc """
  Plants that grow in a group (VMC-039a): crops, pumpkin and melon stems,
  sugar cane, cactus, farmland, saplings and mangrove propagules.

  Their random ticks and bone meal run in the block rules
  (`valimc_core::rules::growth`); this module says which states the native
  sampler hands the rules (the randomly ticking states of those blocks, from
  `priv/physics/random_ticking.json`) and what a farmland's tick reads beyond
  its cells: whether it rains at the cell above (`Level.isRainingAt`, from the
  owner's published heights and biomes, only while the weather is wet).
  """
  use Valimc.Data.Facts, "physics/random_ticking.json"
  use Valimc.Data.Facts, file: "physics/growth.json", as: :growth_facts

  alias Valimc.Data.{Blocks, Grid}
  alias Valimc.World.{BoxEdit, Climate, Clock, Region, View}
  import Bitwise, only: [<<<: 2]

  @blocks MapSet.new(
            ~w(wheat carrots potatoes beetroots pumpkin_stem melon_stem sugar_cane cactus farmland) ++
              Map.keys(@growth_facts["saplings"])
          )

  @states for [name, first, last] <- @facts["runs"],
              MapSet.member?(@blocks, name),
              state <- first..last,
              do: state

  @growing MapSet.new(@states)
  @farmland Blocks.states("farmland")

  @doc "The randomly ticking states of the growing blocks."
  def states, do: @states

  @doc "Whether `state` is one of them."
  def growing?(state), do: MapSet.member?(@growing, state)

  @doc """
  The rules' random tick actions at `hits` (`[{position, state}]`) in
  `dimension`: `{:random_tick, position, false, rain?}`.
  """
  def random_ticks(_dimension, []), do: []

  def random_ticks(dimension, hits) do
    wet = Clock.weather().wet
    view = View.new(dimension)

    for {position, state} <- hits,
        do:
          {:random_tick, position, false,
           wet and state in @farmland and rain_above?(view, position)}
  end

  # `isRainingAt(pos.above())`: open to the sky, at or above the column's
  # MOTION_BLOCKING height, in a biome where it rains there.
  defp rain_above?(view, {x, y, z}) do
    above = {x, y + 1, z}

    with {:ok, column} <- View.column(view, x, z),
         {:ok, biome} <- View.biome(view, above) do
      y + 1 >= column.sky_source and column.motion_blocking <= y + 1 and
        Climate.precipitation(biome, above, sea_level(view.dimension)) == :rain
    else
      :error -> false
    end
  end

  @doc """
  Grow the trees of the actions whose result asks for one (`outcome` of a
  rules run with `actions`), each in a task.
  """
  def grow(_dimension, _actions, nil), do: :ok

  def grow(dimension, actions, %{results: results}) do
    for {action, 2} <- Enum.zip(actions, results), do: start_tree(dimension, elem(action, 1))
    :ok
  end

  @doc "Grow the tree of the sapling at `position` in a task (`tree/2`)."
  def start_tree(dimension, position) do
    Task.Supervisor.start_child(
      Valimc.TransferWorkers,
      Valimc.World.Dimension.bind(fn -> tree(dimension, position) end)
    )
  catch
    :exit, _ -> :busy
  end

  @doc """
  Grow the tree of the sapling at `position` in `dimension` (synchronously):
  `:ok`, or `{:error, reason}` with nothing changed.
  """
  def tree(dimension, {x, _, z} = position) do
    {cx, cz} = Grid.chunk_key(x, z)
    chunks = for dz <- -1..1, dx <- -1..1, do: {cx + dx, cz + dz}
    seed = :rand.uniform(1 <<< 62)

    with {:ok, {worldgen, source}} <- generator(dimension),
         {:ok, images} <- images(dimension, chunks),
         input = for({cx, cz} = c <- chunks, do: {cx, cz, Map.fetch!(images, c)}),
         {:ok, {:ok, {blocks, entities}}} <-
           Valimc.Worldgen.Pool.run(
             fn ->
               Valimc.Native.worldgen_grow(
                 worldgen,
                 source,
                 Valimc.World.BlockRules.native(),
                 position,
                 input,
                 base(),
                 seed
               )
             end,
             10_000
           ),
         {:ok, entries} <- Valimc.Worldgen.FullChunk.block_entities(entities, %{}) do
      commit(dimension, blocks, entries)
    else
      {:ok, {:ok, nil}} -> {:error, :no_tree}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, _} = error -> error
    end
  end

  # One box edit over every region the tree touches, fenced on the states
  # it replaced, with its block entities (a beehive's bees).
  defp commit(dimension, blocks, entries) do
    edits = for {position, _, new} <- blocks, into: %{}, do: {position, new}
    expected = for {position, old, _} <- blocks, into: %{}, do: {position, old}
    entries = BoxEdit.by_region(entries)
    expected = BoxEdit.by_region(expected)

    parts =
      Map.new(BoxEdit.by_region(edits), fn {key, edits} ->
        {key,
         %{
           edits: edits,
           expected: Map.get(expected, key, %{}),
           entries: Map.get(entries, key, %{})
         }}
      end)

    BoxEdit.commit(dimension, parts)
  end

  # The dimension's generator: its noise generation, or the plains' features
  # for a flat world.
  defp generator(dimension) do
    run = fn fun ->
      case Valimc.Worldgen.Pool.run(fun, 50_000) do
        {:ok, {:ok, state}} -> {:ok, state}
        {:ok, error} -> error
        error -> error
      end
    end

    case Valimc.World.Spec.generation(Valimc.World.Spec.current(), dimension) do
      {:ok, %{kind: :noise} = spec} ->
        with {:ok, state} <-
               run.(fn ->
                 Valimc.Worldgen.Generator.worldgen(spec.seed, spec.noise_settings, spec.facts)
               end),
             do: {:ok, {state, spec.biome_source}}

      _flat ->
        with {:ok, state} <- run.(fn -> Valimc.Worldgen.Generator.worldgen(0) end),
             do: {:ok, {state, "fixed:minecraft:plains"}}
    end
  end

  # Column images by chunk, from the running owners.
  defp images(dimension, chunks) do
    chunks
    |> Enum.group_by(&Grid.region_key/1)
    |> Enum.reduce_while({:ok, %{}}, fn {key, group}, {:ok, images} ->
      with {:ok, owner} <- Valimc.World.existing_owner(Grid.section(dimension, key, :section)),
           {:ok, %{images: read}} <- Region.column_images(owner, group) do
        {:cont, {:ok, Map.merge(images, read)}}
      else
        _ -> {:halt, {:error, :unloaded}}
      end
    end)
  end

  defp base, do: for(y <- Grid.min_y()..Grid.max_y(), do: Valimc.World.Chunk.base(y))

  defp sea_level(:overworld), do: 63
  defp sea_level(dimension), do: Valimc.World.Dimension.facts(dimension).sea_level
end
