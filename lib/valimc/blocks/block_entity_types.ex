defmodule Valimc.Blocks.BlockEntityTypes do
  @moduledoc """
  Pinned native block-entity states, the block entity type each creates (network
  ids in registry order) and the blocks whose use vanilla may consume. Writes
  refuse kinds that have no owned ValiMC record yet.
  """
  use Valimc.Data.Facts, "physics/block_entities.json"
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
  unless @facts["state_count"] == Valimc.Data.Blocks.state_count() and
           @facts["block_entity_states"] == 4_743 and
           map_size(@by_state) == 4_743,
         do: raise("Wrong native block-entity facts")

  def native?(state), do: Map.has_key?(@by_state, state)

  @doc "Chests, the furnace family, item machines, barrels and shulker boxes have owned ValiMC entries."
  def supported?(state), do: Valimc.Blocks.block_entity(state) != nil

  # Block entities placed as plain blocks (VMC-026b3/b4): end portals keep
  # nothing; an end gateway's exit, once it has one, is a preserved entry.
  # Signs, banners, mob heads, decorated pots and bells a player places hold
  # nothing yet either (VMC-029d): a blank sign, a plain banner; a daylight
  # detector's never holds anything (VMC-047a); a comparator's output lives
  # with the section's redstone (VMC-048a); an ender chest's items live with
  # each player (VMC-032c3). Chunk packets list them either way.
  @plain_types ~w(minecraft:sign minecraft:hanging_sign minecraft:banner minecraft:skull
                  minecraft:decorated_pot minecraft:bell minecraft:daylight_detector
                  minecraft:comparator minecraft:ender_chest)
  @plain [
           Valimc.Data.Blocks.default_state("end_portal"),
           Valimc.Data.Blocks.default_state("end_gateway")
         ] ++
           for(
             [_block, first, last, type] <- @facts["runs"],
             type in @plain_types,
             state <- first..last,
             do: state
           )
  @plain_set MapSet.new(@plain)

  @doc "Whether a state's block entity holds no data (an end portal's)."
  def plain?(state), do: MapSet.member?(@plain_set, state)

  @doc "The states whose block entity holds no data."
  def plain_states, do: @plain

  @moving Valimc.Data.Blocks.id("moving_piston")

  @doc """
  Whether `state` is a moving piston (VMC-048b), whose block entity the
  section's pistons keep (`RegionData.pistons`) and chunk packets carry.
  """
  def moving?(state), do: Valimc.Data.Blocks.block_id(state) == @moving

  def unsupported?(state),
    do: native?(state) and not supported?(state) and not plain?(state) and not moving?(state)

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
