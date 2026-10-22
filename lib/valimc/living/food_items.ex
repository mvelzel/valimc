defmodule Valimc.Living.FoodItems do
  @moduledoc "Pinned consumable facts and pure eligibility/remainder rules; the player owns item use."
  alias Valimc.Protocol.ItemStack
  @empty %{food: nil, consumable: nil, remainder: nil, other_listeners: []}
  @float_max 3.4028234663852886e38
  use Valimc.Data.Facts, "protocol/food_items.json"

  @defaults @facts["items"]
            |> Map.new(fn {_name, facts} ->
              food =
                if f = facts["food"],
                  do: %{
                    nutrition: f["nutrition"],
                    saturation: f["saturation"],
                    can_always_eat: f["can_always_eat"]
                  }

              remainder =
                if r = facts["remainder"],
                  do: %ItemStack{item_id: r["item_id"], count: r["count"]}

              {facts["item_id"],
               %{
                 food: food,
                 consumable: facts["consumable"],
                 remainder: remainder,
                 other_listeners: facts["other_listeners"]
               }}
            end)

  def defaults(item_id), do: Map.get(@defaults, item_id, @empty)

  def properties(%ItemStack{} = stack) do
    defaults = defaults(stack.item_id)
    listeners = Enum.reject(defaults.other_listeners, &MapSet.member?(stack.removed, &1))

    # A supported patch can introduce a native listener on an ordinary food item.
    # Until the owned consumer handles it, it must not silently become a plain meal.
    listeners =
      if Map.has_key?(stack.components, "minecraft:potion_contents") and
           "minecraft:potion_contents" not in listeners,
         do: ["minecraft:potion_contents" | listeners],
         else: listeners

    %{
      defaults
      | food: effective(stack, "minecraft:food", defaults.food),
        consumable: effective(stack, "minecraft:consumable", defaults.consumable),
        remainder: effective(stack, "minecraft:use_remainder", defaults.remainder),
        other_listeners: listeners
    }
  end

  # Specialized listeners/effects are deliberately explicit pending their owners.
  def plain?(%{consumable: nil}), do: false

  def plain?(%{consumable: c, other_listeners: listeners}),
    do: c["effects"] == 0 and listeners == [] and c["animation"] in ["eat", "drink"]

  def eligible?(%{food: nil}, _food, _abilities), do: true

  def eligible?(%{food: props}, food, abilities),
    do: abilities.invulnerable or props.can_always_eat or food.level < 20

  def duration(seconds) when is_number(seconds) and seconds >= 0 and seconds <= @float_max do
    product = f32(seconds) * 20.0
    if product >= 2_147_483_647, do: 2_147_483_647, else: min(2_147_483_647, trunc(f32(product)))
  end

  @doc "Resolve the native remainder after count consumption; extras still need inventory/drop delivery."
  def remainder(stack, _old_count, _infinite, nil), do: {stack, []}
  def remainder(stack, _old_count, true, _replacement), do: {stack, []}
  def remainder(nil, _old_count, false, replacement), do: {replacement, []}

  def remainder(%ItemStack{count: count} = stack, old_count, false, replacement),
    do: if(count >= old_count, do: {stack, []}, else: {stack, [replacement]})

  defp effective(stack, name, default),
    do:
      if(MapSet.member?(stack.removed, name),
        do: nil,
        else: Map.get(stack.components, name, default)
      )

  defp f32(number) do
    <<value::float-32>> = <<number::float-32>>
    value
  end
end
