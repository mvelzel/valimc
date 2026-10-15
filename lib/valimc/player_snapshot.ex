defmodule Valimc.PlayerSnapshot do
  @moduledoc "Bounded player state/outbox; legacy pose/inventory migration, not vanilla NBT."
  alias Valimc.{Inventory, PlayerStore}
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  alias Valimc.World.{ItemRecords, ItemTransfers}
  @data_version 5023
  @inventory_bytes 524_288
  @outbox_bytes 55 + 5 * (40 + 65_536)
  @max_sequence 18_446_744_073_709_551_615
  @max_bytes 56 + 4 + 3 + 8 + 12 + @inventory_bytes + @outbox_bytes + 32

  def max_bytes, do: @max_bytes

  def capture(player, %Inventory{} = inventory) do
    snapshot = %{pose: PlayerStore.pose(player), inventory: inventory}

    snapshot =
      if Map.has_key?(player, :motion),
        do: Map.put(snapshot, :fall_distance, player.motion.fall_distance),
        else: snapshot

    snapshot =
      case player do
        %{abilities: %Valimc.PlayerAbilities{flying: flying}} ->
          Map.put(snapshot, :flying, flying)

        _ ->
          snapshot
      end

    case player do
      %{game_mode: %Valimc.GameMode{} = mode} -> Map.put(snapshot, :game_mode, mode)
      _ -> snapshot
    end
  end

  def encode(<<_::128>> = uuid, %{pose: pose, inventory: inventory} = snapshot) do
    check(PlayerStore.valid_pose?(pose), :invalid_pose)
    body = encode_inventory(inventory)
    sequence = Map.get(snapshot, :transfer_sequence, 0)
    outbox = Map.get(snapshot, :outbox)
    check(is_integer(sequence) and sequence in 0..@max_sequence, :invalid_transfer_sequence)

    {version, journal} =
      if Map.has_key?(snapshot, :game_mode) do
        {:ok, mode_bytes} = Valimc.GameMode.encode(snapshot.game_mode)
        check(is_boolean(Map.get(snapshot, :flying)), :invalid_flight_state)
        bytes = encode_outbox(uuid, sequence, outbox)
        check(sequence > 0 or outbox == nil, :invalid_transfer_sequence)

        {5,
         [
           mode_bytes,
           <<if(snapshot.flying, do: 1, else: 0), sequence::64, byte_size(bytes)::32>>,
           bytes
         ]}
      else
        if Map.has_key?(snapshot, :flying) do
          check(is_boolean(snapshot.flying), :invalid_flight_state)
          bytes = encode_outbox(uuid, sequence, outbox)
          check(sequence > 0 or outbox == nil, :invalid_transfer_sequence)

          {4,
           [<<if(snapshot.flying, do: 1, else: 0), sequence::64, byte_size(bytes)::32>>, bytes]}
        else
          if sequence == 0 and outbox == nil do
            {2, []}
          else
            bytes = encode_outbox(uuid, sequence, outbox)
            {3, [<<sequence::64, byte_size(bytes)::32>>, bytes]}
          end
        end
      end

    {version, journal} =
      if Map.has_key?(snapshot, :fall_distance) do
        check(
          version == 5 and Valimc.PlayerMotion.valid_distance?(snapshot.fall_distance),
          :invalid_fall_distance
        )

        {6, [<<snapshot.fall_distance::float-64>>, journal]}
      else
        {version, journal}
      end

    payload =
      IO.iodata_to_binary([
        <<"VMCPOSE", version, uuid::binary-size(16), pose.x::float-64, pose.y::float-64,
          pose.z::float-64, pose.yaw::float-32, pose.pitch::float-32, @data_version::32>>,
        journal,
        body
      ])

    {:ok, payload <> :crypto.hash(:sha256, payload)}
  rescue
    _error in [ArgumentError, MatchError, FunctionClauseError, KeyError] ->
      {:error, :invalid_player_state}
  catch
    {:snapshot_error, reason} -> {:error, reason}
    {:item_error, _} -> {:error, :invalid_inventory}
  end

  def encode(_, _), do: {:error, :invalid_player_state}

  def decode(bytes, uuid) when is_binary(bytes) and byte_size(bytes) in 88..@max_bytes do
    payload_bytes = byte_size(bytes) - 32
    <<payload::binary-size(^payload_bytes), checksum::binary-size(32)>> = bytes
    check(:crypto.hash(:sha256, payload) == checksum, :invalid_player_file)

    case payload do
      <<"VMCPOSE", 1, ^uuid::binary-size(16), x::float-64, y::float-64, z::float-64,
        yaw::float-32, pitch::float-32>> ->
        snapshot(%{x: x, y: y, z: z, yaw: yaw, pitch: pitch}, Inventory.new())

      <<"VMCPOSE", 2, ^uuid::binary-size(16), x::float-64, y::float-64, z::float-64,
        yaw::float-32, pitch::float-32, @data_version::32, body::binary>> ->
        snapshot(%{x: x, y: y, z: z, yaw: yaw, pitch: pitch}, decode_inventory(body))

      <<"VMCPOSE", 3, ^uuid::binary-size(16), x::float-64, y::float-64, z::float-64,
        yaw::float-32, pitch::float-32, @data_version::32, sequence::64, length::32,
        body::binary>> ->
        check(sequence > 0 and length <= @outbox_bytes, :invalid_player_file)
        <<outbox::binary-size(^length), body::binary>> = body

        snapshot(
          %{x: x, y: y, z: z, yaw: yaw, pitch: pitch},
          decode_inventory(body),
          sequence,
          decode_outbox(uuid, sequence, outbox)
        )

      <<"VMCPOSE", 4, ^uuid::binary-size(16), x::float-64, y::float-64, z::float-64,
        yaw::float-32, pitch::float-32, @data_version::32, flying, sequence::64, length::32,
        body::binary>> ->
        check(flying in 0..1 and length <= @outbox_bytes, :invalid_player_file)
        check(sequence > 0 or length == 0, :invalid_player_file)
        <<outbox::binary-size(^length), body::binary>> = body

        {:ok, snapshot} =
          snapshot(
            %{x: x, y: y, z: z, yaw: yaw, pitch: pitch},
            decode_inventory(body),
            sequence,
            decode_outbox(uuid, sequence, outbox)
          )

        {:ok, Map.put(snapshot, :flying, flying == 1)}

      <<"VMCPOSE", version, ^uuid::binary-size(16), x::float-64, y::float-64, z::float-64,
        yaw::float-32, pitch::float-32, @data_version::32, rest::binary>>
      when version in [5, 6] ->
        {fall, rest} =
          if version == 6 do
            <<distance::float-64, rest::binary>> = rest
            check(Valimc.PlayerMotion.valid_distance?(distance), :invalid_player_file)
            {%{fall_distance: distance}, rest}
          else
            {%{}, rest}
          end

        <<mode::binary-size(2), flying, sequence::64, length::32, body::binary>> = rest
        {:ok, mode} = Valimc.GameMode.decode(mode)
        check(flying in 0..1 and length <= @outbox_bytes, :invalid_player_file)
        check(sequence > 0 or length == 0, :invalid_player_file)
        <<outbox::binary-size(^length), body::binary>> = body

        {:ok, snapshot} =
          snapshot(
            %{x: x, y: y, z: z, yaw: yaw, pitch: pitch},
            decode_inventory(body),
            sequence,
            decode_outbox(uuid, sequence, outbox)
          )

        {:ok, snapshot |> Map.merge(%{game_mode: mode, flying: flying == 1}) |> Map.merge(fall)}

      _ ->
        {:error, :invalid_player_file}
    end
  rescue
    _ -> {:error, :invalid_player_file}
  catch
    {:snapshot_error, _} -> {:error, :invalid_player_file}
  end

  def decode(_, _), do: {:error, :invalid_player_file}

  defp snapshot(pose, inventory, sequence \\ 0, outbox \\ nil) do
    check(PlayerStore.valid_pose?(pose), :invalid_player_file)
    {:ok, %{pose: pose, inventory: inventory, transfer_sequence: sequence, outbox: outbox}}
  end

  def transfer_request(<<_::128>> = uuid, %{
        transfer_sequence: sequence,
        outbox: %{key: key, records: records}
      }) do
    request = %{source: uuid, sequence: sequence, records: records}
    with {:ok, digest} <- ItemTransfers.digest(key, request), do: {:ok, key, request, digest}
  end

  def transfer_request(_, _), do: {:error, :no_pending_transfer}

  defp encode_outbox(_uuid, _sequence, nil), do: <<>>

  defp encode_outbox(uuid, sequence, %{key: key, records: records}) do
    {:ok, bytes, _digest} =
      ItemTransfers.encode_request(key, %{source: uuid, sequence: sequence, records: records})

    check(byte_size(bytes) <= @outbox_bytes, :outbox_byte_limit)
    bytes
  end

  defp decode_outbox(_uuid, _sequence, <<>>), do: nil

  defp decode_outbox(
         uuid,
         sequence,
         <<"VMCITEMS", 1, @data_version::32, rx::signed-32, rz::signed-32, _::binary>> = bytes
       ) do
    key = {rx, rz}
    {:ok, %{records: records, receipts: receipts}} = ItemRecords.decode(bytes, key)
    check(receipts == %{}, :invalid_player_file)
    {:ok, _} = ItemTransfers.digest(key, %{source: uuid, sequence: sequence, records: records})
    %{key: key, records: records}
  end

  defp encode_inventory(%Inventory{slots: slots, selected: selected} = inventory)
       when is_map(slots) do
    check(is_integer(selected) and selected in 0..8, :invalid_inventory)
    check(map_size(slots) <= 46 and Map.get(slots, 0) == nil, :invalid_inventory)

    check(
      Enum.all?(slots, fn {slot, _} -> is_integer(slot) and slot in 0..45 end),
      :invalid_inventory
    )

    stacks = Enum.map(1..45, &Inventory.get(inventory, &1)) ++ [inventory.carried]

    {encoded, _size} =
      Enum.map_reduce(stacks, 1, fn stack, size ->
        check(
          stack == nil or
            match?(%ItemStack{components: c, removed: %MapSet{}} when is_map(c), stack),
          :invalid_inventory
        )

        check(stack == nil or stack.item_id != ItemTypes.id("air"), :invalid_inventory)
        bytes = ItemStack.encode(stack)
        size = size + IO.iodata_length(bytes)
        check(size <= @inventory_bytes, :inventory_byte_limit)
        {bytes, size}
      end)

    [<<selected>>, encoded]
  end

  defp encode_inventory(_), do: throw({:snapshot_error, :invalid_inventory})

  defp decode_inventory(<<selected, body::binary>>) when selected in 0..8 do
    check(byte_size(body) + 1 <= @inventory_bytes, :invalid_player_file)

    {slots, body} =
      Enum.reduce(1..45, {%{}, body}, fn slot, {slots, bytes} ->
        {:ok, stack, rest} = ItemStack.take(bytes)
        {if(stack == nil, do: slots, else: Map.put(slots, slot, stack)), rest}
      end)

    {:ok, carried, <<>>} = ItemStack.take(body)
    %Inventory{slots: slots, selected: selected, carried: carried}
  end

  defp check(true, _), do: :ok
  defp check(false, reason), do: throw({:snapshot_error, reason})
end
