defmodule Valimc.PlayerDamage do
  @moduledoc "Pure owned damage resolution; callers publish, persist and advance death lifecycle."
  alias Valimc.{
    ArmorDurability,
    PlayerAbsorption,
    PlayerDamageProtection,
    PlayerEnchantmentImmunity,
    PlayerFood,
    PlayerHealth,
    PlayerInput,
    PlayerStatusImmunity
  }

  # `/kill` (vanilla `genericKill`): bypasses invulnerability, armour, effects
  # and absorption with Float.MAX_VALUE damage; exhaustion is zero.
  def resolve(player, inventory, selected, :generic_kill, _effects, _inventory_pending) do
    if player.health.value <= 0 or not selected.accepted do
      :ignored
    else
      {:ok, health} = PlayerHealth.reduce(selected.state, 3.4028234663852886e38)

      {:ok,
       %{
         player: Map.merge(player, %{health: health, absorption: 0.0}),
         inventory: inventory,
         broken: []
       }}
    end
  end

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
        {:ok, absorbed} = PlayerAbsorption.spend(Map.get(player, :absorption, 0.0), damage)
        {:ok, health} = PlayerHealth.reduce(selected.state, absorbed.damage)

        food =
          if absorbed.damage > 0,
            do: PlayerFood.exhaust(player.food, PlayerDamageProtection.exhaustion(source)),
            else: player.food

        {:ok,
         %{
           player: Map.merge(player, %{health: health, food: food, absorption: absorbed.pool}),
           inventory: inventory,
           broken: broken
         }}
    end
  end
end
