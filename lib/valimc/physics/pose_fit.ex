defmodule Valimc.Physics.PoseFit do
  @moduledoc "Native pose selection from a block view, entity boxes and the border."
  alias Valimc.Physics.{
    BorderSnapshot,
    CollisionContext,
    EntityCollisions,
    Kernel,
    PlayerPose
  }

  alias Valimc.World.View

  def select(
        current,
        intent,
        position,
        context,
        %{blocks: %View{}, entities: _, border: border, subject: subject} = observations
      )
      when map_size(observations) == 4 and is_integer(subject) and subject in 0..2_147_483_647 do
    with true <- CollisionContext.valid?(context) and BorderSnapshot.valid?(border),
         {:ok, _} <- PlayerPose.geometry(current, position) do
      resolve(current, intent, position, context, observations, %{})
    else
      false -> {:error, :invalid_pose_fit_observations}
      error -> error
    end
  end

  def select(_, _, _, _, _), do: {:error, :invalid_pose_fit_observations}

  defp resolve(current, intent, position, context, observations, fits) do
    case PlayerPose.select(current, intent, fits) do
      {:ok, selected, queries} ->
        {:ok, geometry} = PlayerPose.geometry(selected, position)
        {:ok, %{pose: selected, geometry: geometry, fits: fits, queries: queries}}

      {:error, {:missing_fit, pose}} when map_size(fits) < 3 ->
        with {:ok, geometry} <- PlayerPose.geometry(pose, position),
             {:ok, clear} <- clear?(geometry.fit_box, position, context, observations) do
          resolve(current, intent, position, context, observations, Map.put(fits, pose, clear))
        end

      error ->
        error
    end
  end

  # `noCollision` of the pose's box: blocks, collidable entities and the border.
  defp clear?(box, position, context, observations) do
    with {:ok, entities} <-
           EntityCollisions.collect(box, observations.subject, observations.entities),
         {:ok, colliding} <-
           Kernel.colliding?(
             observations.blocks,
             box,
             context,
             Kernel.extra(Enum.map(entities.colliders, & &1.box), observations.border),
             position
           ),
         do: {:ok, not colliding}
  end
end
