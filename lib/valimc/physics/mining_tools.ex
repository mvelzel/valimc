defmodule Valimc.Physics.MiningTools do
  @moduledoc "Pinned stock tool rules; player attributes, effects and loot belong to their owners."
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  @path Path.expand("../../../priv/physics/mining_tools.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @count @facts["state_count"]
  @blocks @facts["block_count"]
  @items @facts["item_count"]
  @float_max 3.4028234663852886e38
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
           @count == Valimc.Protocol.Data.block_state_count() and
           Enum.all?(0..(@items - 1), &(ItemTypes.item(&1) != nil)),
         do: raise("Wrong mining tool catalog version")

  @profiles Enum.map(@facts["profiles"], fn
              :null ->
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
  @states Base.decode16!(@facts["states"], case: :lower)
  @item_profiles Base.decode16!(@facts["items"], case: :lower)
  @blocked MapSet.new(@facts["blocked_items"])
  unless byte_size(@states) == @count * 2 and byte_size(@item_profiles) == @items * 2 and
           Enum.all?(for(<<id::16 <- @states>>, do: id), &(&1 < @blocks)) and
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

  defp block_id(state), do: uint16(@states, state)

  defp uint16(binary, index) do
    <<value::16>> = binary_part(binary, index * 2, 2)
    value
  end
end
