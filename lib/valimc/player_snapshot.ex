defmodule Valimc.PlayerSnapshot do
  @moduledoc "Bounded player state/outbox; legacy pose/inventory migration, not vanilla NBT."
  alias Valimc.{
    Inventory,
    PlayerFood,
    PlayerHealth,
    PlayerMiningIntent,
    PlayerPlacementIntent,
    PlayerPickupIntent,
    PlayerStore
  }

  alias Valimc.Protocol.{ItemStack, ItemTypes}
  alias Valimc.World.{ItemRecords, ItemTransfers}
  @data_version 5023
  @inventory_bytes 524_288
  @outbox_bytes max(57 + 5 * (69 + 65_536), PlayerMiningIntent.max_bytes())
  @max_sequence 18_446_744_073_709_551_615
  @max_bytes 56 + 4 + 3 + 8 + 4 + 24 + 12 + 8 + 13 + 2 + 11 + @inventory_bytes + @outbox_bytes +
               32 + 1

  def max_bytes, do: @max_bytes

  def capture(player, %Inventory{} = inventory) do
    snapshot = %{pose: PlayerStore.pose(player), inventory: inventory}

    snapshot =
      if Map.has_key?(player, :motion),
        do:
          Map.merge(snapshot, %{
            fall_distance: player.motion.fall_distance,
            velocity: player.motion.velocity
          }),
        else: snapshot

    snapshot =
      if Map.has_key?(player, :environment),
        do: Map.put(snapshot, :frozen_ticks, player.environment.frozen_ticks),
        else: snapshot

    snapshot =
      if Map.has_key?(player, :health) do
        {:ok, health} = PlayerHealth.saved(player.health)
        Map.put(snapshot, :health, health)
      else
        snapshot
      end

    snapshot =
      if Map.has_key?(player, :last_death),
        do: Map.put(snapshot, :last_death, player.last_death),
        else: snapshot

    snapshot =
      case player do
        %{abilities: %Valimc.PlayerAbilities{flying: flying}} ->
          Map.put(snapshot, :flying, flying)

        _ ->
          snapshot
      end

    snapshot =
      if Map.has_key?(player, :air_supply),
        do: Map.put(snapshot, :air_supply, player.air_supply),
        else: snapshot

    snapshot =
      if Map.has_key?(player, :food),
        do: Map.put(snapshot, :food, player.food),
        else: snapshot

    case player do
      %{game_mode: %Valimc.GameMode{} = mode} -> Map.put(snapshot, :game_mode, mode)
      _ -> snapshot
    end
  end

  def encode(<<_::128>> = uuid, %{pose: pose, inventory: inventory} = snapshot) do
    check(PlayerStore.valid_pose?(pose), :invalid_pose)
    {body, table_body} = encode_inventory(inventory)
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

    {version, journal} =
      if Map.has_key?(snapshot, :frozen_ticks) do
        check(
          version == 6 and Valimc.PlayerEnvironment.valid_ticks?(snapshot.frozen_ticks),
          :invalid_frozen_ticks
        )

        {7, [<<snapshot.frozen_ticks::32>>, journal]}
      else
        {version, journal}
      end

    {version, journal} =
      if Map.has_key?(snapshot, :velocity) do
        check(
          version in [6, 7] and Valimc.PlayerKinetics.valid_velocity?(snapshot.velocity),
          :invalid_velocity
        )

        {vx, vy, vz} = snapshot.velocity
        journal = if version == 6, do: [<<0::32>>, journal], else: journal
        {8, [<<vx::float-64, vy::float-64, vz::float-64>>, journal]}
      else
        {version, journal}
      end

    {version, journal} =
      if Map.has_key?(snapshot, :health) do
        check(version == 8 and PlayerHealth.valid_saved?(snapshot.health), :invalid_health)
        health = snapshot.health
        {9, [<<health.value::float-32, health.hurt_ticks::16, health.death_ticks::16>>, journal]}
      else
        {version, journal}
      end

    {version, journal} =
      if Map.has_key?(snapshot, :last_death) do
        check(
          version == 9 and Valimc.PlayerLife.valid_location?(snapshot.last_death),
          :invalid_last_death
        )

        location =
          case snapshot.last_death do
            nil -> <<0>>
            {x, y, z} -> <<1, x::signed-32, y::signed-32, z::signed-32>>
          end

        {10, [location, journal]}
      else
        {version, journal}
      end

    {version, journal} =
      if Map.has_key?(snapshot, :air_supply) do
        check(version == 10 and Valimc.PlayerAir.valid?(snapshot.air_supply), :invalid_air_supply)
        {11, [<<snapshot.air_supply::signed-16>>, journal]}
      else
        {version, journal}
      end

    {version, journal} =
      if Map.has_key?(snapshot, :food) do
        check(version == 11 and PlayerFood.valid?(snapshot.food), :invalid_food)
        food = snapshot.food

        {12,
         [
           <<food.level, food.saturation::float-32, food.exhaustion::float-32, food.timer::16>>,
           journal
         ]}
      else
        {version, journal}
      end

    version =
      case outbox do
        %{kind: :mining} ->
          check(version == 12, :invalid_mining_snapshot)

          check(
            PlayerMiningIntent.matches_inventory?(outbox, inventory),
            :invalid_mining_snapshot
          )

          13

        %{kind: :placement} ->
          check(version == 12, :invalid_placement_snapshot)

          check(
            PlayerPlacementIntent.matches_inventory?(outbox, inventory),
            :invalid_placement_snapshot
          )

          14

        %{kind: :pickup} ->
          check(
            version == 12 and PlayerPickupIntent.matches_snapshot?(outbox, snapshot),
            :invalid_pickup_snapshot
          )

          16

        _ ->
          version
      end

    {version, journal} =
      if inventory.table_inputs == nil,
        do: {version, journal},
        else: {15, [<<version>>, table_body, journal]}

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

    {payload, table_inputs, table_bytes} =
      case payload do
        <<"VMCPOSE", 15, header::binary-size(52), base, rest::binary>>
        when base in 2..14 or base == 16 ->
          {cells, body} = take_stacks(rest, 9)
          table_bytes = byte_size(rest) - byte_size(body)
          {<<"VMCPOSE", base, header::binary, body::binary>>, List.to_tuple(cells), table_bytes}

        _ ->
          {payload, nil, 0}
      end

    case decode_payload(payload, uuid, table_bytes, table_inputs) do
      {:ok, snapshot} -> {:ok, put_in(snapshot.inventory.table_inputs, table_inputs)}
      error -> error
    end
  rescue
    _ -> {:error, :invalid_player_file}
  catch
    {:snapshot_error, _} -> {:error, :invalid_player_file}
  end

  def decode(_, _), do: {:error, :invalid_player_file}

  defp decode_payload(payload, uuid, table_bytes, table_inputs) do
    case payload do
      <<"VMCPOSE", 1, ^uuid::binary-size(16), x::float-64, y::float-64, z::float-64,
        yaw::float-32, pitch::float-32>> ->
        snapshot(%{x: x, y: y, z: z, yaw: yaw, pitch: pitch}, Inventory.new())

      <<"VMCPOSE", 2, ^uuid::binary-size(16), x::float-64, y::float-64, z::float-64,
        yaw::float-32, pitch::float-32, @data_version::32, body::binary>> ->
        snapshot(
          %{x: x, y: y, z: z, yaw: yaw, pitch: pitch},
          decode_inventory(body, table_bytes)
        )

      <<"VMCPOSE", 3, ^uuid::binary-size(16), x::float-64, y::float-64, z::float-64,
        yaw::float-32, pitch::float-32, @data_version::32, sequence::64, length::32,
        body::binary>> ->
        check(sequence > 0 and length <= @outbox_bytes, :invalid_player_file)
        <<outbox::binary-size(^length), body::binary>> = body

        snapshot(
          %{x: x, y: y, z: z, yaw: yaw, pitch: pitch},
          decode_inventory(body, table_bytes),
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
            decode_inventory(body, table_bytes),
            sequence,
            decode_outbox(uuid, sequence, outbox)
          )

        {:ok, Map.put(snapshot, :flying, flying == 1)}

      <<"VMCPOSE", version, ^uuid::binary-size(16), x::float-64, y::float-64, z::float-64,
        yaw::float-32, pitch::float-32, @data_version::32, rest::binary>>
      when version in [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16] ->
        {food, rest} =
          if version >= 12 do
            <<level, saturation::float-32, exhaustion::float-32, timer::16, rest::binary>> =
              rest

            food = %PlayerFood{
              level: level,
              saturation: saturation,
              exhaustion: exhaustion,
              timer: timer
            }

            check(PlayerFood.valid?(food), :invalid_player_file)
            {%{food: food}, rest}
          else
            {%{}, rest}
          end

        {air, rest} =
          if version >= 11 do
            <<supply::signed-16, rest::binary>> = rest
            check(Valimc.PlayerAir.valid?(supply), :invalid_player_file)
            {%{air_supply: supply}, rest}
          else
            {%{}, rest}
          end

        {life, rest} =
          if version >= 10 do
            {location, rest} =
              case rest do
                <<0, rest::binary>> ->
                  {nil, rest}

                <<1, x::signed-32, y::signed-32, z::signed-32, rest::binary>> ->
                  {{x, y, z}, rest}
              end

            check(Valimc.PlayerLife.valid_location?(location), :invalid_player_file)
            {%{last_death: location}, rest}
          else
            {%{}, rest}
          end

        {health, rest} =
          if version >= 9 do
            <<value::float-32, hurt::16, death::16, rest::binary>> = rest
            health = %{value: value, hurt_ticks: hurt, death_ticks: death}
            check(PlayerHealth.valid_saved?(health), :invalid_player_file)
            {%{health: health}, rest}
          else
            {%{}, rest}
          end

        {velocity, rest} =
          if version >= 8 do
            <<vx::float-64, vy::float-64, vz::float-64, rest::binary>> = rest
            check(Valimc.PlayerKinetics.valid_velocity?({vx, vy, vz}), :invalid_player_file)
            {%{velocity: {vx, vy, vz}}, rest}
          else
            {%{}, rest}
          end

        {environment, rest} =
          if version >= 7 do
            <<frozen::32, rest::binary>> = rest
            check(Valimc.PlayerEnvironment.valid_ticks?(frozen), :invalid_player_file)
            {%{frozen_ticks: frozen}, rest}
          else
            {%{}, rest}
          end

        {fall, rest} =
          if version >= 6 do
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
            decode_inventory(body, table_bytes),
            sequence,
            case version do
              16 -> decode_pickup_outbox(uuid, sequence, outbox)
              14 -> decode_placement_outbox(uuid, sequence, outbox)
              13 -> decode_mining_outbox(uuid, sequence, outbox)
              _ -> decode_outbox(uuid, sequence, outbox)
            end
          )

        check(
          version != 13 or
            PlayerMiningIntent.matches_inventory?(snapshot.outbox, snapshot.inventory),
          :invalid_player_file
        )

        check(
          version != 14 or
            PlayerPlacementIntent.matches_inventory?(snapshot.outbox, snapshot.inventory),
          :invalid_player_file
        )

        check(
          version != 16 or
            PlayerPickupIntent.matches_snapshot?(snapshot.outbox, %{
              inventory: %{snapshot.inventory | table_inputs: table_inputs},
              game_mode: mode
            }),
          :invalid_player_file
        )

        {:ok,
         snapshot
         |> Map.merge(%{game_mode: mode, flying: flying == 1})
         |> Map.merge(fall)
         |> Map.merge(environment)
         |> Map.merge(velocity)
         |> Map.merge(health)
         |> Map.merge(life)
         |> Map.merge(air)
         |> Map.merge(food)}

      _ ->
        {:error, :invalid_player_file}
    end
  end

  defp snapshot(pose, inventory, sequence \\ 0, outbox \\ nil) do
    check(PlayerStore.valid_pose?(pose), :invalid_player_file)
    {:ok, %{pose: pose, inventory: inventory, transfer_sequence: sequence, outbox: outbox}}
  end

  def transfer_request(_uuid, %{outbox: %{kind: _}}), do: {:error, :wrong_transfer_kind}

  def transfer_request(<<_::128>> = uuid, %{
        transfer_sequence: sequence,
        outbox: %{key: key, records: records}
      }) do
    request = %{source: uuid, sequence: sequence, records: records}
    with {:ok, digest} <- ItemTransfers.digest(key, request), do: {:ok, key, request, digest}
  end

  def transfer_request(_, _), do: {:error, :no_pending_transfer}

  defp encode_outbox(_uuid, _sequence, nil), do: <<>>

  defp encode_outbox(uuid, sequence, %{kind: :mining} = intent) do
    {:ok, bytes} = PlayerMiningIntent.encode(uuid, sequence, intent)
    bytes
  end

  defp encode_outbox(uuid, sequence, %{kind: :placement} = intent) do
    {:ok, bytes} = PlayerPlacementIntent.encode(uuid, sequence, intent)
    bytes
  end

  defp encode_outbox(uuid, sequence, %{kind: :pickup} = intent) do
    {:ok, bytes} = PlayerPickupIntent.encode(uuid, sequence, intent)
    bytes
  end

  defp encode_outbox(_uuid, _sequence, %{kind: _}),
    do: throw({:snapshot_error, :invalid_transfer_kind})

  defp encode_outbox(uuid, sequence, %{key: key, records: records}) do
    {:ok, bytes, _digest} =
      ItemTransfers.encode_request(key, %{source: uuid, sequence: sequence, records: records})

    check(byte_size(bytes) <= @outbox_bytes, :outbox_byte_limit)
    bytes
  end

  defp decode_mining_outbox(uuid, sequence, bytes) do
    {:ok, intent} = PlayerMiningIntent.decode(uuid, sequence, bytes)
    intent
  end

  defp decode_placement_outbox(uuid, sequence, bytes) do
    {:ok, intent} = PlayerPlacementIntent.decode(uuid, sequence, bytes)
    intent
  end

  defp decode_pickup_outbox(uuid, sequence, bytes) do
    {:ok, intent} = PlayerPickupIntent.decode(uuid, sequence, bytes)
    intent
  end

  defp decode_outbox(_uuid, _sequence, <<>>), do: nil

  defp decode_outbox(
         uuid,
         sequence,
         <<"VMCITEMS", version, @data_version::32, rx::signed-32, rz::signed-32, _::binary>> =
           bytes
       )
       when version in [1, 3] do
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
    {encoded, size} = encode_stacks(stacks, 1)
    {table, _size} = encode_stacks(Inventory.table_contents(inventory), size)
    {[<<selected>>, encoded], table}
  end

  defp encode_inventory(_), do: throw({:snapshot_error, :invalid_inventory})

  defp encode_stacks(stacks, size) do
    Enum.map_reduce(stacks, size, fn stack, size ->
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
  end

  defp decode_inventory(<<selected, body::binary>>, extra_bytes) when selected in 0..8 do
    check(byte_size(body) + 1 + extra_bytes <= @inventory_bytes, :invalid_player_file)

    {slots, body} =
      Enum.reduce(1..45, {%{}, body}, fn slot, {slots, bytes} ->
        {:ok, stack, rest} = ItemStack.take(bytes)
        {if(stack == nil, do: slots, else: Map.put(slots, slot, stack)), rest}
      end)

    {:ok, carried, <<>>} = ItemStack.take(body)
    %Inventory{slots: slots, selected: selected, carried: carried}
  end

  defp take_stacks(bytes, count) do
    {stacks, rest} =
      Enum.map_reduce(1..count, bytes, fn _, bytes ->
        {:ok, stack, rest} = ItemStack.take(bytes)
        {stack, rest}
      end)

    {stacks, rest}
  end

  defp check(true, _), do: :ok
  defp check(false, reason), do: throw({:snapshot_error, reason})
end
