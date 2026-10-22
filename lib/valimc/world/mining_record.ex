defmodule Valimc.World.MiningRecord do
  @moduledoc "Bounded write-ahead proposal for owner-local blocks, items and optional container state."
  alias Valimc.Protocol.Data
  alias Valimc.World.{Chunk, Containers, ItemRecords}
  @max_edits 4096
  @container_bytes Containers.max_bytes()
  @max_bytes 30 + @max_edits * 14 + ItemRecords.max_bytes() + Containers.max_bytes() + 32
  def max_bytes, do: @max_bytes

  def encode(key, edits, item_bytes), do: encode_record(key, edits, item_bytes, nil)

  def encode(key, edits, item_bytes, container_bytes) when is_binary(container_bytes),
    do: encode_record(key, edits, item_bytes, container_bytes)

  def encode(_, _, _, _), do: {:error, :invalid_mining_record}

  defp encode_record({rx, rz} = key, edits, item_bytes, container_bytes)
       when is_integer(rx) and is_integer(rz) and is_map(edits) and is_binary(item_bytes) and
              map_size(edits) in 1..@max_edits do
    with true <- rx in -2_147_483_648..2_147_483_647 and rz in -2_147_483_648..2_147_483_647,
         true <- Enum.all?(edits, &valid_edit?(key, &1)),
         {:ok, _} <- ItemRecords.decode(item_bytes, key),
         :ok <- valid_containers(container_bytes, key) do
      version = if container_bytes == nil, do: 1, else: 2
      container_size = if version == 1, do: <<>>, else: <<byte_size(container_bytes)::32>>

      payload =
        IO.iodata_to_binary([
          <<"VMCMINE", version, 5023::32, rx::signed-32, rz::signed-32, map_size(edits)::16,
            byte_size(item_bytes)::32>>,
          container_size,
          edits
          |> Enum.sort()
          |> Enum.map(fn {{x, y, z}, block} ->
            <<x::signed-32, y::signed-32, z::signed-32, block::16>>
          end),
          item_bytes,
          container_bytes || <<>>
        ])

      {:ok, payload <> :crypto.hash(:sha256, payload)}
    else
      _ -> {:error, :invalid_mining_record}
    end
  end

  defp encode_record(_, _, _, _), do: {:error, :invalid_mining_record}

  defp valid_containers(nil, _), do: :ok

  defp valid_containers(bytes, key) do
    case Containers.decode(bytes, key) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_mining_record}
    end
  end

  def decode(bytes, {rx, rz} = key)
      when is_binary(bytes) and byte_size(bytes) in 127..@max_bytes do
    payload_size = byte_size(bytes) - 32
    <<payload::binary-size(^payload_size), checksum::binary-size(32)>> = bytes

    <<"VMCMINE", version, 5023::32, ^rx::signed-32, ^rz::signed-32, count::16, item_size::32,
      body::binary>> = payload

    {container_size, body} =
      case {version, body} do
        {1, body} -> {0, body}
        {2, <<size::32, body::binary>>} when size in 63..@container_bytes -> {size, body}
        _ -> throw(:invalid_mining_record)
      end

    edit_size = count * 14

    with true <-
           :crypto.hash(:sha256, payload) == checksum and count in 1..@max_edits and
             item_size <= ItemRecords.max_bytes(),
         <<edit_bytes::binary-size(^edit_size), item_bytes::binary-size(^item_size),
           container_bytes::binary-size(^container_size)>> <- body,
         entries <-
           for(<<x::signed-32, y::signed-32, z::signed-32, block::16 <- edit_bytes>>,
             do: {{x, y, z}, block}
           ),
         edits <- Map.new(entries),
         true <- map_size(edits) == count and Enum.all?(edits, &valid_edit?(key, &1)),
         {:ok, ledger} <- ItemRecords.decode(item_bytes, key),
         :ok <- valid_containers(if(version == 1, do: nil, else: container_bytes), key) do
      proposal = %{edits: edits, item_bytes: item_bytes, ledger: ledger}

      {:ok,
       if(version == 1, do: proposal, else: Map.put(proposal, :container_bytes, container_bytes))}
    else
      _ -> {:error, :invalid_mining_record}
    end
  rescue
    MatchError -> {:error, :invalid_mining_record}
  catch
    :invalid_mining_record -> {:error, :invalid_mining_record}
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
