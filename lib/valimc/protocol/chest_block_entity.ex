defmodule Valimc.Protocol.ChestBlockEntity do
  @moduledoc "Pinned chest presentation and chunk block-entity lists; stored items belong exclusively to container menus."
  import Bitwise
  alias Valimc.Protocol.{Packets, Wire}
  # Mojang26.3 BuiltInRegistries.BLOCK_ENTITY_TYPE; checked by ChestBlockEntityOracle.
  @entity_type 1

  # Every position of a chunk could hold a block entity; update tags beyond the
  # byte budget are sent empty (the block still renders, without its data).
  @max_entries 16 * 16 * 384
  @max_tag_bytes 4 * 1024 * 1024

  @doc """
  A chunk packet's block entity list: owned chests and furnaces among `edits`
  (`position => block`, sent without a tag, as vanilla sends their empty update
  tags) and `preserved` imported entries `{position, type_id, update_or_nil}`.
  """
  def chunk_entries({cx, cz}, edits, preserved \\ [])
      when is_map(edits) and map_size(edits) <= 131_072 do
    owned =
      for {{x, _, z} = position, block} <- edits,
          Integer.floor_div(x, 16) == cx and Integer.floor_div(z, 16) == cz,
          Valimc.Block.block_entity(block) != nil or Valimc.Physics.BlockEntities.plain?(block),
          do: {position, Valimc.Physics.BlockEntities.type_id(block), nil}

    entries = Enum.sort(owned ++ preserved)
    if length(entries) > @max_entries, do: raise(ArgumentError, "too many block entities")

    {encoded, _} =
      Enum.map_reduce(entries, @max_tag_bytes, fn {position, type, tag}, budget ->
        if tag != nil and byte_size(tag) <= budget,
          do: {chunk_entry(position, type, tag), budget - byte_size(tag)},
          else: {chunk_entry(position, type, nil), budget}
      end)

    [Wire.varint(length(entries)), encoded]
  end

  def chunk_entry(position), do: chunk_entry(position, @entity_type, nil)

  def chunk_entry({x, y, z}, type, tag)
      when is_integer(x) and is_integer(y) and is_integer(z) and y in -64..319 and
             x in -29_999_984..29_999_984 and z in -29_999_984..29_999_984 and
             is_integer(type) and type >= 0 do
    packed = (x &&& 15) <<< 4 ||| (z &&& 15)
    [<<packed, y::signed-16>>, Wire.varint(type), tag || <<0>>]
  end

  @doc "A `block_entity_data` packet: a block entity's type and update tag (nil sends none)."
  def data_packet(position, type, tag) when is_integer(type) and type >= 0 do
    Packets.packet("block_entity_data", [
      Wire.position(position),
      Wire.varint(type),
      tag || <<10, 0>>
    ])
  end

  def update({x, y, z} = position)
      when is_integer(x) and is_integer(y) and is_integer(z) and y in -64..319 and
             x in -29_999_984..29_999_984 and z in -29_999_984..29_999_984,
      do:
        Packets.packet("block_entity_data", [
          Wire.position(position),
          Wire.varint(@entity_type),
          <<10, 0>>
        ])
end
