defmodule Valimc.Physics.BlockCollisions do
  @moduledoc "Ordered bounded colliders from supplied observations; retained fences require later owner validation."
  alias Valimc.Physics.{
    BlockEntityContext,
    BlockOffset,
    BlockScan,
    BlockShapes,
    Box,
    CollisionContext,
    Shape,
    VoxelOps
  }

  @max_observations 16
  @max_colliders 128

  defmodule Frame do
    @moduledoc false
    @enforce_keys [:states, :fences, :entities]
    defstruct [:states, :fences, :entities]
    @opaque t :: %__MODULE__{states: map(), fences: map(), entities: map()}
  end

  @doc "Validate one immutable block sample for repeated geometry queries; its fences still need checking."
  def prepare(observed, entities \\ %{}) do
    with {:ok, states, fences} <- observations(observed, %{}, %{}, %{}, 0),
         :ok <- entities(entities, states),
         do: {:ok, %Frame{states: states, fences: fences, entities: entities}}
  end

  def collect(box, observations, context \\ CollisionContext.empty(), entities \\ %{}) do
    with true <- CollisionContext.valid?(context),
         {:ok, positions} <- BlockScan.plan(box),
         {:ok, frame} <- prepare(observations, entities),
         {:ok, colliders} <-
           resolve(
             positions,
             frame.states,
             context,
             frame.entities,
             box,
             VoxelOps.world_box(box),
             [],
             0
           ) do
      {:ok, %{colliders: colliders, fences: frame.fences}}
    else
      false -> {:error, :invalid_context}
      {:error, _} = error -> error
    end
  rescue
    ArgumentError -> {:error, :collision_geometry_limit}
  end

  @doc "Query a frame returned by prepare/2; dynamic geometry is resolved for this context every time."
  def collect_frame(
        box,
        %Frame{states: states, fences: fences, entities: entities} = frame,
        context
      )
      when map_size(frame) == 4 and is_map(states) and map_size(states) <= 2048 and
             is_map(fences) and map_size(fences) <= 16 and is_map(entities) and
             map_size(entities) <= 512 do
    with true <- CollisionContext.valid?(context),
         {:ok, positions} <- BlockScan.plan(box),
         {:ok, colliders} <-
           resolve(positions, states, context, entities, box, VoxelOps.world_box(box), [], 0) do
      {:ok, %{colliders: colliders, fences: fences}}
    else
      false -> {:error, :invalid_context}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :collision_geometry_limit}
  end

  def collect_frame(_, _, _), do: {:error, :invalid_block_frame}

  defp observations([], states, fences, _, _), do: {:ok, states, fences}

  defp observations(
         [
           %{owner: {pid, epoch} = owner, region: {rx, rz} = key, revision: rev, blocks: blocks}
           | rest
         ],
         states,
         fences,
         owners,
         count
       )
       when count < @max_observations and is_pid(pid) and is_reference(epoch) and
              is_integer(rx) and is_integer(rz) and abs(rx) <= 30_000_000 and
              abs(rz) <= 30_000_000 and
              is_integer(rev) and rev >= 0 and rev <= 9_223_372_036_854_775_807 and is_map(blocks) and
              map_size(blocks) <= 128 do
    fence = %{owner: owner, revision: rev}

    cond do
      Map.has_key?(fences, key) and fences[key] != fence ->
        {:error, {:conflicting_fence, key}}

      Map.has_key?(owners, pid) and owners[pid] != {key, epoch} ->
        {:error, :owner_region_conflict}

      true ->
        with {:ok, states} <- merge_blocks(blocks, key, states),
             do:
               observations(
                 rest,
                 states,
                 Map.put(fences, key, fence),
                 Map.put(owners, pid, {key, epoch}),
                 count + 1
               )
    end
  end

  defp observations(_, _, _, _, _), do: {:error, :invalid_observations}

  defp merge_blocks(blocks, key, states) do
    Enum.reduce_while(blocks, {:ok, states}, fn {pos, id}, {:ok, acc} ->
      result =
        cond do
          not BlockOffset.valid_position?(pos) ->
            {:error, :invalid_block_position}

          region(pos) != key ->
            {:error, {:foreign_block, pos}}

          not is_integer(id) or id < 0 or id >= BlockShapes.state_count() ->
            {:error, {:unknown_block_state, pos}}

          Map.has_key?(acc, pos) and acc[pos] != id ->
            {:error, {:conflicting_block, pos}}

          true ->
            {:ok, Map.put(acc, pos, id)}
        end

      case result do
        {:ok, _} -> {:cont, result}
        {:error, _} -> {:halt, result}
      end
    end)
  end

  defp region({x, _, z}), do: Valimc.World.region_key(Valimc.World.chunk_key(x, z))

  defp entities(entities, states) when is_map(entities) and map_size(entities) <= 512 do
    if Enum.all?(entities, fn {pos, entity} ->
         Map.has_key?(states, pos) and BlockEntityContext.valid?(entity)
       end), do: :ok, else: {:error, :invalid_block_entity_context}
  end

  defp entities(_, _), do: {:error, :invalid_block_entity_context}

  defp resolve([], _, _, _, _, _, acc, _), do: {:ok, Enum.reverse(acc)}

  defp resolve([{pos, type} | rest], states, context, entities, box, query, acc, count) do
    with {:ok, id} <- state(states, pos),
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
                  states,
                  context,
                  entities,
                  box,
                  query,
                  [%{position: pos, state: id, shape: world} | acc],
                  count + 1
                )

              true ->
                resolve(rest, states, context, entities, box, query, acc, count)
            end

          {:context_required, name} ->
            {:error, {:context_required, pos, name}}

          {:error, reason} ->
            {:error, {:block_shape, pos, reason}}
        end
      else
        resolve(rest, states, context, entities, box, query, acc, count)
      end
    end
  end

  defp state(states, pos) do
    case Map.fetch(states, pos) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:missing_block, pos}}
    end
  end

  defp unit_box({x, y, z}), do: {x * 1.0, y * 1.0, z * 1.0, x + 1.0, y + 1.0, z + 1.0}
end
