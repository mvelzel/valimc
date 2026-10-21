defmodule Valimc.Physics.PistonShape do
  @moduledoc false
  alias Valimc.Physics.{BlockEntityContext, BlockShapes, CollisionContext, Shape, VoxelOps}
  alias Valimc.Registry.Blocks

  # A retracting base's extended state, and the piston head of each facing and shortness.
  @bases for name <- ~w(piston sticky_piston),
             id <- Blocks.states(name),
             into: %{},
             do:
               {id,
                Blocks.state(name, Map.put(Map.new(Blocks.properties(id)), "extended", "true"))}
  @heads for dir <- ~w(down up north south west east),
             short <- [false, true],
             into: %{},
             do:
               {{dir, short},
                Blocks.state("piston_head", %{"facing" => dir, "short" => "#{short}"})}
  unless map_size(@bases) == 24 and map_size(@heads) == 12, do: raise("Piston states changed")

  @directions %{
    down: {0, -1, 0},
    up: {0, 1, 0},
    north: {0, 0, -1},
    south: {0, 0, 1},
    west: {-1, 0, 0},
    east: {1, 0, 0}
  }
  @opposite %{down: :up, up: :down, north: :south, south: :north, west: :east, east: :west}

  def fetch(piston, position, context) do
    base =
      case {piston.extending, piston.source, Map.get(@bases, piston.moved_state)} do
        {false, true, id} when is_integer(id) ->
          {:ok, shape} = BlockShapes.fetch(id)
          shape

        _ ->
          %Shape{}
      end

    progress = float32(piston.progress)

    movement =
      if piston.extending, do: piston.direction, else: Map.fetch!(@opposite, piston.direction)

    if progress < 1.0 and context.piston_movement == movement do
      {:ok, base}
    else
      short = piston.extending != float32(1.0 - progress) < 0.25

      id =
        if piston.source,
          do: Map.fetch!(@heads, {Atom.to_string(piston.direction), short}),
          else: piston.moved_state

      # Native moved-state lookup uses empty collision context; the block entity
      # at this position is the piston, so it is a confirmed different type.
      with {:ok, moved} <-
             BlockShapes.fetch(id, position, CollisionContext.empty(), BlockEntityContext.other()) do
        offset = if piston.extending, do: float32(progress - 1.0), else: float32(1.0 - progress)

        delta =
          Map.fetch!(@directions, piston.direction)
          |> Tuple.to_list()
          |> Enum.map(&float32(&1 * offset))
          |> List.to_tuple()

        {:ok, VoxelOps.union(base, Shape.move(moved, delta))}
      end
    end
  rescue
    ArgumentError -> {:error, :piston_geometry_limit}
  end

  defp float32(n) do
    <<rounded::float-32>> = <<n::float-32>>
    rounded
  end
end
