defmodule Valimc.PlayerLanding do
  @moduledoc "Landing observations from the accepted movement frame; only the player owner applies damage."
  import Bitwise
  alias Valimc.{PlayerKinetics, PlayerMotion}
  alias Valimc.Physics.{Box, CollisionContext, FluidContact}
  alias Valimc.Registry.BlockFacts

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

          with {:ok, material} <-
                 material(
                   frame,
                   moved_box,
                   {target.x, target.y, target.z},
                   CollisionContext.player(player, target.y)
                 ),
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
  # The legacy landing block (`getOnPos(0.2F)`) of a material.
  def from_material(_frame, material, _position), do: {:ok, material.legacy}
end
