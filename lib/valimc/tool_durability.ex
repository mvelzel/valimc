defmodule Valimc.ToolDurability do
  @moduledoc "Pure stock mining wear; sample once before journaling, never again on delivery retry."
  alias Valimc.Physics.MiningTools
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @doc "Returns the remaining stack and the broken-stack event payload, if any."
  def mine(stack, state, infinite, random \\ &next_float/0)

  def mine(nil, _state, infinite, _random) when is_boolean(infinite), do: {nil, nil}

  def mine(%ItemStack{} = stack, state, infinite, random)
      when is_boolean(infinite) and is_function(random, 0) do
    cost = MiningTools.damage_per_block(stack, state)

    maximum =
      component(stack, "minecraft:max_damage", ItemTypes.item(stack.item_id)["max_damage"])

    default_damage =
      if MapSet.member?(ItemTypes.defaults(stack.item_id).present, "minecraft:damage"), do: 0

    damage = component(stack, "minecraft:damage", default_damage)

    if infinite or cost == 0 or maximum == nil or damage == nil or
         component(stack, "minecraft:unbreakable", nil) != nil do
      {stack, nil}
    else
      level =
        stack.components
        |> Map.get("minecraft:enchantments", %{})
        |> Map.get("minecraft:unbreaking", 0)

      wear = wear(cost, level, random)

      if wear == 0 do
        {stack, nil}
      else
        # Native signed-int addition precedes clamping, including custom INT_MAX durability.
        value = min(damage, maximum) + wear
        value = if value > 2_147_483_647, do: value - 4_294_967_296, else: value
        value = value |> max(0) |> min(maximum)
        next = %{stack | components: Map.put(stack.components, "minecraft:damage", value)}
        if value >= maximum, do: {nil, next}, else: {next, nil}
      end
    end
  end

  defp wear(cost, 0, _random), do: cost

  defp wear(cost, level, random) do
    <<chance::float-32>> = <<level / (level + 1)::float-32>>

    Enum.count(1..cost, fn _ ->
      value = random.()
      true = is_float(value) and value >= 0.0 and value < 1.0
      value >= chance
    end)
  end

  defp component(stack, name, default),
    do:
      if(MapSet.member?(stack.removed, name),
        do: nil,
        else: Map.get(stack.components, name, default)
      )

  # Match the native 24-bit float domain using the player's process-local PRNG.
  defp next_float, do: (:rand.uniform(16_777_216) - 1) / 16_777_216
end
