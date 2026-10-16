defmodule Valimc.World.PlacementRequest do
  @moduledoc "Canonical one-block placement transfer identity, separate from mining receipts."
  alias Valimc.Protocol.Data
  alias Valimc.World
  alias Valimc.World.Chunk
  @max_sequence 18_446_744_073_709_551_615
  def max_bytes, do: 104

  def encode({rx, rz} = key, %{
        source: <<_::128>> = source,
        sequence: sequence,
        permit: <<_::128>> = permit,
        expected: expected,
        edits: edits
      })
      when is_integer(rx) and is_integer(rz) and is_integer(sequence) and
             sequence in 1..@max_sequence and is_map(expected) and map_size(expected) in 1..2 and
             is_map(edits) and map_size(edits) == 1 do
    with true <- rx in -2_147_483_648..2_147_483_647 and rz in -2_147_483_648..2_147_483_647,
         [{target, state}] <- Map.to_list(edits),
         true <- Enum.all?(expected, &valid_edit?(key, &1)) and valid_edit?(key, {target, state}),
         true <- Map.has_key?(expected, target) and expected[target] != state do
      {x, y, z} = target

      body =
        Enum.map(Enum.sort(expected), fn {{x, y, z}, state} ->
          <<x::signed-32, y::signed-32, z::signed-32, state::16>>
        end)

      {:ok,
       IO.iodata_to_binary([
         <<"VMCPLACE", 1, 5023::32, rx::signed-32, rz::signed-32, source::binary, sequence::64,
           permit::binary, map_size(expected), x::signed-32, y::signed-32, z::signed-32,
           state::16>>,
         body
       ])}
    else
      _ -> {:error, :invalid_placement_request}
    end
  end

  def encode(_, _), do: {:error, :invalid_placement_request}

  def decode(bytes, {rx, rz} = key) when is_binary(bytes) and byte_size(bytes) in [90, 104] do
    <<"VMCPLACE", 1, 5023::32, ^rx::signed-32, ^rz::signed-32, source::binary-size(16),
      sequence::64, permit::binary-size(16), count, x::signed-32, y::signed-32, z::signed-32,
      state::16, entries::binary>> = bytes

    expected =
      Map.new(
        for <<x::signed-32, y::signed-32, z::signed-32, state::16 <- entries>>,
          do: {{x, y, z}, state}
      )

    request = %{
      source: source,
      sequence: sequence,
      permit: permit,
      expected: expected,
      edits: %{{x, y, z} => state}
    }

    with true <- count == map_size(expected),
         {:ok, ^bytes} <- encode(key, request),
         do: {:ok, request},
         else: (_ -> {:error, :invalid_placement_request})
  rescue
    MatchError -> {:error, :invalid_placement_request}
  end

  def decode(_, _), do: {:error, :invalid_placement_request}

  def digest(key, request) do
    with {:ok, bytes} <- encode(key, request), do: {:ok, :crypto.hash(:sha256, bytes)}
  end

  defp valid_edit?(key, {{x, y, z}, state})
       when is_integer(x) and is_integer(y) and is_integer(z) and is_integer(state),
       do:
         abs(x) <= 29_999_984 and abs(z) <= 29_999_984 and Chunk.valid_y?(y) and
           state >= 0 and state < Data.block_state_count() and
           World.region_key(World.chunk_key(x, z)) == key

  defp valid_edit?(_, _), do: false
end
