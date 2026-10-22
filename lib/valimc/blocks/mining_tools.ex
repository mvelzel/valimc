defmodule Valimc.Blocks.MiningTools do
  @moduledoc "Pinned stock tool rules; player attributes, effects and loot belong to their owners."
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  use Valimc.Data.Facts, "physics/mining_tools.json"
  @fire Valimc.Protocol.Data.tags()["minecraft:block"]["minecraft:fire"] |> MapSet.new()
  @shears ItemTypes.id("shears")
  @count @facts["state_count"]
  @blocks Valimc.Data.Blocks.block_count()
  @items @facts["item_count"]
  @float_max 3.4028234663852886e38
  unless @count == Valimc.Data.Blocks.state_count() and @facts["block_count"] == @blocks and
           Enum.all?(0..(@items - 1), &(ItemTypes.item(&1) != nil)),
         do: raise("Wrong mining tool catalog version")

  @profiles Enum.map(@facts["profiles"], fn
              nil ->
                nil

              p ->
                rules =
                  Enum.map(p["rules"], fn rule ->
                    ids = rule["blocks"]
                    speed = rule["speed"]
                    correct = rule["correct"]

                    unless Enum.all?(ids, &(is_integer(&1) and &1 >= 0 and &1 < @blocks)) and
                             length(ids) == MapSet.size(MapSet.new(ids)) and
                             (is_nil(speed) or
                                (is_number(speed) and speed >= 0 and speed <= @float_max)) and
                             (is_nil(correct) or is_boolean(correct)),
                           do: raise("Invalid mining tool rule")

                    {MapSet.new(ids), speed, correct}
                  end)

                unless is_number(p["default_speed"]) and p["default_speed"] >= 0 and
                         p["default_speed"] <= @float_max and
                         is_integer(p["damage_per_block"]) and p["damage_per_block"] >= 0 and
                         is_boolean(p["creative"]),
                       do: raise("Invalid mining tool properties")

                %{
                  speed: p["default_speed"],
                  damage: p["damage_per_block"],
                  creative: p["creative"],
                  rules: rules
                }
            end)
            |> List.to_tuple()
  @item_profiles Base.decode16!(@facts["items"], case: :lower)
  @blocked MapSet.new(@facts["blocked_items"])
  unless byte_size(@item_profiles) == @items * 2 and
           Enum.all?(for(<<id::16 <- @item_profiles>>, do: id), &(&1 < tuple_size(@profiles))) and
           Enum.all?(@blocked, &(&1 >= 0 and &1 < @items)),
         do: raise("Incomplete mining tool catalog")

  def speed(stack, state) when is_integer(state) and state >= 0 and state < @count do
    case profile(stack) do
      nil -> 1.0
      p -> select(p.rules, block_id(state), 1, p.speed)
    end
  end

  @doc "Tool permission only; blocks without a tool requirement can still drop without it."
  def correct_tool?(stack, state) when is_integer(state) and state >= 0 and state < @count do
    case profile(stack) do
      nil -> false
      p -> select(p.rules, block_id(state), 2, false)
    end
  end

  def damage_per_block(stack) do
    case profile(stack) do
      nil -> 0
      p -> p.damage
    end
  end

  @doc "Stock server mining callbacks: ordinary tools skip zero hardness; shears skip fire."
  def damage_per_block(stack, state) when is_integer(state) and state >= 0 and state < @count do
    skip =
      case stack do
        %ItemStack{item_id: @shears} -> MapSet.member?(@fire, block_id(state))
        _ -> Valimc.Blocks.Mining.hardness(state) == 0
      end

    if skip, do: 0, else: damage_per_block(stack)
  end

  @doc "Native permission to destroy; debug-stick block interaction is a separate action."
  def can_destroy?(stack, creative) when is_boolean(creative) do
    not blocked?(stack) and
      case profile(stack) do
        nil -> true
        p -> not creative or p.creative
      end
  end

  defp blocked?(nil), do: false
  defp blocked?(%ItemStack{item_id: id}), do: MapSet.member?(@blocked, id)
  defp profile(nil), do: nil

  defp profile(%ItemStack{item_id: id, removed: removed})
       when is_integer(id) and id >= 0 and id < @items do
    if MapSet.member?(removed, "minecraft:tool"),
      do: nil,
      else: elem(@profiles, uint16(@item_profiles, id))
  end

  # Speed and harvest permission independently use their first defined matching rule.
  defp select([], _block, _field, default), do: default

  defp select([{blocks, speed, correct} | rest], block, field, default) do
    value = if field == 1, do: speed, else: correct

    if not is_nil(value) and MapSet.member?(blocks, block),
      do: value,
      else: select(rest, block, field, default)
  end

  def block_count, do: @blocks
  defdelegate block_id(state), to: Valimc.Data.Blocks

  defp uint16(binary, index) do
    <<value::16>> = binary_part(binary, index * 2, 2)
    value
  end
end
