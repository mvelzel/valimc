defmodule Valimc.Durability do
  @moduledoc """
  Item wear (vanilla `ItemStack.hurtAndBreak`), shared by tools and armor: the
  stack's damage grows by the cost minus the points Unbreaking removes (from
  the data pack's `item_damage` effects), clamped to its maximum; at the
  maximum the item breaks.
  """
  alias Valimc.MiningTools
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  alias Valimc.Registry.EnchantmentEffects

  @doc "Wear `stack` by `cost`: `{remaining stack or nil, broken stack or nil}`."
  def hurt_and_break(stack, cost, infinite, random \\ &next_float/0)

  def hurt_and_break(nil, _cost, infinite, _random) when is_boolean(infinite), do: {nil, nil}

  def hurt_and_break(%ItemStack{} = stack, cost, infinite, random)
      when is_boolean(infinite) and is_function(random, 0) do
    case context(stack, cost, infinite) do
      :unchanged ->
        {stack, nil}

      {cost, maximum, damage, chance} ->
        apply_wear(stack, maximum, damage, wear(cost, chance, random))
    end
  end

  @doc "Stock mining wear of the tool that broke `state`."
  def mine(stack, state, infinite, random \\ &next_float/0)
  def mine(nil, _state, infinite, _random) when is_boolean(infinite), do: {nil, nil}

  def mine(%ItemStack{} = stack, state, infinite, random),
    do: hurt_and_break(stack, MiningTools.damage_per_block(stack, state), infinite, random)

  @doc "Validates a sampled mining result without consuming the owner's random draws again."
  def valid_mine?(nil, _state, infinite, result) when is_boolean(infinite), do: result == nil

  def valid_mine?(%ItemStack{} = stack, state, infinite, result) when is_boolean(infinite) do
    case context(stack, MiningTools.damage_per_block(stack, state), infinite) do
      :unchanged ->
        result == stack

      {cost, maximum, damage, chance} ->
        possible = if chance == 0.0, do: [cost], else: 0..cost
        Enum.any?(possible, &(elem(apply_wear(stack, maximum, damage, &1), 0) == result))
    end
  end

  defp context(stack, cost, infinite) do
    maximum =
      component(stack, "minecraft:max_damage", ItemTypes.item(stack.item_id)["max_damage"])

    default_damage =
      if MapSet.member?(ItemTypes.defaults(stack.item_id).present, "minecraft:damage"), do: 0

    damage = component(stack, "minecraft:damage", default_damage)

    if infinite or cost == 0 or maximum == nil or damage == nil or
         component(stack, "minecraft:unbreakable", nil) != nil do
      :unchanged
    else
      enchantments = Map.get(stack.components, "minecraft:enchantments", %{})
      {cost, maximum, damage, EnchantmentEffects.item_damage_chance(enchantments, stack.item_id)}
    end
  end

  defp apply_wear(stack, _maximum, _damage, 0), do: {stack, nil}

  defp apply_wear(stack, maximum, damage, wear) do
    # Native signed-int addition precedes clamping, including custom INT_MAX durability.
    value = min(damage, maximum) + wear
    value = if value > 2_147_483_647, do: value - 4_294_967_296, else: value
    value = value |> max(0) |> min(maximum)
    next = %{stack | components: Map.put(stack.components, "minecraft:damage", value)}
    if value >= maximum, do: {nil, next}, else: {next, nil}
  end

  # vanilla `RemoveBinomial`: one draw per point, removed below the chance.
  defp wear(cost, +0.0, _random), do: cost

  defp wear(cost, chance, random) do
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

  # Match the native 24-bit float domain using the owner's process-local PRNG.
  defp next_float, do: (:rand.uniform(16_777_216) - 1) / 16_777_216
end
