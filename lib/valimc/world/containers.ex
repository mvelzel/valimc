defmodule Valimc.World.Containers do
  @moduledoc "Region-owned container snapshots; persistent revisions fence stale views across replacement."
  alias Valimc.Data.Grid
  alias Valimc.Protocol.ItemStack

  alias Valimc.World.{Chunk, CookingEntry}

  # Experience orbs are entities (VMC-077h), not container state.
  defstruct sequence: 0, entries: %{}

  @max_sequence 18_446_744_073_709_551_615
  @max_entries 1024
  @contents_bytes 524_288
  @max_bytes 8_388_608
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

  def encode({rx, rz} = key, %__MODULE__{sequence: sequence, entries: entries})
      when is_integer(sequence) and sequence in 0..@max_sequence and is_map(entries) and
             map_size(entries) <= @max_entries do
    true = region?(key)

    # Version 3 holds furnaces; its (always empty) count of the player
    # transfer receipts versions 2 and 3 held before VMC-077i3 stays.
    version =
      if Enum.any?(entries, fn {_, entry} -> Map.has_key?(entry, :cooking) end), do: 3, else: 1

    receipt_count = if version == 1, do: <<>>, else: <<0::16>>
    revisions = Enum.map(entries, fn {_, entry} -> entry.revision end)
    true = length(Enum.uniq(revisions)) == length(revisions)

    initial_size = 63 + byte_size(receipt_count)

    true = initial_size <= @max_bytes

    {parts, _} =
      entries
      |> Enum.sort()
      |> Enum.map_reduce(initial_size, fn {{x, y, z} = position, entry}, size ->
        %{revision: revision} = entry
        true = owned?(key, position)
        true = is_integer(revision) and revision > 0 and revision <= sequence
        bytes = entry_bytes(entry, version)
        size = size + 20 + byte_size(bytes)
        true = size <= @max_bytes

        {<<x::signed-32, y::signed-32, z::signed-32, revision::64, bytes::binary>>, size}
      end)

    payload =
      IO.iodata_to_binary([
        <<"VMCCONTS", version, 5023::32, rx::signed-32, rz::signed-32, sequence::64,
          map_size(entries)::16>>,
        receipt_count,
        parts
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

    # Version 2 held player transfer receipts and versions 4 to 8 the cooking
    # orb ledger (D4: refused, no migration).
    true = count <= @max_entries and version in [1, 3]
    body = if version == 3, do: with(<<0::16, rest::binary>> <- body, do: rest), else: body
    {entries, <<>>} = take_entries(body, count, %{}, version)
    state = %__MODULE__{sequence: sequence, entries: entries}
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
        Grid.region_key(Grid.chunk_key(x, z)) == key

  defp owned?(_, _), do: false

  defp region?({x, z}),
    do:
      is_integer(x) and x in -2_147_483_648..2_147_483_647 and is_integer(z) and
        z in -2_147_483_648..2_147_483_647

  defp invalid, do: {:error, :invalid_container_snapshot}
end
