defmodule Valimc.Physics.BlockEntities do
  @moduledoc "Pinned native block-entity states; writes refuse kinds that have no owned ValiMC record yet."
  @path Path.expand("../../../priv/physics/block_entities.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @states @facts["runs"]
          |> Enum.flat_map(fn [_block, first, last] -> Enum.to_list(first..last) end)
          |> MapSet.new()
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
           @facts["state_count"] == 35_723 and @facts["block_entity_states"] == 4_743 and
           MapSet.size(@states) == 4_743,
         do: raise("Wrong native block-entity facts")

  def native?(state), do: MapSet.member?(@states, state)

  @doc "Single chests and the furnace family are the block entities ValiMC owns today."
  def supported?(state),
    do: Valimc.ChestAccess.single?(state) or Valimc.Physics.CookingBlocks.kind(state) != nil

  def unsupported?(state), do: native?(state) and not supported?(state)
end
