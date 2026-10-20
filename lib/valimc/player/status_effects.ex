defmodule Valimc.Player.StatusEffects do
  @moduledoc """
  Adding and removing a live status effect in the owning connection: the effect
  map, absorption, the client effect packets and the published movement facts.
  """
  alias Valimc.{PlayerAbsorption, PlayerEffects, Players}
  alias Valimc.Player.Movement
  alias Valimc.Protocol.{EffectTypes, Packets}
  import Valimc.Net.Codec, only: [send_packets: 2]

  @absorption EffectTypes.id("absorption")

  @doc "`incoming` is `[rung]` or `:remove`; returns `{:ok, changed, state}` or an error."
  def apply(state, id, incoming) do
    result =
      if incoming == :remove,
        do: PlayerEffects.remove(state.player.effects, id),
        else: PlayerEffects.add(state.player.effects, id, incoming)

    case result do
      {:ok, effects, changed} ->
        new = not Map.has_key?(state.player.effects, id)
        player = %{state.player | effects: effects}

        player =
          if id == @absorption and incoming != :remove,
            do: PlayerAbsorption.reconcile(player, elem(hd(incoming), 1)),
            else: PlayerAbsorption.reconcile(player)

        next = %{state | player: player}

        if changed do
          packet =
            if incoming == :remove,
              do: Packets.remove_effect(player.entity_id, id),
              else: Packets.update_effect(player.entity_id, id, hd(effects[id]), new)

          send_packets(next, [packet])
        end

        Players.update(self(), player)

        next =
          next
          |> Movement.publish_movement_speed()
          |> Movement.publish_absorption()
          |> Movement.publish_jump_boost()

        {:ok, changed, next}

      error ->
        error
    end
  end
end
