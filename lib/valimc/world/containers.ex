defmodule Valimc.World.Containers do
  @moduledoc "Region-owned container snapshots; persistent revisions fence stale views across replacement."
  alias Valimc.Data.Grid
  alias Valimc.Protocol.ItemStack

  import Bitwise, only: [&&&: 2]
  alias Valimc.Blocks.Brewing
  alias Valimc.World.{Chunk, CookingEntry}

  # Experience orbs are entities (VMC-077h), not container state.
  defstruct sequence: 0, entries: %{}

  @max_sequence 18_446_744_073_709_551_615
  @max_entries 1024
  @contents_bytes 524_288
  @max_bytes 8_388_608
  @machines %{hopper: 5, dropper: 9, dispenser: 9}
  @machine_ids %{hopper: 0, dropper: 1, dispenser: 2}
  @machine_kinds %{0 => :hopper, 1 => :dropper, 2 => :dispenser}
  # Plain storage blocks (VMC-032c1): their kind and its slots, no timers.
  @storage Valimc.Blocks.Storage.sizes()
  @storage_ids %{barrel: 0, shulker_box: 1}
  @storage_kinds Map.new(@storage_ids, fn {kind, id} -> {id, kind} end)
  @max_name_bytes 65_536
  def max_bytes, do: @max_bytes

  def observe(%__MODULE__{entries: entries}, position),
    do: Map.fetch(entries, position)

  @doc "A joined chest's ephemeral menu or machine view, from its two owned entries."
  def chest_view([_, _] = positions, fetch) do
    entries = Enum.map(positions, fetch)

    if Enum.all?(entries, &match?(%{rows: 3, slots: slots} when tuple_size(slots) == 27, &1)) do
      view = %{
        rows: 6,
        parts: positions,
        slots: entries |> Enum.flat_map(&Tuple.to_list(&1.slots)) |> List.to_tuple(),
        revision:
          Map.new(Enum.zip(positions, entries), fn {at, entry} -> {at, entry.revision} end)
      }

      # The first half's name, else the second's (`ChestBlock`'s double
      # chest `getDisplayName`).
      case Enum.find_value(entries, &Map.get(&1, :name)) do
        nil -> {:ok, view}
        name -> {:ok, Map.put(view, :name, name)}
      end
    else
      {:error, :missing_menu_entry}
    end
  end

  @doc "The physical 27-slot replacements of a joined chest view."
  def chest_parts(%{parts: positions, slots: slots}) do
    positions
    |> Enum.with_index()
    |> Enum.map(fn {at, index} ->
      {at, slots |> Tuple.to_list() |> Enum.slice(index * 27, 27) |> List.to_tuple()}
    end)
  end

  def create(%__MODULE__{} = state, key, position, rows) when rows in 1..6 do
    create_entry(state, key, position, %{rows: rows, slots: Tuple.duplicate(nil, rows * 9)})
  end

  def create(_, _, _, _), do: {:error, :invalid_container_rows}

  @doc """
  An empty hopper, dropper or dispenser (VMC-049a): `%{kind, slots, cooldown,
  order}`, where `cooldown` is a hopper's `TransferCooldown` (-1 none) and
  `order` the revision it was created at, the order block entities tick in.
  """
  def create_machine(%__MODULE__{} = state, key, position, kind)
      when is_map_key(@machines, kind) do
    entry = %{
      kind: kind,
      slots: Tuple.duplicate(nil, @machines[kind]),
      cooldown: -1,
      order: state.sequence + 1
    }

    create_entry(state, key, position, entry)
  end

  def create_machine(_, _, _, _), do: {:error, :invalid_container_kind}

  @doc "The machine kinds and their sizes."
  def machines, do: @machines

  @doc "Whether an entry is a hopper's, a dropper's or a dispenser's."
  def machine?(%{kind: kind, slots: _}), do: is_map_key(@machines, kind)
  def machine?(_), do: false

  @doc """
  Set a machine's cooldown alone: its revision stays, as a furnace's progress
  leaves it (menus fence item identity and counts, not timers).
  """
  def put_cooldown(%__MODULE__{} = state, position, revision, cooldown)
      when is_integer(cooldown) and cooldown in -2_147_483_648..2_147_483_647 do
    case observe(state, position) do
      {:ok, %{revision: ^revision, cooldown: ^cooldown}} ->
        {:ok, state}

      {:ok, %{revision: ^revision, cooldown: _} = entry} ->
        {:ok, %{state | entries: Map.put(state.entries, position, %{entry | cooldown: cooldown})}}

      {:ok, _} ->
        {:error, :stale_container}

      :error ->
        {:error, :missing_container}
    end
  end

  @doc """
  An empty storage entry (VMC-032c1): `%{kind, slots}` for a barrel, the
  kind every plain item store without timers or a joined form shares.
  """
  def create_storage(%__MODULE__{} = state, key, position, kind)
      when is_map_key(@storage, kind),
      do:
        create_entry(state, key, position, %{
          kind: kind,
          slots: Tuple.duplicate(nil, @storage[kind])
        })

  def create_storage(_, _, _, _), do: {:error, :invalid_container_kind}

  @doc "The storage kinds and their sizes."
  def storage, do: @storage

  @doc "Whether an entry is a storage entry (a barrel's)."
  def storage?(%{kind: kind, slots: _}), do: is_map_key(@storage, kind)
  def storage?(_), do: false

  @doc """
  The empty entry of an owned block-entity kind (`Valimc.Blocks.block_entity/1`):
  a single chest, a furnace-family block, a machine or a storage block.
  """
  def create_owned(%__MODULE__{} = state, key, position, :chest),
    do: create(state, key, position, 3)

  def create_owned(%__MODULE__{} = state, key, position, kind) when is_map_key(@machines, kind),
    do: create_machine(state, key, position, kind)

  def create_owned(%__MODULE__{} = state, key, position, kind) when is_map_key(@storage, kind),
    do: create_storage(state, key, position, kind)

  def create_owned(%__MODULE__{} = state, key, position, :brewing_stand),
    do: create_entry(state, key, position, %{kind: :brewing_stand, brewing: %Brewing{}})

  def create_owned(%__MODULE__{} = state, key, position, kind),
    do: create_cooking(state, key, position, kind)

  @doc """
  A brewing stand's next state (VMC-034o), fenced on `revision`. Its slots
  changing bumps the revision; its times alone keep it, as a furnace's
  progress does.
  """
  def replace_brewing(%__MODULE__{} = state, position, revision, %Brewing{} = brewing) do
    with {:ok, %{revision: ^revision, brewing: old} = entry} <- observe(state, position),
         true <- Brewing.valid?(brewing) and valid_slots?(brewing.slots) do
      next = %{entry | brewing: brewing}

      if old.slots == brewing.slots,
        do: {:ok, %{state | entries: Map.put(state.entries, position, next)}, next},
        else: change(state, position, next)
    else
      :error -> {:error, :missing_container}
      {:ok, _} -> {:error, :stale_container}
      false -> {:error, :invalid_container_contents}
    end
  end

  def replace_brewing(_, _, _, _), do: {:error, :invalid_container_contents}

  def create_cooking(%__MODULE__{} = state, key, position, kind) do
    with {:ok, entry} <- CookingEntry.new(kind),
         do: create_entry(state, key, position, entry)
  end

  @doc """
  Name the entry at `position` (vanilla's `CustomName`, VMC-032c5): a text
  component tag from a placed item's `minecraft:custom_name`, shown as its
  menu's title and copied into its block loot. Every owned kind takes one.
  """
  def put_name(%__MODULE__{} = state, position, revision, name) do
    with {:ok, %{revision: ^revision} = entry} <- observe(state, position),
         true <- valid_name?(name) do
      change(state, position, Map.put(entry, :name, name))
    else
      :error -> {:error, :missing_container}
      {:ok, _} -> {:error, :stale_container}
      false -> {:error, :invalid_container_name}
    end
  end

  @doc "Whether `name` is a text component an entry can hold and send."
  def valid_name?(name) do
    byte_size(IO.iodata_to_binary(Valimc.Text.Codec.encode(name))) in 1..@max_name_bytes
  rescue
    _ -> false
  catch
    _, _ -> false
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
    with {:ok, %{revision: ^revision, slots: old} = entry} <- observe(state, position),
         true <- tuple_size(old) == tuple_size(slots) and valid_slots?(slots) do
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

    # Version 3 holds furnaces, machines and storage (tagged entries); its (always
    # empty) count of the player transfer receipts versions 2 and 3 held
    # before VMC-077i3 stays.
    version =
      if Enum.any?(entries, fn {_, entry} ->
           Map.has_key?(entry, :kind) or Map.has_key?(entry, :name)
         end),
         do: 3,
         else: 1

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

  # A named entry (VMC-032c5): tag 4, its name's network NBT, then the
  # entry's own tagged bytes.
  defp entry_bytes(%{name: name} = entry, 3) do
    true = valid_name?(name)
    bytes = IO.iodata_to_binary(Valimc.Text.Codec.encode(name))
    <<4, byte_size(bytes)::32, bytes::binary, entry_bytes(Map.delete(entry, :name), 3)::binary>>
  end

  defp entry_bytes(%{rows: rows, slots: slots} = entry, version) when map_size(entry) == 3 do
    true = rows in 1..6 and tuple_size(slots) == rows * 9
    bytes = slot_bytes(slots)
    tag = if version == 3, do: <<0>>, else: <<>>
    <<tag::binary, rows, byte_size(bytes)::32, bytes::binary>>
  end

  # A hopper, dropper or dispenser (VMC-049a): kind, cooldown, tick order, slots.
  defp entry_bytes(
         %{kind: kind, slots: slots, cooldown: cooldown, order: order, revision: revision} =
           entry,
         3
       )
       when map_size(entry) == 5 do
    true = tuple_size(slots) == Map.fetch!(@machines, kind)
    true = is_integer(cooldown) and cooldown in -2_147_483_648..2_147_483_647
    true = is_integer(order) and order in 1..revision
    bytes = slot_bytes(slots)

    <<2, Map.fetch!(@machine_ids, kind), cooldown::signed-32, order::64, byte_size(bytes)::32,
      bytes::binary>>
  end

  # A storage entry (VMC-032c1): kind and slots.
  defp entry_bytes(%{kind: kind, slots: slots} = entry, 3)
       when is_map_key(@storage, kind) and map_size(entry) == 3 do
    true = tuple_size(slots) == @storage[kind]
    bytes = slot_bytes(slots)
    <<3, Map.fetch!(@storage_ids, kind), byte_size(bytes)::32, bytes::binary>>
  end

  # A brewing stand (VMC-034o): its times, ingredient, shown bottles, slots.
  defp entry_bytes(%{kind: :brewing_stand, brewing: %Brewing{} = b} = entry, 3)
       when map_size(entry) == 3 do
    true = Brewing.valid?(b)
    bytes = slot_bytes(b.slots)

    shown =
      if b.shown == nil,
        do: 8,
        else: Integer.undigits(Enum.map(b.shown, &if(&1, do: 1, else: 0)), 2)

    <<5, b.brew_time::32, b.total_brew_time::32, b.fuel::32, b.total_fuel::32, b.speed::float-32,
      b.ingredient || -1::signed-32, shown, byte_size(bytes)::32, bytes::binary>>
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
    {entry, rest} = take_entry(tag, body, revision)
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

  defp take_entry(tag, body, revision) do
    case {tag, body} do
      {0, <<rows, length::32, rest::binary>>} ->
        take_generic(rows, length, rest, revision)

      {1, <<length::32, rest::binary>>} when length in 26..@contents_bytes ->
        <<bytes::binary-size(^length), rest::binary>> = rest
        {:ok, entry} = CookingEntry.decode(bytes, revision)
        {entry, rest}

      {2, <<id, cooldown::signed-32, order::64, length::32, rest::binary>>} ->
        kind = Map.fetch!(@machine_kinds, id)
        true = order in 1..revision and length in 1..@contents_bytes
        <<bytes::binary-size(^length), rest::binary>> = rest
        {slots, <<>>} = take_slots(bytes, @machines[kind], [])

        entry = %{
          revision: revision,
          kind: kind,
          slots: List.to_tuple(Enum.reverse(slots)),
          cooldown: cooldown,
          order: order
        }

        {entry, rest}

      {3, <<id, length::32, rest::binary>>} ->
        kind = Map.fetch!(@storage_kinds, id)
        true = length in 1..@contents_bytes
        <<bytes::binary-size(^length), rest::binary>> = rest
        {slots, <<>>} = take_slots(bytes, @storage[kind], [])
        {%{revision: revision, kind: kind, slots: List.to_tuple(Enum.reverse(slots))}, rest}

      {5,
       <<brew::32, total_brew::32, fuel::32, total_fuel::32, speed::float-32,
         ingredient::signed-32, shown, length::32, rest::binary>>} ->
        true = length in 5..@contents_bytes and shown in 0..8
        <<bytes::binary-size(^length), rest::binary>> = rest
        {slots, <<>>} = take_slots(bytes, 5, [])

        brewing = %Brewing{
          slots: List.to_tuple(Enum.reverse(slots)),
          brew_time: brew,
          total_brew_time: total_brew,
          fuel: fuel,
          total_fuel: total_fuel,
          speed: speed,
          ingredient: if(ingredient == -1, do: nil, else: ingredient),
          shown: if(shown == 8, do: nil, else: for(bit <- [4, 2, 1], do: (shown &&& bit) != 0))
        }

        true = Brewing.valid?(brewing)
        {%{revision: revision, kind: :brewing_stand, brewing: brewing}, rest}

      {4, <<length::32, rest::binary>>} when length in 1..@max_name_bytes ->
        <<bytes::binary-size(^length), tag, rest::binary>> = rest
        {name, <<>>} = Valimc.Text.Codec.take(bytes)
        true = tag != 4 and valid_name?(name)
        {entry, rest} = take_entry(tag, rest, revision)
        {Map.put(entry, :name, name), rest}
    end
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

  defp valid_slots?(slots) do
    slot_bytes(slots)
    true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp slot_bytes(slots) when is_tuple(slots) and tuple_size(slots) in 1..54 do
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
