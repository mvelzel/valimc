defmodule Valimc.Physics.PistonShape do
  @moduledoc false
  alias Valimc.Physics.{BlockEntityContext, BlockShapes, CollisionContext, Shape, VoxelOps}
  @path Path.expand("../../../priv/physics/collision_shapes.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @bases Map.new(@facts["piston"]["bases"], fn [id, extended] -> {id, extended} end)
  @heads Map.new(@facts["piston"]["heads"], fn [dir, short, id] -> {{dir, short}, id} end)
  unless map_size(@bases) == 24 and length(@facts["piston"]["bases"]) == 24 and
           Enum.all?(@bases, fn {id, extended} ->
             is_integer(id) and is_integer(extended) and id >= 0 and extended >= 0 and
               id < @facts["state_count"] and extended < @facts["state_count"]
           end),
         do: raise("Invalid piston base facts")

  unless map_size(@heads) == 12 and length(@facts["piston"]["heads"]) == 12 and
           Enum.all?(@heads, fn {{dir, short}, id} ->
             dir in ["down", "up", "north", "south", "west", "east"] and is_boolean(short) and
               is_integer(id) and id >= 0 and id < @facts["state_count"]
           end),
         do: raise("Invalid piston head facts")

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
