defmodule Valimc.World.Containers do
  @moduledoc "Region-owned container snapshots; persistent revisions fence stale views across replacement."
  alias Valimc.Protocol.ItemStack

  alias Valimc.World.{
    Chunk,
    CookingEntry,
    CookingOrbs,
    CookingOrbTransfers,
    CookingOrbConsumptions,
    ItemReceipts,
    PendingCookingAwards
  }

  defstruct sequence: 0,
            entries: %{},
            receipts: %{},
            pending_awards: %{},
            cooking_orbs: %{},
            orb_transfers: %{revision: 0, outgoing: %{}, incoming: %{}},
            orb_consumption: %{revision: 0, counts: %{}}

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
    create_entry(state, key, position, %{rows: rows, slots: Tuple.duplicate(nil, rows * 9)})
  end

  def create(_, _, _, _), do: {:error, :invalid_container_rows}

  def create_cooking(%__MODULE__{} = state, key, position, kind) do
    with {:ok, entry} <- CookingEntry.new(kind),
         do: create_entry(state, key, position, entry)
  end

  def replace_cooking(%__MODULE__{} = state, position, revision, cooking, recipes) do
    with {:ok, %{revision: ^revision, cooking: _} = entry} <- observe(state, position),
         next = %{entry | cooking: cooking, recipes: recipes},
         {:ok, _} <- CookingEntry.encode(next) do
      change(state, position, next)
    else
      :error -> {:error, :missing_container}
      {:ok, _} -> {:error, :stale_container}
      error -> error
    end
  end

  defp create_entry(state, key, position, entry) do
    cond do
      not owned?(key, position) -> {:error, :invalid_container_position}
      Map.has_key?(state.entries, position) -> {:error, :container_exists}
      map_size(state.entries) >= @max_entries -> {:error, :container_limit}
      true -> change(state, position, entry)
    end
  end

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

  def encode({rx, rz} = key, %__MODULE__{
        sequence: sequence,
        entries: entries,
        receipts: receipts,
        pending_awards: awards,
        cooking_orbs: orbs,
        orb_transfers: transfers,
        orb_consumption: consumption
      })
      when is_integer(sequence) and sequence in 0..@max_sequence and is_map(entries) and
             map_size(entries) <= @max_entries do
    true = region?(key)
    true = valid_receipts?(receipts)
    true = is_map(awards)
    true = is_map(orbs)
    consumed? = consumption != CookingOrbConsumptions.new()
    remote? = transfers != CookingOrbTransfers.new()
    extended? = remote? or consumed?
    {:ok, transfer_bytes} = CookingOrbTransfers.encode(transfers, key, awards, orbs)

    {:ok, award_bytes} =
      if map_size(awards) == 0 and not extended?,
        do: {:ok, <<>>},
        else: PendingCookingAwards.encode(key, awards, receipts)

    {:ok, orb_bytes} =
      if map_size(orbs) == 0 and not extended?,
        do: {:ok, <<>>},
        else: CookingOrbs.encode(orbs, key, awards)

    {:ok, consumed_bytes} =
      CookingOrbConsumptions.encode(consumption, %{cooking_orbs: orbs, orb_transfers: transfers})

    # v6 length-delimits both ledgers before transfer receipts. Empty transfer
    # state retains exact v1-v5 bytes, including their original layout tags.
    effects =
      cond do
        consumed? ->
          <<byte_size(award_bytes)::32, award_bytes::binary, byte_size(orb_bytes)::32,
            orb_bytes::binary, byte_size(transfer_bytes)::32, transfer_bytes::binary,
            consumed_bytes::binary>>

        remote? ->
          <<byte_size(award_bytes)::32, award_bytes::binary, byte_size(orb_bytes)::32,
            orb_bytes::binary, transfer_bytes::binary>>

        map_size(orbs) == 0 ->
          award_bytes

        true ->
          <<byte_size(award_bytes)::32, award_bytes::binary, orb_bytes::binary>>
      end

    version =
      cond do
        consumed? -> 7
        remote? -> 6
        map_size(orbs) > 0 -> 5
        map_size(awards) > 0 -> 4
        Enum.any?(entries, fn {_, entry} -> Map.has_key?(entry, :cooking) end) -> 3
        map_size(receipts) == 0 -> 1
        true -> 2
      end

    receipt_count = if version == 1, do: <<>>, else: <<map_size(receipts)::16>>

    receipt_bytes =
      Enum.map(Enum.sort(receipts), fn {source, receipt} ->
        <<source::binary-size(16), receipt.sequence::64, receipt.digest::binary-size(32)>>
      end)

    revisions = Enum.map(entries, fn {_, entry} -> entry.revision end)
    true = length(Enum.uniq(revisions)) == length(revisions)

    initial_size =
      63 + byte_size(receipt_count) + map_size(receipts) * 56 + byte_size(effects)

    true = initial_size <= @max_bytes

    {parts, _} =
      entries
      |> Enum.sort()
      |> Enum.map_reduce(initial_size, fn {{x, y, z} = position, entry}, size ->
        %{revision: revision} = entry
        true = owned?(key, position)
        true = is_integer(revision) and revision > 0 and revision <= sequence
        bytes = entry_bytes(entry, min(version, 3))
        size = size + 20 + byte_size(bytes)
        true = size <= @max_bytes

        {<<x::signed-32, y::signed-32, z::signed-32, revision::64, bytes::binary>>, size}
      end)

    payload =
      IO.iodata_to_binary([
        <<"VMCCONTS", version, 5023::32, rx::signed-32, rz::signed-32, sequence::64,
          map_size(entries)::16>>,
        receipt_count,
        parts,
        receipt_bytes,
        effects
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

    true = count <= @max_entries and version in [1, 2, 3, 4, 5, 6, 7]

    {receipts_count, body} =
      case version do
        1 -> {0, body}
        2 -> take_receipt_count(body)
        3 -> take_receipt_count(body, 0)
        4 -> take_receipt_count(body, 0)
        5 -> take_receipt_count(body, 0)
        6 -> take_receipt_count(body, 0)
        7 -> take_receipt_count(body, 0)
      end

    {entries, body} = take_entries(body, count, %{}, min(version, 3))
    {receipts, rest} = take_receipts(body, receipts_count, %{})

    {rest, consumed_bytes} =
      if version == 7 do
        <<a::32, awards::binary-size(a), o::32, orbs::binary-size(o), t::32,
          transfers::binary-size(t), consumption::binary>> = rest

        {<<a::32, awards::binary, o::32, orbs::binary, transfers::binary>>, consumption}
      else
        {rest, nil}
      end

    {awards, orbs, transfers} =
      case version do
        v when v in [6, 7] ->
          <<length::32, award_bytes::binary-size(length), rest::binary>> = rest
          <<length::32, orb_bytes::binary-size(length), transfer_bytes::binary>> = rest
          {:ok, awards} = PendingCookingAwards.decode(award_bytes, key, receipts)
          {:ok, orbs} = CookingOrbs.decode(orb_bytes, key, awards)
          {:ok, transfers} = CookingOrbTransfers.decode(transfer_bytes, key, awards, orbs)
          {awards, orbs, transfers}

        5 ->
          <<length::32, award_bytes::binary-size(length), orb_bytes::binary>> = rest
          {:ok, awards} = PendingCookingAwards.decode(award_bytes, key, receipts)
          {:ok, orbs} = CookingOrbs.decode(orb_bytes, key, awards)
          {awards, orbs, CookingOrbTransfers.new()}

        4 ->
          {:ok, awards} = PendingCookingAwards.decode(rest, key, receipts)
          {awards, %{}, CookingOrbTransfers.new()}

        _ ->
          <<>> = rest
          {%{}, %{}, CookingOrbTransfers.new()}
      end

    state = %__MODULE__{
      sequence: sequence,
      entries: entries,
      receipts: receipts,
      pending_awards: awards,
      cooking_orbs: orbs,
      orb_transfers: transfers
    }

    state =
      if consumed_bytes do
        {:ok, consumption} = CookingOrbConsumptions.decode(consumed_bytes, state)
        %{state | orb_consumption: consumption}
      else
        state
      end

    {:ok, ^bytes} = encode(key, state)
    {:ok, state}
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  def decode(_, _), do: invalid()

  defp entry_bytes(%{rows: rows, slots: slots} = entry, version) when map_size(entry) == 3 do
    bytes = slot_bytes(rows, slots)
    tag = if version == 3, do: <<0>>, else: <<>>
    <<tag::binary, rows, byte_size(bytes)::32, bytes::binary>>
  end

  defp entry_bytes(%{cooking: _} = entry, 3) do
    {:ok, bytes} = CookingEntry.encode(entry)
    <<1, byte_size(bytes)::32, bytes::binary>>
  end

  defp take_entries(body, 0, entries, _version), do: {entries, body}

  defp take_entries(
         <<x::signed-32, y::signed-32, z::signed-32, revision::64, tag, body::binary>>,
         count,
         entries,
         3
       ) do
    position = {x, y, z}
    false = Map.has_key?(entries, position)

    {entry, rest} =
      case {tag, body} do
        {0, <<rows, length::32, rest::binary>>} ->
          take_generic(rows, length, rest, revision)

        {1, <<length::32, rest::binary>>} when length in 26..@contents_bytes ->
          <<bytes::binary-size(^length), rest::binary>> = rest
          {:ok, entry} = CookingEntry.decode(bytes, revision)
          {entry, rest}
      end

    take_entries(rest, count - 1, Map.put(entries, position, entry), 3)
  end

  defp take_entries(
         <<x::signed-32, y::signed-32, z::signed-32, revision::64, rows, length::32,
           rest::binary>>,
         count,
         entries,
         version
       )
       when version in [1, 2] do
    position = {x, y, z}
    false = Map.has_key?(entries, position)
    {entry, rest} = take_generic(rows, length, rest, revision)
    take_entries(rest, count - 1, Map.put(entries, position, entry), version)
  end

  defp take_generic(rows, length, rest, revision) do
    true = rows in 1..6 and length in 1..@contents_bytes
    <<bytes::binary-size(^length), rest::binary>> = rest
    {slots, <<>>} = take_slots(bytes, rows * 9, [])
    entry = %{revision: revision, rows: rows, slots: List.to_tuple(Enum.reverse(slots))}
    {entry, rest}
  end

  defp take_slots(bytes, 0, slots), do: {slots, bytes}

  defp take_slots(bytes, count, slots) do
    {:ok, stack, rest} = ItemStack.take(bytes)
    take_slots(rest, count - 1, [stack | slots])
  end

  defp take_receipt_count(bytes, minimum \\ 1)

  defp take_receipt_count(<<count::16, body::binary>>, minimum) do
    true = count >= minimum and count <= ItemReceipts.max_sources()
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
