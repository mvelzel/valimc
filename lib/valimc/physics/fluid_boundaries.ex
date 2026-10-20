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

  @path Path.expand("../../../priv/physics/fluid_boundaries.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @count 35_723
  unless Valimc.Version.stamped?(@facts) and
           @facts["state_count"] == @count,
         do: raise("Wrong fluid boundary catalog version")

  @properties @facts["properties"]
              |> Enum.map(fn f ->
                valid_facing =
                  if f["context"] == "shulker", do: f["facing"] in 0..5, else: f["facing"] == -1

                unless map_size(f) == 5 and is_boolean(f["blocks_flow"]) and is_boolean(f["ice"]) and
                         is_integer(f["faces"]) and f["faces"] in 0..63 and
                         f["context"] in ["none", "piston", "shulker"] and
                         is_integer(f["facing"]) and f["facing"] in -1..5 and
                         valid_facing,
                       do: raise("Invalid fluid boundary facts")

                %{
                  blocks_flow: f["blocks_flow"],
                  ice: f["ice"],
                  faces: f["faces"],
                  context: String.to_atom(f["context"]),
                  facing: f["facing"]
                }
              end)
              |> List.to_tuple()
  @states Base.decode16!(@facts["states"], case: :lower)
  unless tuple_size(@properties) == 41 and byte_size(@states) == @count and
           Enum.all?(:binary.bin_to_list(@states), &(&1 < tuple_size(@properties))),
         do: raise("Invalid fluid boundary indexes")

  def count, do: @count

  def fetch(id) when is_integer(id) and id >= 0 and id < @count,
    do: {:ok, elem(@properties, :binary.at(@states, id))}

  def fetch(_), do: {:error, :unknown_block_state}

  def sturdy?(%Frame{} = frame, pos, direction) when direction in 0..5 do
    with {:ok, id} <- at(frame, pos),
         {:ok, facts} <- fetch(id),
         do: sturdy(frame, pos, id, facts, direction)
  end

  def sturdy?(_, _, _), do: {:error, :invalid_fluid_face}

  defp sturdy(_, _, _, %{context: :none, faces: mask}, direction),
    do: {:ok, (mask &&& 1 <<< direction) != 0}

  defp sturdy(%Frame{entities: entities}, pos, id, %{context: kind} = facts, direction) do
    case Map.get(entities, pos, BlockEntityContext.unavailable()) do
      %{kind: :unavailable} ->
        {:error, :incomplete_fluid_block_entity}

      %{kind: entity} when entity != kind ->
        {:ok, kind == :shulker}

      %BlockEntityContext{kind: :shulker, closed: closed} when is_boolean(closed) ->
        {:ok, closed or direction == bxor(facts.facing, 1)}

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
end
