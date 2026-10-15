defmodule Valimc.World.MiningRecord do
  @moduledoc "Bounded write-ahead proposal for owner-local block edits and their complete item ledger."
  alias Valimc.Protocol.Data
  alias Valimc.World.{Chunk, ItemRecords}
  @max_edits 4096
  @max_bytes 26 + @max_edits * 14 + ItemRecords.max_bytes() + 32
  def max_bytes, do: @max_bytes

  def encode({rx, rz} = key, edits, item_bytes)
      when is_integer(rx) and is_integer(rz) and is_map(edits) and is_binary(item_bytes) and
             map_size(edits) in 1..@max_edits do
    with true <- rx in -2_147_483_648..2_147_483_647 and rz in -2_147_483_648..2_147_483_647,
         true <- Enum.all?(edits, &valid_edit?(key, &1)),
         {:ok, _} <- ItemRecords.decode(item_bytes, key) do
      payload =
        IO.iodata_to_binary([
          <<"VMCMINE", 1, 5023::32, rx::signed-32, rz::signed-32, map_size(edits)::16,
            byte_size(item_bytes)::32>>,
          edits
          |> Enum.sort()
          |> Enum.map(fn {{x, y, z}, block} ->
            <<x::signed-32, y::signed-32, z::signed-32, block::16>>
          end),
          item_bytes
        ])

      {:ok, payload <> :crypto.hash(:sha256, payload)}
    else
      _ -> {:error, :invalid_mining_record}
    end
  end

  def encode(_, _, _), do: {:error, :invalid_mining_record}

  def decode(bytes, {rx, rz} = key)
      when is_binary(bytes) and byte_size(bytes) in 127..@max_bytes do
    payload_size = byte_size(bytes) - 32
    <<payload::binary-size(^payload_size), checksum::binary-size(32)>> = bytes

    <<"VMCMINE", 1, 5023::32, ^rx::signed-32, ^rz::signed-32, count::16, item_size::32,
      body::binary>> = payload

    edit_size = count * 14

    with true <-
           :crypto.hash(:sha256, payload) == checksum and count in 1..@max_edits and
             item_size <= ItemRecords.max_bytes(),
         <<edit_bytes::binary-size(^edit_size), item_bytes::binary-size(^item_size)>> <- body,
         entries <-
           for(<<x::signed-32, y::signed-32, z::signed-32, block::16 <- edit_bytes>>,
             do: {{x, y, z}, block}
           ),
         edits <- Map.new(entries),
         true <- map_size(edits) == count and Enum.all?(edits, &valid_edit?(key, &1)),
         {:ok, ledger} <- ItemRecords.decode(item_bytes, key) do
      {:ok, %{edits: edits, item_bytes: item_bytes, ledger: ledger}}
    else
      _ -> {:error, :invalid_mining_record}
    end
  rescue
    MatchError -> {:error, :invalid_mining_record}
  end

  def decode(_, _), do: {:error, :invalid_mining_record}

  defp valid_edit?(key, {{x, y, z}, block})
       when is_integer(x) and is_integer(y) and is_integer(z) and is_integer(block),
       do:
         abs(x) <= 29_999_984 and abs(z) <= 29_999_984 and Chunk.valid_y?(y) and
           block >= 0 and block < Data.block_state_count() and
           Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == key

  defp valid_edit?(_, _), do: false
end
