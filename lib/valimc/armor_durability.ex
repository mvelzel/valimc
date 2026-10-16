defmodule Valimc.ArmorDurability do
  @moduledoc "Bounded player-owned wear for admitted fire damage (at most four raw damage)."
  alias Valimc.{Inventory, PlayerDamageProtection}
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  @path Path.expand("../../priv/protocol/item_armor_wear.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @hurt MapSet.new(@facts["damage_on_hurt"])
  @resistant MapSet.new(@facts["fire_resistant"])
  @armor MapSet.new(@facts["armor_tag"])
  @armor_chance List.to_tuple(@facts["unbreaking"]["armor"])
  @other_chance List.to_tuple(@facts["unbreaking"]["other"])

  def fire(inventory, source, amount, infinite, random \\ &next_float/0)

  def fire(%Inventory{} = inventory, source, amount, infinite, random)
      when source in [:in_fire, :on_fire, :lava, :hot_floor] and is_number(amount) and
             amount >= 0 and amount <= 4 and is_boolean(infinite) and is_function(random, 0) do
    <<amount::float-32>> = <<amount::float-32>>

    if infinite or amount == 0 or not PlayerDamageProtection.wears_armor?(source) do
      {:ok, inventory, []}
    else
      {inventory, broken} =
        Enum.reduce([8, 7, 6, 5], {inventory, []}, fn slot, {inventory, broken} ->
          stack = Inventory.get(inventory, slot)

          case wear(stack, random) do
            {^stack, nil} ->
              {inventory, broken}

            {next, event} ->
              slots =
                if next,
                  do: Map.put(inventory.slots, slot, next),
                  else: Map.delete(inventory.slots, slot)

              broken = if event, do: [{slot, event} | broken], else: broken
              {%{inventory | slots: slots}, broken}
          end
        end)

      {:ok, inventory, Enum.reverse(broken)}
    end
  end

  def fire(_, _, _, _, _), do: {:error, :invalid_armor_wear}

  defp wear(nil, _random), do: {nil, nil}

  defp wear(%ItemStack{} = stack, random) do
    maximum =
      component(stack, "minecraft:max_damage", ItemTypes.item(stack.item_id)["max_damage"])

    default =
      if MapSet.member?(ItemTypes.defaults(stack.item_id).present, "minecraft:damage"), do: 0

    damage = component(stack, "minecraft:damage", default)

    allowed =
      MapSet.member?(@hurt, stack.item_id) and
        not MapSet.member?(stack.removed, "minecraft:equippable") and
        not (MapSet.member?(@resistant, stack.item_id) and
               not MapSet.member?(stack.removed, "minecraft:damage_resistant"))

    if not allowed or maximum == nil or damage == nil or
         component(stack, "minecraft:unbreakable", nil) != nil do
      {stack, nil}
    else
      level =
        stack.components
        |> Map.get("minecraft:enchantments", %{})
        |> Map.get("minecraft:unbreaking", 0)

      chance =
        elem(
          if(MapSet.member?(@armor, stack.item_id), do: @armor_chance, else: @other_chance),
          level
        )

      if level > 0 and draw(random) < chance do
        {stack, nil}
      else
        value = min(damage, maximum) + 1
        value = if value > 2_147_483_647, do: value - 4_294_967_296, else: value
        value = value |> max(0) |> min(maximum)
        next = %{stack | components: Map.put(stack.components, "minecraft:damage", value)}
        if value >= maximum, do: {nil, next}, else: {next, nil}
      end
    end
  end

  defp component(stack, name, default),
    do:
      if(MapSet.member?(stack.removed, name),
        do: nil,
        else: Map.get(stack.components, name, default)
      )

  defp draw(random) do
    value = random.()
    true = is_float(value) and value >= 0.0 and value < 1.0
    value
  end

  defp next_float, do: (:rand.uniform(16_777_216) - 1) / 16_777_216
end
