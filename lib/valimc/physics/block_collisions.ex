defmodule Valimc.Physics.BlockCollisions do
  @moduledoc "Ordered bounded block colliders read from a `Valimc.World.View`."
  alias Valimc.Physics.{
    BlockEntityContext,
    BlockScan,
    BlockShapes,
    Box,
    CollisionContext,
    Shape,
    VoxelOps
  }

  alias Valimc.World.View

  @max_colliders 128

  @doc """
  The colliders of the blocks a box meets, in scan order; dynamic geometry is
  resolved for `context` every time. A cell the view cannot read is an error.
  """
  def collect(box, %View{} = view, context \\ CollisionContext.empty()) do
    with true <- CollisionContext.valid?(context),
         {:ok, positions} <- BlockScan.plan(box),
         {:ok, colliders} <-
           resolve(positions, view, context, view.entities, box, VoxelOps.world_box(box), [], 0) do
      {:ok, %{colliders: colliders}}
    else
      false -> {:error, :invalid_context}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :collision_geometry_limit}
  end

  defp resolve([], _, _, _, _, _, acc, _), do: {:ok, Enum.reverse(acc)}

  defp resolve([{pos, type} | rest], view, context, entities, box, query, acc, count) do
    with {:ok, id} <- state(view, pos),
         {:ok, eligible} <- BlockScan.eligible(id, type) do
      if eligible do
        entity = Map.get(entities, pos, BlockEntityContext.absent())

        case BlockShapes.fetch(id, pos, context, entity) do
          {:ok, shape} ->
            world = Shape.move(shape, pos)

            overlaps =
              cond do
                shape.full_block -> Box.intersects?(box, unit_box(pos))
                Shape.empty?(world) -> false
                true -> VoxelOps.intersects?(world, query)
              end

            cond do
              overlaps and count == @max_colliders ->
                {:error, :collider_limit}

              overlaps ->
                resolve(
                  rest,
                  view,
                  context,
                  entities,
                  box,
                  query,
                  [%{position: pos, state: id, shape: world} | acc],
                  count + 1
                )

              true ->
                resolve(rest, view, context, entities, box, query, acc, count)
            end

          {:context_required, name} ->
            {:error, {:context_required, pos, name}}

          {:error, reason} ->
            {:error, {:block_shape, pos, reason}}
        end
      else
        resolve(rest, view, context, entities, box, query, acc, count)
      end
    end
  end

  defp state(view, pos) do
    case View.fetch(view, pos) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:missing_block, pos}}
    end
  end

  defp unit_box({x, y, z}), do: {x * 1.0, y * 1.0, z * 1.0, x + 1.0, y + 1.0, z + 1.0}
end
