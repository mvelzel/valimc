defmodule Valimc.Physics.RandomMiningLoot do
  @moduledoc "Bounded stock-cube loot; sample once before persisting exact mining records."
  alias Valimc.Physics.Mining
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes}
  @path Path.expand("../../../priv/physics/random_mining_loot.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c",
         do: raise("Wrong random mining loot catalog version")

  @blocks Map.new(@facts["blocks"], fn profile ->
            %{"state" => state, "silk" => silk, "item" => item, "min" => low, "max" => high} =
              profile

            cap = profile["cap"]
            chances = profile["chances"]

            unless is_integer(state) and state in 0..(Data.block_state_count() - 1) and
                     Mining.hardness(state) >= 0 and Data.item_block(silk) == state and
                     ItemTypes.item(item) != nil and low in 1..64 and high in low..64 and
                     ((is_integer(cap) and cap in high..64 and chances == nil) or
                        (cap == nil and is_list(chances) and length(chances) == 4 and
                           Enum.all?(chances, &(is_float(&1) and &1 >= 0.0 and &1 <= 1.0)))),
                   do: raise("Invalid random mining loot profile")

            {state, {silk, item, low, high, cap, if(chances, do: List.to_tuple(chances))}}
          end)
  unless map_size(@blocks) == 4 and length(@facts["blocks"]) == 4,
    do: raise("Incomplete random mining loot catalog")

  def supported?(state), do: Map.has_key?(@blocks, state)

  @doc "Original tool before wear; decision draws are bounded integers or native-domain floats."
  def drops(state, tool, harvest, random \\ &draw/1)

  def drops(state, tool, harvest, random) when is_boolean(harvest) and is_function(random, 1) do
    case Map.get(@blocks, state) do
      nil ->
        {:error, :unsupported_mining_loot}

      {silk, item, low, high, cap, chances} ->
        cond do
          not harvest ->
            {:ok, []}

          enchantment(tool, "minecraft:silk_touch") > 0 ->
            {:ok, [%ItemStack{item_id: silk}]}

          chances != nil ->
            level = min(enchantment(tool, "minecraft:fortune"), tuple_size(chances) - 1)

            if float(random) < elem(chances, level),
              do:
                {:ok, [%ItemStack{item_id: item, count: low + integer(random, high - low + 1)}]},
              else: {:ok, [%ItemStack{item_id: silk}]}

          true ->
            base = low + integer(random, high - low + 1)
            bonus = integer(random, enchantment(tool, "minecraft:fortune") + 1)
            {:ok, [%ItemStack{item_id: item, count: min(base + bonus, cap)}]}
        end
    end
  end

  def drops(_, _, _, _), do: {:error, :invalid_mining_loot}

  defp enchantment(nil, _name), do: 0

  defp enchantment(%ItemStack{components: components}, name),
    do: components |> Map.get("minecraft:enchantments", %{}) |> Map.get(name, 0)

  # Bound-one draws have a fixed outcome and consume no decision randomness.
  defp integer(_random, 1), do: 0

  defp integer(random, bound) do
    value = random.(bound)
    true = is_integer(value) and value >= 0 and value < bound
    value
  end

  defp float(random) do
    value = random.(:float)
    true = is_float(value) and value >= 0.0 and value < 1.0
    value
  end

  defp draw(:float), do: (:rand.uniform(16_777_216) - 1) / 16_777_216
  defp draw(bound), do: :rand.uniform(bound) - 1
end
