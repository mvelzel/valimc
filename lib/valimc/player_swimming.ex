defmodule Valimc.PlayerSwimming do
  @moduledoc "Swimming intent from a fenced geometry frame; the connection owns the committed flag."
  import Bitwise
  alias Valimc.Physics.{FluidContact, PlayerPose, Swimming}

  def sample(player, pose, {x, y, z} = position, frame) do
    previous = Map.get(player, :motion, %Valimc.PlayerMotion{}).swimming
    sprint = (player.input.shared_flags &&& 8) != 0

    cond do
      not sprint or player.abilities.flying or player.game_mode.current == :spectator ->
        {:ok, false}

      previous ->
        with {:ok, geometry} <- PlayerPose.geometry(pose, position),
             {:ok, depths} <- FluidContact.sample(frame, geometry.box),
             do: {:ok, Swimming.next(true, sprint, depths.water > 0, false, false, false)}

      true ->
        feet = {floor(x), floor(y), floor(z)}

        with {:ok, fluid} <- FluidContact.fluid_at(frame, feet) do
          if fluid.kind == :water do
            with {:ok, geometry} <- PlayerPose.geometry(pose, position),
                 {:ok, eyes} <- FluidContact.eyes(frame, geometry.box, geometry.eye),
                 do: {:ok, Swimming.next(false, sprint, true, eyes.water, true, false)}
          else
            {:ok, false}
          end
        end
    end
  end
end
