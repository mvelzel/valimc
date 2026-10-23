defmodule Valimc.Worldgen.Locate do
  @moduledoc """
  Vanilla's `ChunkGenerator.findNearestMapStructure` in a dimension of the
  current world (`Native.worldgen_structure_locate`, up to 100 grid rings),
  as a generation pool job, never the caller's own dirty call. `/locate
  structure` (VMC-053o) and eyes of ender (VMC-026d) ask it.
  """

  @doc """
  The nearest start of the structures `members` from block `pos` in
  `dimension`: `{:ok, {x, y, z, id}}` or `{:ok, nil}`. A world created without
  structures (`generate-structures`) is `{:error, :no_structures}`, a
  dimension without noise generation `{:error, :flat}`, a failed search
  `{:error, reason}`.
  """
  def nearest(dimension, members, {_, _, _} = pos) do
    world = Valimc.World.Spec.current()

    with true <- Valimc.World.Spec.structures?(world) || {:error, :no_structures},
         {:ok, %{kind: :noise} = spec} <- Valimc.World.Spec.generation(world, dimension) do
      search = fn ->
        {:ok, state} =
          Valimc.Worldgen.Generator.worldgen(spec.seed, spec.noise_settings, spec.facts)

        Valimc.Native.worldgen_structure_locate(state, spec.biome_source, members, pos, 100)
      end

      case Valimc.Worldgen.Pool.run(search, 50_000) do
        {:ok, {:ok, found}} -> {:ok, found}
        {:ok, other} -> {:error, other}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_structures} -> {:error, :no_structures}
      _ -> {:error, :flat}
    end
  end
end
