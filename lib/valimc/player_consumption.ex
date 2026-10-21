defmodule Valimc.PlayerConsumption do
  @moduledoc "Pure consumption transition; the player owner checkpoints it before publishing any outcome."
  alias Valimc.{Inventory, PlayerFood}
  alias Valimc.Living.{Effects, Health}

  alias Valimc.Protocol.EffectTypes
  @heal EffectTypes.id("instant_health")
  @absorption EffectTypes.id("absorption")
  @instant Enum.map(~w(instant_health instant_damage saturation), &EffectTypes.id/1)

  @doc "Negative signed healing's zero-health lifecycle remains unsupported; refuse the whole drink."
  def admitted_effects?({:remove, _}), do: true

  def admitted_effects?(effects) when is_list(effects) do
    Enum.all?(effects, fn
      {@heal, [{_, amp, _, _, _} | _]} ->
        {:ok, {:heal, amount}} = Effects.instant(@heal, amp)
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
    living = transition.player.living
    {:ok, effects, removed} = Effects.apply_removal(living.effects, policy)
    absorption = Health.reconcile_absorption(living.absorption, effects)
    living = %{living | effects: effects, absorption: absorption}

    %{
      transition
      | player: %{transition.player | living: living},
        effects: Enum.map(removed, &{:remove, &1})
    }
  end

  defp consume(transition, additions, hand) when is_list(additions) do
    Enum.reduce(additions, transition, fn {id, [head | _] = value}, current ->
      if id in @instant do
        {:ok, action} = Effects.instant(id, elem(head, 1))
        instant(current, action, hand)
      else
        living = current.player.living
        new = not Map.has_key?(living.effects, id)
        {:ok, effects, changed} = Effects.add(living.effects, id, value)

        events =
          if changed,
            do: current.effects ++ [{:update, id, hd(effects[id]), new}],
            else: current.effects

        absorption =
          if id == @absorption,
            do: Health.reconcile_absorption(living.absorption, effects, elem(head, 1)),
            else: living.absorption

        living = %{living | effects: effects, absorption: absorption}
        %{current | player: %{current.player | living: living}, effects: events}
      end
    end)
  end

  defp instant(transition, {:eat, nutrition, saturation}, _) do
    food = PlayerFood.eat(transition.player.food, nutrition, saturation)
    %{transition | player: %{transition.player | food: food}}
  end

  defp instant(transition, {:heal, amount}, _) do
    living = transition.player.living
    {:ok, health} = Health.heal(living.health, amount)
    %{transition | player: %{transition.player | living: %{living | health: health}}}
  end

  defp instant(transition, {:hurt, source, amount}, hand) do
    {:ok, selected} = Health.hurt_window(transition.player.living.health, amount)

    case Valimc.Player.Vitals.resolve_damage(
           transition.player,
           transition.inventory,
           selected,
           source,
           transition.player.living.effects,
           false
         ) do
      {:ok, %{player: player, inventory: inventory, broken: []}} ->
        context = {:self_magic, hand}
        damage = if selected.notify, do: transition.damage ++ [context], else: transition.damage
        death = if player.living.health.value <= 0, do: context, else: transition.death
        %{transition | player: player, inventory: inventory, damage: damage, death: death}

      result when result in [:ignored, :immune] ->
        transition
    end
  end
end
