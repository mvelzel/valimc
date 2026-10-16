defmodule Valimc.ConsumableRemoval do
  @moduledoc "Stock milk/honey removal policies; completion timing and inventory remain player-owned."
  alias Valimc.{FoodItems, PlayerEffects}
  alias Valimc.Protocol.{EffectTypes, ItemStack, ItemTypes}
  @milk ItemTypes.id("milk_bucket")
  @honey ItemTypes.id("honey_bottle")
  @poison EffectTypes.id("poison")

  def policy(%ItemStack{item_id: id}, %{consumable: consumable, other_listeners: []})
      when id in [@milk, @honey] and consumable != nil do
    if consumable == FoodItems.defaults(id).consumable,
      do: {:ok, if(id == @milk, do: :all, else: :poison)},
      else: :unsupported
  end

  def policy(_, _), do: :unsupported

  def apply(effects, policy) when policy in [:all, :poison] do
    if PlayerEffects.valid?(effects) do
      removed =
        if policy == :all,
          do: Map.keys(effects),
          else: if(Map.has_key?(effects, @poison), do: [@poison], else: [])

      {:ok, Map.drop(effects, removed), Enum.sort(removed)}
    else
      {:error, :invalid_player_effects}
    end
  end
end
