defmodule Valimc.Blocks.MiningLoot do
  @moduledoc "Native-verified stock block loot; unsupported rule families stay explicit."
  alias Valimc.Blocks.Mining
  alias Valimc.Blocks.MiningTools
  alias Valimc.Blocks.RandomMiningLoot
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes}
  use Valimc.Data.Facts, "physics/mining_loot.json"
  @count Data.block_state_count()
  unless @facts["state_count"] == @count and @facts["block_count"] == MiningTools.block_count(),
    do: raise("Wrong mining loot catalog version")

  @profiles Enum.map(@facts["profiles"], fn
              nil ->
                nil

              [ordinary, silk] ->
                for ids <- [ordinary, silk] do
                  unless is_list(ids) and length(ids) <= 256 and
                           Enum.all?(
                             ids,
                             fn
                               [id, count] ->
                                 is_integer(id) and id > 0 and ItemTypes.item(id) != nil and
                                   count in 1..64

                               _ ->
                                 false
                             end
                           ),
                         do: raise("Invalid deterministic loot profile")

                  Enum.map(ids, fn [id, count] -> %ItemStack{item_id: id, count: count} end)
                end
                |> List.to_tuple()
            end)
            |> List.to_tuple()
  @blocks List.to_tuple(@facts["block_profiles"])
  unless elem(@profiles, 0) == nil and tuple_size(@blocks) == MiningTools.block_count() and
           Enum.all?(
             Tuple.to_list(@blocks),
             &(is_integer(&1) and &1 >= 0 and &1 < tuple_size(@profiles))
           ) and
           Enum.count(Tuple.to_list(@blocks), &(&1 != 0)) == @facts["supported_blocks"],
         do: raise("Incomplete deterministic loot indexes")

  @states Map.new(@facts["state_profiles"], fn [state, profile] ->
            unless is_integer(state) and state in 0..(@count - 1) and
                     is_integer(profile) and profile in 1..(tuple_size(@profiles) - 1),
                   do: raise("Invalid state loot override")

            {state, profile}
          end)
  unless map_size(@states) == length(@facts["state_profiles"]),
    do: raise("Duplicate state loot overrides")

  @ordinary MapSet.new(@facts["ordinary_mining"])
  @pillars MapSet.new(@facts["pillar_mining"])
  @simple MapSet.union(@ordinary, @pillars)
  unless MapSet.size(@ordinary) == 179 and length(@facts["ordinary_mining"]) == 179 and
           MapSet.size(@pillars) == 180 and length(@facts["pillar_mining"]) == 180 and
           MapSet.disjoint?(@ordinary, @pillars) and
           Enum.all?(@simple, fn state ->
             is_integer(state) and state in 0..(@count - 1) and Mining.hardness(state) >= 0 and
               elem(@blocks, MiningTools.block_id(state)) != 0
           end),
         do: raise("Invalid ordinary mining admission")

  @doc "Finite, deterministic cubes/pillars with native-verified base destruction callbacks."
  def ordinary_mining?(state), do: MapSet.member?(@simple, state)

  @doc "Use the original tool before wear, including a tool that breaks on this operation."
  def drops(state, tool, harvest)
      when is_integer(state) and state >= 0 and state < @count and
             is_boolean(harvest) do
    if harvest do
      with :default <- Valimc.Blocks.harvest_drops(state) do
        case elem(
               @profiles,
               Map.get(@states, state, elem(@blocks, MiningTools.block_id(state)))
             ) do
          nil -> RandomMiningLoot.drops(state, tool, true)
          profile -> {:ok, elem(profile, if(silk?(tool), do: 1, else: 0))}
        end
      end
    else
      {:ok, []}
    end
  end

  def drops(_, _, _), do: {:error, :invalid_mining_loot}
  defp silk?(nil), do: false

  defp silk?(%ItemStack{components: components}),
    do:
      components
      |> Map.get("minecraft:enchantments", %{})
      |> Map.get("minecraft:silk_touch", 0)
      |> Kernel.>(0)
end
