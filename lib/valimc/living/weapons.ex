defmodule Valimc.Living.Weapons do
  @moduledoc """
  What an item does in a fight (VMC-037n), from `CombatOracle`'s facts: its
  default attribute modifiers (the attack damage and speed of weapons and
  tools), its `weapon` component (wear per attack, the seconds a hit disables
  a shield), its `blocks_attacks` component (shields), the damage type it
  attacks with and the attack charge it needs; the player's base attributes;
  and each modelled mob's base experience reward.

  Component patches of these are not decoded yet (VMC-004b), so a stack acts
  with its item's defaults.
  """
  use Valimc.Data.Facts, "registry/combat_facts.json"
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @operations %{"add_value" => 0, "add_multiplied_base" => 1, "add_multiplied_total" => 2}
  # `EquipmentSlotGroup`s by the slots they cover.
  @groups %{
    "any" => [:mainhand, :offhand, :feet, :legs, :chest, :head, :body, :saddle],
    "hand" => [:mainhand, :offhand],
    "armor" => [:feet, :legs, :chest, :head],
    "mainhand" => [:mainhand],
    "offhand" => [:offhand],
    "feet" => [:feet],
    "legs" => [:legs],
    "chest" => [:chest],
    "head" => [:head],
    "body" => [:body],
    "saddle" => [:saddle]
  }

  # A damage type set as a codec writes it: a tag (`{:tag, atom}`) or types.
  types = fn
    nil ->
      nil

    "#minecraft:" <> tag ->
      {:tag, String.to_atom(tag)}

    "minecraft:" <> type ->
      {:types, [String.to_atom(type)]}

    list when is_list(list) ->
      {:types, Enum.map(list, fn "minecraft:" <> t -> String.to_atom(t) end)}
  end

  @items Map.new(@facts["items"], fn {name, components} ->
           modifiers =
             for m <- Map.get(components, "minecraft:attribute_modifiers", []) do
               {m["type"], m["id"], m["amount"] * 1.0, Map.fetch!(@operations, m["operation"]),
                Map.fetch!(@groups, Map.get(m, "slot", "any"))}
             end

           weapon =
             case components["minecraft:weapon"] do
               nil ->
                 nil

               w ->
                 %{
                   wear: Map.get(w, "item_damage_per_attack", 1),
                   disables: Map.get(w, "disable_blocking_for_seconds", 0) * 1.0
                 }
             end

           blocks =
             case components["minecraft:blocks_attacks"] do
               nil ->
                 nil

               b ->
                 damage =
                   Map.get(b, "item_damage", %{"threshold" => 1, "base" => 0, "factor" => 1})

                 %{
                   delay: Map.get(b, "block_delay_seconds", 0) * 1.0,
                   disable_scale: Map.get(b, "disable_cooldown_scale", 1) * 1.0,
                   reductions:
                     for r <-
                           Map.get(b, "damage_reductions", [%{"base" => 0, "factor" => 1}]) do
                       %{
                         angle: Map.get(r, "horizontal_blocking_angle", 90) * 1.0,
                         types: types.(r["type"]),
                         base: r["base"] * 1.0,
                         factor: r["factor"] * 1.0
                       }
                     end,
                   item_damage:
                     {damage["threshold"] * 1.0, damage["base"] * 1.0, damage["factor"] * 1.0},
                   bypassed_by: types.(b["bypassed_by"])
                 }
             end

           {ItemTypes.id(name),
            %{
              modifiers: modifiers,
              weapon: weapon,
              blocks_attacks: blocks,
              damage_type:
                case components["minecraft:damage_type"] do
                  nil -> nil
                  "minecraft:" <> type -> String.to_atom(type)
                end,
              minimum_charge: Map.get(components, "minecraft:minimum_attack_charge", 0) * 1.0
            }}
         end)
  @player @facts["player_attributes"]
  @experience @facts["experience"]
  @swords MapSet.new(Valimc.Protocol.Data.tags()["minecraft:item"]["minecraft:swords"])

  @doc """
  The stock attribute modifiers `stack` adds while in `slot`, as
  `{attribute, id, amount, operation}` (operations 0 add, 1 multiply the
  base, 2 multiply the total).
  """
  def modifiers(nil, _slot), do: []

  def modifiers(%ItemStack{item_id: id}, slot) do
    for {attribute, mid, amount, operation, slots} <- facts(id).modifiers,
        slot in slots,
        do: {attribute, mid, amount, operation}
  end

  @doc "The `weapon` component: `%{wear, disables}` or nil."
  def weapon(stack), do: stack && facts(stack.item_id).weapon

  @doc "The `blocks_attacks` component (a shield's), or nil."
  def blocks_attacks(stack), do: stack && facts(stack.item_id).blocks_attacks

  @doc "The damage type an attack with `stack` deals (`ItemStack.getDamageSource`)."
  def damage_type(stack, default), do: (stack && facts(stack.item_id).damage_type) || default

  @doc "The attack charge `stack` needs (`minimum_attack_charge`), 0.0 for most items."
  def minimum_charge(stack), do: if(stack, do: facts(stack.item_id).minimum_charge, else: 0.0)

  @doc "Whether `stack` is a sword (`#minecraft:swords`, which sweeps)."
  def sword?(stack), do: stack != nil and MapSet.member?(@swords, stack.item_id)

  @doc "A player's base value of attribute `name` (`Player.createAttributes`)."
  def player_base(name), do: Map.fetch!(@player, name)

  @doc "A modelled mob type's base experience reward (its `xpReward`)."
  def experience(type), do: Map.get(@experience, type, 0)

  defp facts(id),
    do:
      Map.get(@items, id, %{
        modifiers: [],
        weapon: nil,
        blocks_attacks: nil,
        damage_type: nil,
        minimum_charge: 0.0
      })
end
