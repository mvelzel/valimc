defmodule Valimc.Protocol.ChestBlockEntity do
  @moduledoc "Pinned ordinary chest presentation; stored items belong exclusively to container menus."
  import Bitwise
  alias Valimc.{ChestAccess, Protocol.Packets, Protocol.Wire}
  # Mojang26.3 BuiltInRegistries.BLOCK_ENTITY_TYPE; checked by ChestBlockEntityOracle.
  @entity_type 1

  def chunk_entries({cx, cz}, edits) when is_map(edits) and map_size(edits) <= 131_072 do
    entries =
      edits
      |> Enum.filter(fn {{x, _, z}, block} ->
        Integer.floor_div(x, 16) == cx and Integer.floor_div(z, 16) == cz and
          ChestAccess.single?(block)
      end)
      |> Enum.sort()

    if length(entries) > 1024, do: raise(ArgumentError, "too many chest block entities")

    [
      Wire.varint(length(entries)),
      Enum.map(entries, fn {position, _} -> chunk_entry(position) end)
    ]
  end

  def chunk_entry({x, y, z})
      when is_integer(x) and is_integer(y) and is_integer(z) and y in -64..319 and
             x in -29_999_984..29_999_984 and z in -29_999_984..29_999_984 do
    packed = (x &&& 15) <<< 4 ||| (z &&& 15)
    [<<packed, y::signed-16>>, Wire.varint(@entity_type), <<0>>]
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
