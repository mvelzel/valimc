defmodule Valimc.PlayerArmor do
  @moduledoc "Bounded defensive attributes from the admitted stock-item/component set."
  alias Valimc.Inventory
  @path Path.expand("../../priv/protocol/item_armor.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @defaults Map.new(@facts["defaults"], fn {id, slots} ->
              {String.to_integer(id),
               Map.new(slots, fn {slot, values} ->
                 {String.to_integer(slot), List.to_tuple(values)}
               end)}
            end)
  @fire List.to_tuple(@facts["fire_protection"])

  def attributes(%Inventory{} = inventory) do
    {armor, toughness, burning} =
      Enum.reduce(
        [{5, 5}, {6, 6}, {7, 7}, {8, 8}, {36, 36 + inventory.selected}, {45, 45}],
        {0.0, 0.0, 1.0},
        fn {slot, physical}, {armor, toughness, burning} ->
          case Inventory.get(inventory, physical) do
            nil ->
              {armor, toughness, burning}

            stack ->
              {a, t} =
                if MapSet.member?(stack.removed, "minecraft:attribute_modifiers"),
                  do: {0.0, 0.0},
                  else: @defaults |> Map.get(stack.item_id, %{}) |> Map.get(slot, {0.0, 0.0})

              level =
                stack.components
                |> Map.get("minecraft:enchantments", %{})
                |> Map.get("minecraft:fire_protection", 0)

              delta = if slot in 5..8, do: elem(@fire, level), else: 0.0
              {armor + a, toughness + t, burning + delta}
          end
        end
      )

    %{
      armor: floor(min(30.0, max(0.0, armor))),
      toughness: min(20.0, max(0.0, toughness)),
      burning_time: min(1024.0, max(0.0, burning))
    }
  end
end
