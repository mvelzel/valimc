defmodule Valimc.Physics.MiningLoot do
  @moduledoc "Native-verified deterministic stock block loot; unsupported rule families stay explicit."
  alias Valimc.Physics.MiningTools
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes}
  @path Path.expand("../../../priv/physics/mining_loot.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @count Data.block_state_count()
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
           @facts["state_count"] == @count and @facts["block_count"] == MiningTools.block_count(),
         do: raise("Wrong mining loot catalog version")

  @profiles Enum.map(@facts["profiles"], fn
              :null ->
                nil

              [ordinary, silk] ->
                for ids <- [ordinary, silk] do
                  unless is_list(ids) and length(ids) <= 256 and
                           Enum.all?(
                             ids,
                             &(is_integer(&1) and &1 > 0 and ItemTypes.item(&1) != nil)
                           ),
                         do: raise("Invalid deterministic loot profile")

                  Enum.map(ids, &%ItemStack{item_id: &1})
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

  @doc "Use the original tool before wear, including a tool that breaks on this operation."
  def drops(state, tool, harvest)
      when is_integer(state) and state >= 0 and state < @count and
             is_boolean(harvest) do
    if harvest do
      case elem(@profiles, elem(@blocks, MiningTools.block_id(state))) do
        nil -> {:error, :unsupported_mining_loot}
        profile -> {:ok, elem(profile, if(silk?(tool), do: 1, else: 0))}
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
