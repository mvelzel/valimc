defmodule Valimc.Physics.BlockEntities do
  @moduledoc """
  Pinned native block-entity states, the block entity type each creates (network
  ids in registry order) and the blocks whose use vanilla may consume. Writes
  refuse kinds that have no owned ValiMC record yet.
  """
  use Valimc.Facts, "physics/block_entities.json"
  @types List.to_tuple(@facts["types"])
  @type_ids @facts["types"] |> Enum.with_index() |> Map.new()
  @by_state @facts["runs"]
            |> Enum.flat_map(fn [_block, first, last, type] ->
              Enum.map(first..last, &{&1, Map.fetch!(@type_ids, type)})
            end)
            |> Map.new()
  @interactive_blocks MapSet.new(@facts["interactive"])
  @interactive @facts["runs"]
               |> Enum.filter(fn [block | _] -> MapSet.member?(@interactive_blocks, block) end)
               |> Enum.flat_map(fn [_, first, last, _] -> Enum.to_list(first..last) end)
               |> MapSet.new()
  unless @facts["state_count"] == Valimc.Registry.Blocks.state_count() and
           @facts["block_entity_states"] == 4_743 and
           map_size(@by_state) == 4_743,
         do: raise("Wrong native block-entity facts")

  def native?(state), do: Map.has_key?(@by_state, state)

  @doc "Single chests and the furnace family are the block entities ValiMC owns today."
  def supported?(state), do: Valimc.Block.block_entity(state) != nil

  # Block entities placed as plain blocks (VMC-026b3/b4): end portals keep
  # nothing; an end gateway's exit, once it has one, is a preserved entry.
  # Chunk packets list them either way.
  @plain [
    Valimc.Registry.Blocks.default_state("end_portal"),
    Valimc.Registry.Blocks.default_state("end_gateway")
  ]

  @doc "Whether a state's block entity holds no data (an end portal's)."
  def plain?(state), do: state in @plain

  @doc "The states whose block entity holds no data."
  def plain_states, do: @plain

  def unsupported?(state), do: native?(state) and not supported?(state) and not plain?(state)

  @doc "The network id of the block entity type a state creates, or nil."
  def type_id(state), do: Map.get(@by_state, state)

  @doc "A block entity type's name (`minecraft:sign`) by network id, or nil."
  def type_name(id) when is_integer(id) and id >= 0 and id < tuple_size(@types),
    do: elem(@types, id)

  def type_name(_), do: nil

  @doc "The network id of a block entity type name, or nil."
  def type_named(name), do: Map.get(@type_ids, name)

  @doc "Whether the state's block overrides `useItemOn`/`useWithoutItem` (vanilla may consume a use)."
  def interactive?(state), do: MapSet.member?(@interactive, state)
end
