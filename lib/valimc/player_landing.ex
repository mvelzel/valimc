defmodule Valimc.PlayerLanding do
  @moduledoc "Landing observations from the accepted movement frame; only the player owner applies damage."
  import Bitwise
  alias Valimc.{PlayerKinetics, PlayerMotion}
  alias Valimc.Physics.{Box, CollisionContext, FluidContact}
  alias Valimc.Registry.BlockFacts
  @legacy_offset 0.20000000298023224

  def sample(player, target, flags, box, frame) do
    if (flags &&& 1) != 0 and not player.abilities.flying and
         (PlayerMotion.distance(player) > 0 or target.y < player.y) do
      dy = target.y - player.y
      moved_box = Box.move(box, {target.x - player.x, dy, target.z - player.z})

      with {:ok, fluid} <- FluidContact.sample(frame, moved_box) do
        {_, landed} =
          PlayerMotion.fall_step(PlayerMotion.distance(player), dy, true, fluid.water > 0)

        if fluid.water == 0 do
          shift = (player.input.shared_flags &&& 2) != 0

          context =
            CollisionContext.entity(target.y, shift)
            |> CollisionContext.with_entity(PlayerMotion.distance(player), false, false)

          with {:ok, material} <-
                 material(frame, moved_box, {target.x, target.y, target.z}, context),
               do: call(material.state, landed, shift)
        else
          {:ok, nil}
        end
      end
    else
      {:ok, nil}
    end
  end

  @doc "Native `fallOn`: the damage call landing on `state` from `distance` makes, or nil."
  def call(state, distance, shift) do
    rule = state |> BlockFacts.landing() |> elem(if(shift, do: 1, else: 0))

    {:ok,
     if rule do
       %{
         distance: distance * rule.distance_scale + rule.distance_offset,
         multiplier: rule.multiplier,
         source: rule.source
       }
     end}
  end

  @doc "Whether a support at `state` keeps the legacy support height (walls, fence gates, fences)."
  def holds_y?(state),
    do: BlockFacts.motion(state).support_holds_y or BlockFacts.flag?(state, :fence)

  @doc false
  def material(%Valimc.World.View{} = frame, box, position, context) do
    with {:ok, material} <- PlayerKinetics.material(frame, box, position, context) do
      from_material(frame, material, position)
    end
  end

  @doc false
  def from_material(frame, material, {x, y, z}) do
    below =
      case material.support do
        nil ->
          {floor(x), floor(y - @legacy_offset), floor(z)}

        %{position: {sx, _, sz} = pos, state: state} ->
          if holds_y?(state),
            do: pos,
            else: {sx, floor(y - @legacy_offset), sz}
      end

    case Valimc.World.View.fetch(frame, below) do
      {:ok, state} -> {:ok, %{position: below, state: state}}
      :error -> {:error, :incomplete_landing_frame}
    end
  end
end
