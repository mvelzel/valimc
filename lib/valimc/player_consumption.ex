defmodule Valimc.PlayerConsumption do
  @moduledoc "Pure consumption transition; the player owner checkpoints it before publishing any outcome."
  alias Valimc.{
    ConsumableRemoval,
    InstantEffect,
    Inventory,
    PlayerDamage,
    PlayerEffects,
    PlayerFood,
    PlayerHealth
  }

  alias Valimc.Protocol.EffectTypes
  @heal EffectTypes.id("instant_health")
  @instant Enum.map(~w(instant_health instant_damage saturation), &EffectTypes.id/1)

  @doc "Negative signed healing's zero-health lifecycle remains unsupported; refuse the whole drink."
  def admitted_effects?({:remove, _}), do: true

  def admitted_effects?(effects) when is_list(effects) do
    Enum.all?(effects, fn
      {@heal, [{_, amp, _, _, _} | _]} ->
        {:ok, {:heal, amount}} = InstantEffect.drink_request(@heal, amp)
        amount >= 0

      _ ->
        true
    end)
  end

  def plan(player, inventory, hand, props, incoming) do
    with true <- admitted_effects?(incoming),
         {:ok, next, []} <- Inventory.consume_hand(inventory, hand, props.remainder) do
      food =
        if props.food,
          do: PlayerFood.eat(player.food, props.food.nutrition, props.food.saturation),
          else: player.food

      transition = %{
        player: %{player | food: food},
        inventory: next,
        effects: [],
        damage: [],
        death: nil
      }

      original_hand = Inventory.held(inventory, :main)
      {:ok, consume(transition, incoming, original_hand)}
    else
      _ -> :refused
    end
  end

  defp consume(transition, {:remove, policy}, _) do
    {:ok, effects, removed} = ConsumableRemoval.apply(transition.player.effects, policy)

    %{
      transition
      | player: %{transition.player | effects: effects},
        effects: Enum.map(removed, &{:remove, &1})
    }
  end

  defp consume(transition, additions, hand) when is_list(additions) do
    Enum.reduce(additions, transition, fn {id, [head | _] = value}, current ->
      if id in @instant do
        {:ok, action} = InstantEffect.drink_request(id, elem(head, 1))
        instant(current, action, hand)
      else
        new = not Map.has_key?(current.player.effects, id)
        {:ok, effects, changed} = PlayerEffects.add(current.player.effects, id, value)

        events =
          if changed,
            do: current.effects ++ [{:update, id, hd(effects[id]), new}],
            else: current.effects

        %{current | player: %{current.player | effects: effects}, effects: events}
      end
    end)
  end

  defp instant(transition, {:eat, nutrition, saturation}, _) do
    food = PlayerFood.eat(transition.player.food, nutrition, saturation)
    %{transition | player: %{transition.player | food: food}}
  end

  defp instant(transition, {:heal, amount}, _) do
    {:ok, health} = PlayerHealth.heal(transition.player.health, amount)

    %{transition | player: %{transition.player | health: health}}
  end

  defp instant(transition, {:hurt, source, amount}, hand) do
    {:ok, selected} = PlayerHealth.hurt_window(transition.player.health, amount)

    case PlayerDamage.resolve(
           transition.player,
           transition.inventory,
           selected,
           source,
           transition.player.effects,
           false
         ) do
      {:ok, %{player: player, inventory: inventory, broken: []}} ->
        context = {:self_magic, hand}
        damage = if selected.notify, do: transition.damage ++ [context], else: transition.damage
        death = if player.health.value <= 0, do: context, else: transition.death
        %{transition | player: player, inventory: inventory, damage: damage, death: death}

      result when result in [:ignored, :immune] ->
        transition
    end
  end
end
