defmodule Valimc.World.Containers do
  @moduledoc "Region-owned container snapshots; persistent revisions fence stale views across replacement."
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Chunk, ItemReceipts}
  defstruct sequence: 0, entries: %{}, receipts: %{}
  @max_sequence 18_446_744_073_709_551_615
  @max_entries 1024
  @max_sources ItemReceipts.max_sources()
  @contents_bytes 524_288
  @max_bytes 8_388_608
  def max_entries, do: @max_entries
  def max_bytes, do: @max_bytes

  def observe(%__MODULE__{entries: entries}, position),
    do: Map.fetch(entries, position)

  def create(%__MODULE__{} = state, key, position, rows) when rows in 1..6 do
    cond do
      not owned?(key, position) -> {:error, :invalid_container_position}
      Map.has_key?(state.entries, position) -> {:error, :container_exists}
      map_size(state.entries) >= @max_entries -> {:error, :container_limit}
      true -> change(state, position, %{rows: rows, slots: Tuple.duplicate(nil, rows * 9)})
    end
  end

  def create(_, _, _, _), do: {:error, :invalid_container_rows}

  def replace(%__MODULE__{} = state, position, revision, slots) do
    with {:ok, %{revision: ^revision, rows: rows} = entry} <- observe(state, position),
         true <- valid_slots?(rows, slots) do
      change(state, position, %{entry | slots: slots})
    else
      :error -> {:error, :missing_container}
      {:ok, _} -> {:error, :stale_container}
      false -> {:error, :invalid_container_contents}
    end
  end

  def remove(%__MODULE__{} = state, position, revision) do
    case observe(state, position) do
      {:ok, %{revision: ^revision} = entry} when state.sequence < @max_sequence ->
        {:ok,
         %{state | sequence: state.sequence + 1, entries: Map.delete(state.entries, position)},
         entry}

      {:ok, %{revision: ^revision}} ->
        {:error, :container_sequence_exhausted}

      {:ok, _} ->
        {:error, :stale_container}

      :error ->
        {:error, :missing_container}
    end
  end

  defp change(%{sequence: sequence} = state, position, entry) when sequence < @max_sequence do
    entry = Map.put(entry, :revision, sequence + 1)

    {:ok, %{state | sequence: sequence + 1, entries: Map.put(state.entries, position, entry)},
     entry}
  end

  defp change(_, _, _), do: {:error, :container_sequence_exhausted}

  def encode({rx, rz} = key, %__MODULE__{sequence: sequence, entries: entries, receipts: receipts})
      when is_integer(sequence) and sequence in 0..@max_sequence and is_map(entries) and
             map_size(entries) <= @max_entries do
    true = region?(key)
    true = valid_receipts?(receipts)
    version = if map_size(receipts) == 0, do: 1, else: 2
    receipt_count = if version == 1, do: <<>>, else: <<map_size(receipts)::16>>

    receipt_bytes =
      Enum.map(Enum.sort(receipts), fn {source, receipt} ->
        <<source::binary-size(16), receipt.sequence::64, receipt.digest::binary-size(32)>>
      end)

    revisions = Enum.map(entries, fn {_, entry} -> entry.revision end)
    true = length(Enum.uniq(revisions)) == length(revisions)
    initial_size = 63 + byte_size(receipt_count) + map_size(receipts) * 56

    {parts, _} =
      entries
      |> Enum.sort()
      |> Enum.map_reduce(initial_size, fn {{x, y, z} = position, entry}, size ->
        %{revision: revision, rows: rows, slots: slots} = entry
        true = map_size(entry) == 3 and owned?(key, position)
        true = is_integer(revision) and revision > 0 and revision <= sequence
        bytes = slot_bytes(rows, slots)
        size = size + 25 + byte_size(bytes)
        true = size <= @max_bytes

        {<<x::signed-32, y::signed-32, z::signed-32, revision::64, rows, byte_size(bytes)::32,
           bytes::binary>>, size}
      end)

    payload =
      IO.iodata_to_binary([
        <<"VMCCONTS", version, 5023::32, rx::signed-32, rz::signed-32, sequence::64,
          map_size(entries)::16>>,
        receipt_count,
        parts,
        receipt_bytes
      ])

    {:ok, payload <> :crypto.hash(:sha256, payload)}
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  def encode(_, _), do: invalid()

  def decode(bytes, {rx, rz} = key)
      when is_binary(bytes) and byte_size(bytes) in 63..@max_bytes do
    size = byte_size(bytes) - 32
    <<payload::binary-size(^size), checksum::binary-size(32)>> = bytes
    true = :crypto.hash(:sha256, payload) == checksum

    <<"VMCCONTS", version, 5023::32, ^rx::signed-32, ^rz::signed-32, sequence::64, count::16,
      body::binary>> = payload

    true = count <= @max_entries and version in [1, 2]
    {receipts_count, body} = if version == 1, do: {0, body}, else: take_receipt_count(body)
    {entries, body} = take_entries(body, count, %{})
    {receipts, <<>>} = take_receipts(body, receipts_count, %{})
    state = %__MODULE__{sequence: sequence, entries: entries, receipts: receipts}
    {:ok, ^bytes} = encode(key, state)
    {:ok, state}
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  def decode(_, _), do: invalid()

  defp take_entries(body, 0, entries), do: {entries, body}

  defp take_entries(
         <<x::signed-32, y::signed-32, z::signed-32, revision::64, rows, length::32,
           rest::binary>>,
         count,
         entries
       ) do
    true = rows in 1..6 and length in 1..@contents_bytes
    position = {x, y, z}
    false = Map.has_key?(entries, position)
    <<bytes::binary-size(^length), rest::binary>> = rest
    {slots, <<>>} = take_slots(bytes, rows * 9, [])
    entry = %{revision: revision, rows: rows, slots: List.to_tuple(Enum.reverse(slots))}
    take_entries(rest, count - 1, Map.put(entries, position, entry))
  end

  defp take_slots(bytes, 0, slots), do: {slots, bytes}

  defp take_slots(bytes, count, slots) do
    {:ok, stack, rest} = ItemStack.take(bytes)
    take_slots(rest, count - 1, [stack | slots])
  end

  defp take_receipt_count(<<count::16, body::binary>>) do
    true = count in 1..ItemReceipts.max_sources()
    {count, body}
  end

  defp take_receipts(body, 0, receipts), do: {receipts, body}

  defp take_receipts(
         <<source::binary-size(16), sequence::64, digest::binary-size(32), body::binary>>,
         count,
         receipts
       ) do
    false = Map.has_key?(receipts, source)

    take_receipts(
      body,
      count - 1,
      Map.put(receipts, source, %{sequence: sequence, digest: digest})
    )
  end

  defp valid_receipts?(receipts) when is_map(receipts) and map_size(receipts) <= @max_sources do
    Enum.all?(receipts, fn
      {<<_::128>>, receipt} when is_map(receipt) and map_size(receipt) == 2 ->
        ItemReceipts.valid?(receipt)

      _ ->
        false
    end)
  end

  defp valid_receipts?(_), do: false

  defp valid_slots?(rows, slots) do
    slot_bytes(rows, slots)
    true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp slot_bytes(rows, slots)
       when rows in 1..6 and is_tuple(slots) and tuple_size(slots) == rows * 9 do
    {parts, _} =
      slots
      |> Tuple.to_list()
      |> Enum.map_reduce(0, fn stack, size ->
        bytes = stack |> ItemStack.encode() |> IO.iodata_to_binary()
        # Reject encodable air/noncanonical values rather than changing them on restart.
        {:ok, ^stack} = ItemStack.decode(bytes)
        size = size + byte_size(bytes)
        true = size <= @contents_bytes
        {bytes, size}
      end)

    IO.iodata_to_binary(parts)
  end

  defp owned?({_, _} = key, {x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z),
    do:
      region?(key) and x in -2_147_483_648..2_147_483_647 and
        z in -2_147_483_648..2_147_483_647 and Chunk.valid_y?(y) and
        Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == key

  defp owned?(_, _), do: false

  defp region?({x, z}),
    do:
      is_integer(x) and x in -2_147_483_648..2_147_483_647 and is_integer(z) and
        z in -2_147_483_648..2_147_483_647

  defp invalid, do: {:error, :invalid_container_snapshot}
end
