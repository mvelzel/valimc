defmodule Valimc.PlayerLanding do
  @moduledoc "Landing observations from the accepted movement frame; only the player owner applies damage."
  import Bitwise
  alias Valimc.{PlayerKinetics, PlayerMotion}
  alias Valimc.Physics.{BlockCollisions, Box, CollisionContext, FluidContact, LandingBlocks}
  @legacy_offset 0.20000000298023224

  def sample(player, target, flags, box, frame) do
    ground = (flags &&& 1) != 0
    dy = target.y - player.y
    moved_box = Box.move(box, {target.x - player.x, dy, target.z - player.z})

    if ground and not player.abilities.flying and (PlayerMotion.distance(player) > 0 or dy < 0) do
      with {:ok, fluid} <- FluidContact.sample(frame, moved_box) do
        {_, landed} =
          PlayerMotion.fall_step(PlayerMotion.distance(player), dy, ground, fluid.water > 0)

        if fluid.water == 0 do
          shift = (player.input.shared_flags &&& 2) != 0

          context =
            CollisionContext.entity(target.y, shift)
            |> CollisionContext.with_entity(PlayerMotion.distance(player), false, false)

          with {:ok, material} <-
                 material(frame, moved_box, {target.x, target.y, target.z}, context),
               do: LandingBlocks.call(material.state, landed, shift)
        else
          {:ok, nil}
        end
      end
    else
      {:ok, nil}
    end
  end

  @doc false
  def material(%BlockCollisions.Frame{} = frame, box, {x, y, z} = position, context) do
    with {:ok, material} <- PlayerKinetics.material(frame, box, position, context) do
      below =
        case material.support do
          nil ->
            {floor(x), floor(y - @legacy_offset), floor(z)}

          %{position: {sx, _, sz} = pos, state: state} ->
            if LandingBlocks.support_holds_y?(state),
              do: pos,
              else: {sx, floor(y - @legacy_offset), sz}
        end

      case Map.fetch(frame.states, below) do
        {:ok, state} -> {:ok, %{position: below, state: state}}
        :error -> {:error, :incomplete_landing_frame}
      end
    end
  end
end
