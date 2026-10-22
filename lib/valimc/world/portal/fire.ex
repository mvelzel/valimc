defmodule Valimc.World.Portal.Fire do
  @moduledoc """
  Fire a flint and steel or a fire charge sets (VMC-026b2), as vanilla's
  `BaseFireBlock` places it: soul fire on soul fire bases, else fire facing
  the neighbours that can burn when the block below neither burns nor is
  sturdy. Lit inside an empty nether portal frame in the overworld or the
  Nether, the fire opens the portal instead (`BaseFireBlock.onPlace`).
  """
  alias Valimc.Blocks.{PortalBlocks, PortalShape}
  alias Valimc.Data.Blocks, as: Registry

  @faces [
    {"north", {0, 0, -1}},
    {"east", {1, 0, 0}},
    {"south", {0, 0, 1}},
    {"west", {-1, 0, 0}},
    {"up", {0, 1, 0}}
  ]
  @directions [{0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}]

  @doc "The fire state for `pos` (`BaseFireBlock.getState`)."
  def state(read, {x, y, z} = pos) do
    below = read.({x, y - 1, z})

    cond do
      PortalBlocks.soul_fire_base?(below) ->
        Registry.default_state("soul_fire")

      not PortalBlocks.burns?(below) and not PortalBlocks.sturdy_up?(below) ->
        faces =
          Map.new(@faces, fn {face, direction} ->
            {face, to_string(PortalBlocks.burns?(read.(PortalShape.offset(pos, direction, 1))))}
          end)

        Registry.state("fire", faces)

      true ->
        Registry.default_state("fire")
    end
  end

  @doc "Whether fire `state` survives at `pos` (`FireBlock`/`SoulFireBlock.canSurvive`)."
  def survives?(read, {x, y, z} = pos, state) do
    below = read.({x, y - 1, z})

    if Registry.block_id(state) == Registry.id("soul_fire"),
      do: PortalBlocks.soul_fire_base?(below),
      else:
        PortalBlocks.sturdy_up?(below) or
          Enum.any?(@directions, &PortalBlocks.burns?(read.(PortalShape.offset(pos, &1, 1))))
  end

  @doc """
  Whether fire can be set at `pos` by a player facing `facing` (`:north`,
  `:east`, `:south` or `:west`) in `dimension` (`BaseFireBlock.canBePlacedAt`).
  """
  def placeable?(read, pos, facing, dimension, min_y) do
    PortalBlocks.air?(read.(pos)) and
      (survives?(read, pos, state(read, pos)) or portal?(read, pos, facing, dimension, min_y))
  end

  defp portal?(read, pos, facing, dimension, min_y) do
    dimension in [:overworld, :the_nether] and
      Enum.any?(@directions, &PortalBlocks.frame?(read.(PortalShape.offset(pos, &1, 1)))) and
      PortalShape.find_empty(read, pos, preferred(facing), min_y) != :none
  end

  # The axis across the player's facing (`getCounterClockWise().getAxis()`).
  defp preferred(facing) when facing in [:north, :south], do: :x
  defp preferred(facing) when facing in [:east, :west], do: :z

  @doc """
  What setting fire at `pos` leaves (`BaseFireBlock.onPlace`): the portal
  opening of an empty frame there (`{:portal, shape}`, preferring the X
  axis), the fire, or nothing when it cannot survive.
  """
  def ignite(read, pos, dimension, min_y) do
    portal =
      if dimension in [:overworld, :the_nether],
        do: PortalShape.find_empty(read, pos, :x, min_y),
        else: :none

    case portal do
      {:ok, shape} ->
        {:portal, shape}

      :none ->
        fire = state(read, pos)
        if survives?(read, pos, fire), do: {:fire, fire}, else: :none
    end
  end
end
