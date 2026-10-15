defmodule Valimc.Physics.PoseFit do
  @moduledoc "Native pose selection from complete supplied occupancy; retained fences are not authority."
  alias Valimc.Physics.{
    BlockCollisions,
    BorderSnapshot,
    CollisionContext,
    EntityCollisions,
    PlayerPose
  }

  def select(
        current,
        intent,
        position,
        context,
        %{blocks: _, block_entities: _, entities: _, border: border, subject: subject} =
          observations
      )
      when map_size(observations) == 5 and is_integer(subject) and subject in 0..2_147_483_647 do
    with true <- CollisionContext.valid?(context) and BorderSnapshot.valid?(border),
         {:ok, _} <- PlayerPose.geometry(current, position) do
      resolve(current, intent, position, context, observations, %{}, %{})
    else
      false -> {:error, :invalid_pose_fit_observations}
      error -> error
    end
  end

  def select(_, _, _, _, _), do: {:error, :invalid_pose_fit_observations}

  defp resolve(current, intent, position, context, observations, fits, fences) do
    case PlayerPose.select(current, intent, fits) do
      {:ok, selected, queries} ->
        {:ok, geometry} = PlayerPose.geometry(selected, position)
        {:ok, %{pose: selected, geometry: geometry, fits: fits, queries: queries, fences: fences}}

      {:error, {:missing_fit, pose}} when map_size(fits) < 3 ->
        with {:ok, geometry} <- PlayerPose.geometry(pose, position),
             {:ok, blocks} <-
               blocks(geometry.fit_box, observations, context),
             {:ok, clear} <- clear?(blocks.colliders, geometry.fit_box, position, observations) do
          resolve(
            current,
            intent,
            position,
            context,
            observations,
            Map.put(fits, pose, clear),
            Map.merge(fences, blocks.fences)
          )
        end

      error ->
        error
    end
  end

  defp blocks(box, %{blocks: %BlockCollisions.Frame{} = frame, block_entities: entities}, context)
       when frame.entities == entities,
       do: BlockCollisions.collect_frame(box, frame, context)

  defp blocks(_, %{blocks: %BlockCollisions.Frame{}}, _),
    do: {:error, :invalid_block_entity_context}

  defp blocks(box, observations, context),
    do: BlockCollisions.collect(box, observations.blocks, context, observations.block_entities)

  defp clear?([_ | _], _, _, _), do: {:ok, false}

  defp clear?([], box, {x, _, z}, observations) do
    with {:ok, result} <-
           EntityCollisions.collect(box, observations.subject, observations.entities) do
      if result.colliders == [],
        do: BorderSnapshot.no_collision?(observations.border, {x, z}, box),
        else: {:ok, false}
    end
  end
end
