defmodule Valimc.World.BlockBatch do
  @moduledoc "Bounded owner-local edits and shared section frames, prepared outside the owner."
  import Bitwise
  alias Valimc.Protocol.{Data, Packets, Wire}
  alias Valimc.World.Chunk
  @enforce_keys [:region, :edits, :chunks, :frames]
  defstruct [:region, :edits, :chunks, :frames]

  def prepare(edits, threshold \\ Valimc.config(:compression_threshold))

  # Up to vanilla's `max_block_modifications` (32,768), a box edit's cells in one owner.
  def prepare(edits, threshold) when is_map(edits) and map_size(edits) in 1..32_768 do
    if Enum.all?(edits, &valid_edit?/1) do
      sections =
        Enum.group_by(edits, fn {{x, y, z}, _} ->
          {Integer.floor_div(x, 16), Integer.floor_div(y, 16), Integer.floor_div(z, 16)}
        end)

      chunks = sections |> Map.keys() |> Enum.map(fn {x, _, z} -> {x, z} end) |> Enum.uniq()
      regions = chunks |> Enum.map(&Valimc.Data.Grid.region_key/1) |> Enum.uniq()

      case regions do
        [region] ->
          frames =
            sections
            |> Enum.sort()
            |> Enum.map(fn {{cx, sy, cz}, updates} ->
              packed = (cx &&& 0x3FFFFF) <<< 42 ||| (cz &&& 0x3FFFFF) <<< 20 ||| (sy &&& 0xFFFFF)

              entries =
                updates
                |> Enum.map(fn {{x, y, z}, block} ->
                  local = (x &&& 15) <<< 8 ||| (z &&& 15) <<< 4 ||| (y &&& 15)
                  {local, block}
                end)
                |> Enum.sort()

              body = [
                <<packed::64>>,
                Wire.varint(length(entries)),
                Enum.map(entries, fn {local, block} -> Wire.varlong(block <<< 12 ||| local) end)
              ]

              packet = Packets.packet("section_blocks_update", body)
              {{cx, cz}, Packets.frame(packet, threshold)}
            end)

          {:ok, %__MODULE__{region: region, edits: edits, chunks: chunks, frames: frames}}

        _ ->
          {:error, :cross_region_batch}
      end
    else
      {:error, :invalid_block_batch}
    end
  end

  def prepare(_, _), do: {:error, :invalid_block_batch}

  defp valid_edit?({{x, y, z}, block})
       when is_integer(x) and is_integer(y) and is_integer(z) and is_integer(block),
       do:
         abs(x) <= 29_999_984 and abs(z) <= 29_999_984 and Chunk.valid_y?(y) and
           block >= 0 and block < Data.block_state_count()

  defp valid_edit?(_), do: false
end
