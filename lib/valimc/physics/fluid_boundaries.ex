defmodule Valimc.Physics.FluidBoundaries do
  @moduledoc "Pinned flow barriers and support faces; block-entity-dependent faces remain explicit."
  import Bitwise

  alias Valimc.Physics.{
    BlockCollisions.Frame,
    BlockEntityContext,
    BlockShapes,
    CollisionContext,
    VoxelOps
  }

  alias Valimc.Registry.{BlockFacts, Blocks}

  def sturdy?(%Frame{} = frame, pos, direction) when direction in 0..5 do
    with {:ok, id} <- at(frame, pos),
         do: sturdy(frame, pos, id, BlockFacts.boundary(id).context, direction)
  end

  def sturdy?(_, _, _), do: {:error, :invalid_fluid_face}

  defp sturdy(_, _, id, :none, direction),
    do: {:ok, (BlockFacts.sturdy_faces(id) &&& 1 <<< direction) != 0}

  defp sturdy(%Frame{entities: entities}, pos, id, kind, direction) do
    case Map.get(entities, pos, BlockEntityContext.absent()) do
      %{kind: entity} when entity != kind ->
        {:ok, kind == :shulker}

      %BlockEntityContext{kind: :shulker, closed: closed} when is_boolean(closed) ->
        {:ok, closed or direction == bxor(facing(id), 1)}

      %BlockEntityContext{kind: :piston} = entity ->
        with {:ok, shape} <- BlockShapes.fetch(id, pos, CollisionContext.empty(), entity),
             do: {:ok, VoxelOps.face_full?(shape, direction)}

      _ ->
        {:error, :unresolved_fluid_support}
    end
  end

  defp at(%Frame{states: states}, pos) do
    case Map.fetch(states, pos) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :incomplete_fluid_frame}
    end
  end

  @facings ~w(down up north south west east)
  defp facing(id), do: Enum.find_index(@facings, &({"facing", &1} in Blocks.properties(id)))
end
