defmodule Valimc.PlayerDamage do
  @moduledoc "Pure owned damage resolution; callers publish, persist and advance death lifecycle."
  alias Valimc.{
    ArmorDurability,
    PlayerDamageProtection,
    PlayerEnchantmentImmunity,
    PlayerFood,
    PlayerHealth,
    PlayerInput,
    PlayerStatusImmunity
  }

  def resolve(player, inventory, selected, source, effects, inventory_pending) do
    cond do
      player.health.value <= 0 or not selected.accepted ->
        :ignored

      (source in [:fall, :stalagmite] and player.abilities.may_fly) or
        (source != :out_of_world and player.abilities.invulnerable) or
          not PlayerInput.loaded?(player.input) ->
        :immune

      PlayerEnchantmentImmunity.immune?(inventory, source) or
          PlayerStatusImmunity.immune?(player.effects, source) ->
        :immune

      PlayerDamageProtection.wears_armor?(source) and inventory_pending ->
        :deferred

      true ->
        {:ok, inventory, broken} =
          if PlayerDamageProtection.wears_armor?(source),
            do:
              ArmorDurability.damage(
                inventory,
                source,
                selected.damage,
                player.abilities.infinite_materials
              ),
            else: {:ok, inventory, []}

        {:ok, damage} = PlayerDamageProtection.damage(inventory, source, selected.damage, effects)
        {:ok, health} = PlayerHealth.reduce(selected.state, damage)

        food =
          if damage > 0,
            do: PlayerFood.exhaust(player.food, PlayerDamageProtection.exhaustion(source)),
            else: player.food

        {:ok,
         %{player: %{player | health: health, food: food}, inventory: inventory, broken: broken}}
    end
  end
end
