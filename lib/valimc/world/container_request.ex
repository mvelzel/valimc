defmodule Valimc.World.ContainerRequest do
  @moduledoc "Canonical bounded container action; a durable player intent must precede delivery."
  alias Valimc.{ContainerClick, CookingClick, Inventory}
  alias Valimc.Physics.CookingBlocks
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.Containers
  @max_sequence 18_446_744_073_709_551_615
  @contents_bytes 524_288
  @header_bytes 95
  @max_bytes @header_bytes + 2 * @contents_bytes + 239
  @actions %{pickup: 0, quick_move: 1, swap: 2}
  @kinds {:furnace, :smoker, :blast_furnace}
  def max_bytes, do: @max_bytes

  def encode(key, %{kind: :experience} = request),
    do: Valimc.World.ExperienceRequest.encode(key, request)

  def encode(
        {rx, rz} = key,
        %{
          source: <<_::128>> = source,
          sequence: sequence,
          permit: <<_::128>> = permit,
          position: {x, y, z} = position,
          revision: revision,
          slots: slots,
          inventory: %Inventory{} = inventory,
          action: action,
          slot: slot,
          button: button
        } = request
      )
      when map_size(request) in [11, 12] and is_integer(sequence) and sequence in 1..@max_sequence and
             is_integer(revision) and revision in 1..@max_sequence do
    with {:ok, version, tag} <- layout(request, key, position),
         {:ok, _slots, _inventory} <- plan(request),
         true <- valid_inventory?(inventory),
         storage_bytes = encode_cells(Tuple.to_list(slots)),
         inventory_bytes =
           encode_cells(Enum.map(1..45, &Inventory.get(inventory, &1)) ++ [inventory.carried]),
         {:ok, code} <- Map.fetch(@actions, action),
         {:ok, award} <- award_bytes(request, version) do
      {:ok,
       <<"VMCCREQ", version, 5023::32, rx::signed-32, rz::signed-32, source::binary-size(16),
         sequence::64, permit::binary-size(16), x::signed-32, y::signed-32, z::signed-32,
         revision::64, tag, code, slot::signed-16, button::signed-8, inventory.selected,
         if(inventory.infinite_materials, do: 1, else: 0), byte_size(storage_bytes)::32,
         byte_size(inventory_bytes)::32, storage_bytes::binary, inventory_bytes::binary,
         award::binary>>}
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  def encode(_, _), do: invalid()

  def decode(<<"VMCXPICK", _::binary>> = bytes, key),
    do: Valimc.World.ExperienceRequest.decode(bytes, key)

  def decode(bytes, {rx, rz} = key)
      when is_binary(bytes) and
             byte_size(bytes) in @header_bytes..@max_bytes do
    <<"VMCCREQ", version, 5023::32, ^rx::signed-32, ^rz::signed-32, source::binary-size(16),
      sequence::64, permit::binary-size(16), x::signed-32, y::signed-32, z::signed-32,
      revision::64, tag, code, slot::signed-16, button::signed-8, selected, infinite,
      storage_size::32, inventory_size::32, rest::binary>> = bytes

    {layout_key, layout_value, count} = decode_layout(version, tag)
    true = selected in 0..8 and infinite in [0, 1]
    true = storage_size in 1..@contents_bytes and inventory_size in 1..@contents_bytes

    <<storage_bytes::binary-size(^storage_size), inventory_bytes::binary-size(^inventory_size),
      award_bytes::binary>> =
      rest

    {storage, <<>>} = take_cells(storage_bytes, count, [])
    {cells, <<>>} = take_cells(inventory_bytes, 46, [])

    slots =
      cells
      |> Enum.take(45)
      |> Enum.zip(1..45)
      |> Enum.reject(fn {item, _} -> item == nil end)
      |> Map.new(fn {item, slot} -> {slot, item} end)

    # Network counters/drag are session state, not part of a durable item identity.
    inventory = %Inventory{
      slots: slots,
      carried: List.last(cells),
      selected: selected,
      infinite_materials: infinite == 1
    }

    {action, ^code} = Enum.find(@actions, fn {_, value} -> value == code end)

    request = %{
      source: source,
      sequence: sequence,
      permit: permit,
      position: {x, y, z},
      revision: revision,
      slots: List.to_tuple(storage),
      inventory: inventory,
      action: action,
      slot: slot,
      button: button
    }

    request = Map.put(request, layout_key, layout_value)

    request =
      if version == 3 do
        {:ok, award} = Valimc.World.CookingAwardRequest.decode(award_bytes)
        Map.put(request, :award, award)
      else
        <<>> = award_bytes
        request
      end

    {:ok, ^bytes} = encode(key, request)
    {:ok, request}
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  def decode(_, _), do: invalid()

  def digest(key, request) do
    with {:ok, bytes} <- encode(key, request), do: {:ok, :crypto.hash(:sha256, bytes)}
  end

  def plan(%{
        rows: rows,
        slots: slots,
        inventory: inventory,
        action: action,
        slot: slot,
        button: button
      }),
      do: ContainerClick.plan(rows, slots, inventory, action, slot, button)

  def plan(%{
        kind: kind,
        slots: slots,
        inventory: inventory,
        action: action,
        slot: slot,
        button: button
      }) do
    with {:ok, block} <- CookingBlocks.placement(kind, 0.0),
         {:ok, next_slots, next_inventory, _taken} <-
           CookingClick.plan(block, slots, inventory, action, slot, button),
         do: {:ok, next_slots, next_inventory}
  end

  def matches_entry?(
        %{revision: revision, rows: rows, slots: slots},
        %{revision: revision, rows: rows, slots: slots}
      ),
      do: true

  def matches_entry?(
        %{revision: revision, kind: kind, slots: slots},
        %{revision: revision, kind: kind, cooking: %{slots: slots}}
      )
      when kind in [:furnace, :smoker, :blast_furnace],
      do: true

  def matches_entry?(_, _), do: false

  defp award_bytes(%{award: award}, 3), do: Valimc.World.CookingAwardRequest.encode(award)

  defp award_bytes(request, version) when version in [1, 2] and map_size(request) == 11,
    do: {:ok, <<>>}

  defp award_bytes(_, _), do: invalid()

  defp layout(%{rows: rows}, key, position) do
    with {:ok, _, _} <- Containers.create(%Containers{}, key, position, rows),
         do: {:ok, 1, rows}
  end

  defp layout(%{kind: kind, award: award}, key, position) do
    with {:ok, _, _} <- Containers.create_cooking(%Containers{}, key, position, kind),
         {:ok, _} <- Valimc.World.CookingAwardRequest.encode(award),
         do: {:ok, 3, Enum.find_index(Tuple.to_list(@kinds), &(&1 == kind))}
  end

  defp layout(%{kind: kind}, key, position) do
    with {:ok, _, _} <- Containers.create_cooking(%Containers{}, key, position, kind),
         do: {:ok, 2, Enum.find_index(Tuple.to_list(@kinds), &(&1 == kind))}
  end

  defp layout(_, _, _), do: invalid()
  defp decode_layout(1, rows) when rows in 1..6, do: {:rows, rows, rows * 9}

  defp decode_layout(version, kind) when version in [2, 3] and kind in 0..2,
    do: {:kind, elem(@kinds, kind), 3}

  defp valid_inventory?(%Inventory{
         slots: slots,
         selected: selected,
         drag: nil,
         table_inputs: nil,
         infinite_materials: infinite
       }) do
    is_map(slots) and map_size(slots) <= 45 and
      Enum.all?(Map.keys(slots), &(is_integer(&1) and &1 in 1..45)) and
      selected in 0..8 and is_boolean(infinite)
  end

  defp valid_inventory?(_), do: false

  defp encode_cells(cells) do
    {parts, _} =
      Enum.map_reduce(cells, 0, fn stack, size ->
        bytes = stack |> ItemStack.encode() |> IO.iodata_to_binary()
        {:ok, ^stack} = ItemStack.decode(bytes)
        size = size + byte_size(bytes)
        true = size <= @contents_bytes
        {bytes, size}
      end)

    IO.iodata_to_binary(parts)
  end

  defp take_cells(bytes, 0, cells), do: {Enum.reverse(cells), bytes}

  defp take_cells(bytes, count, cells) do
    {:ok, stack, rest} = ItemStack.take(bytes)
    take_cells(rest, count - 1, [stack | cells])
  end

  defp invalid, do: {:error, :invalid_container_request}
end
