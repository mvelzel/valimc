defmodule Valimc.TestClient do
  @doc "The connection process whose login name is `name` (connections may exit concurrently)."
  def connection(name) do
    Enum.find_value(DynamicSupervisor.which_children(Valimc.ConnectionSupervisor), fn {_, pid, _,
                                                                                       _} ->
      try do
        if :sys.get_state(pid).login_name == name, do: pid
      catch
        :exit, _ -> nil
      end
    end)
  end

  @moduledoc false
  alias Valimc.Protocol.{Data, Encryption, ItemStack, Wire}

  def connect do
    {:ok, socket} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        Valimc.Listener.port(),
        [:binary, active: false, packet: :raw],
        5000
      )

    %{socket: socket, buffer: <<>>, threshold: nil}
  end

  def close(client), do: :gen_tcp.close(client.socket)

  def await_position(pid, expected, attempts \\ 200) do
    player = :sys.get_state(pid).player

    if Map.take(player, Map.keys(expected)) == expected do
      player
    else
      if attempts == 0, do: raise("Player did not reach #{inspect(expected)}")
      Process.sleep(5)
      await_position(pid, expected, attempts - 1)
    end
  end

  def teleport(client, pid, pose) do
    :ok = Valimc.Connection.teleport(pid, pose)
    {body, client} = await(client, :play, "player_position")
    client = auto_reply(client, :play, "player_position", body)
    await_teleport_ack(pid, 200)
    client
  end

  defp await_teleport_ack(pid, attempts) do
    if :sys.get_state(pid).teleport_pending do
      if attempts == 0, do: raise("Teleport was not acknowledged")
      Process.sleep(5)
      await_teleport_ack(pid, attempts - 1)
    end
  end

  def send_packet(client, phase, name, payload),
    do:
      send_raw(client, Wire.frame(Data.id(phase, :serverbound, name), payload, client.threshold))

  def send_raw(client, bytes) do
    bytes = IO.iodata_to_binary(bytes)

    bytes =
      case Map.get(client, :cipher) do
        nil ->
          bytes

        cipher ->
          {:ok, encrypted} = Encryption.encrypt(cipher, bytes)
          encrypted
      end

    :ok = :gen_tcp.send(client.socket, bytes)
    client
  end

  def read(client) do
    case Wire.next_frame(client.buffer, 2_097_152, client.threshold) do
      {:ok, id, body, rest} ->
        {id, body, %{client | buffer: rest}}

      :more ->
        {:ok, bytes} = :gen_tcp.recv(client.socket, 0, 5000)

        bytes =
          case Map.get(client, :cipher) do
            nil ->
              bytes

            cipher ->
              {:ok, decrypted} = Encryption.decrypt(cipher, bytes)
              decrypted
          end

        read(%{client | buffer: client.buffer <> bytes})

      error ->
        raise "Invalid server frame: #{inspect(error)}"
    end
  end

  def await(client, phase, name, limit \\ 300) do
    if limit == 0, do: raise("Packet #{name} not received")
    {id, body, client} = read(client)
    packet = Data.name(phase, :clientbound, id)

    if packet == name,
      do: {body, client},
      else: await(auto_reply(client, phase, packet, body), phase, name, limit - 1)
  end

  def auto_reply(client, :play, "player_position", body) do
    {id,
     <<x::float-64, y::float-64, z::float-64, _delta::binary-size(24), yaw::float-32,
       pitch::float-32, _flags::32>>} = Wire.take_varint(body)

    send_packet(client, :play, "accept_teleportation", [
      Wire.varint(id),
      <<x::float-64, y::float-64, z::float-64, yaw::float-32, pitch::float-32>>
    ])
  end

  def auto_reply(client, :play, "chunk_batch_finished", _),
    do: send_packet(client, :play, "chunk_batch_received", <<8.0::float-32>>)

  def auto_reply(client, :play, "keep_alive", body),
    do: send_packet(client, :play, "keep_alive", body)

  def auto_reply(client, :play, "container_set_content", body) do
    {container, body} = Wire.take_varint(body)
    {state_id, body} = Wire.take_varint(body)
    {count, body} = Wire.take_varint(body)
    {items, body} = take_items(body, count, [])
    {:ok, carried, <<>>} = ItemStack.take(body)

    Map.put(client, :inventory, %{
      container: container,
      state_id: state_id,
      items: items,
      carried: carried
    })
  end

  def auto_reply(client, :play, "set_experience", <<progress::float-32, rest::binary>>) do
    {level, rest} = Wire.take_varint(rest)
    {total, <<>>} = Wire.take_varint(rest)
    Map.put(client, :experience, %{level: level, progress: progress, total: total})
  end

  def auto_reply(client, :play, "set_held_slot", body) do
    {slot, <<>>} = Wire.take_varint(body)
    Map.put(client, :selected, slot)
  end

  def auto_reply(client, :play, "player_abilities", <<flags, fly::float-32, walk::float-32>>) do
    Map.put(client, :abilities, %{flags: flags, flying_speed: fly, walking_speed: walk})
  end

  def auto_reply(client, :play, "update_attributes", body) do
    {entity, body} = Wire.take_varint(body)
    {count, body} = Wire.take_varint(body)
    {values, <<>>} = take_attributes(body, count, %{})
    values = Map.new(values, fn {id, value} -> {{entity, id}, value} end)
    Map.put(client, :attributes, Map.merge(Map.get(client, :attributes, %{}), values))
  end

  def auto_reply(client, :play, "set_entity_data", body) do
    {id, rest} = Wire.take_varint(body)
    take_metadata(client, id, rest)
  end

  def auto_reply(client, :play, "set_equipment", body) do
    {id, rest} = Wire.take_varint(body)
    take_equipment(client, id, rest)
  end

  def auto_reply(client, _, _, _), do: client

  defp take_attributes(body, 0, values), do: {values, body}

  defp take_attributes(body, count, values) do
    {id, <<base::float-64, body::binary>>} = Wire.take_varint(body)
    {count_modifiers, body} = Wire.take_varint(body)

    {modifiers, body} =
      Enum.map_reduce(List.duplicate(nil, count_modifiers), body, fn _, body ->
        {name, <<amount::float-64, operation, body::binary>>} = Wire.take_string(body)
        {{name, amount, operation}, body}
      end)

    take_attributes(body, count - 1, Map.put(values, id, {base, modifiers}))
  end

  defp take_equipment(client, id, <<flags, rest::binary>>) do
    {:ok, stack, rest} = ItemStack.take(rest)
    slot = Bitwise.band(flags, 127)
    equipment = Map.get(client, :equipment, %{})
    slots = Map.put(Map.get(equipment, id, %{}), slot, stack)
    client = Map.put(client, :equipment, Map.put(equipment, id, slots))
    if flags >= 128, do: take_equipment(client, id, rest), else: client
  end

  defp take_metadata(client, id, <<0, 0, flags, rest::binary>>),
    do: put_metadata(client, id, :entity_flags, flags, rest)

  defp take_metadata(client, id, <<6, 20, pose, rest::binary>>),
    do: put_metadata(client, id, :entity_poses, pose, rest)

  defp take_metadata(client, id, <<8, 0, flags, rest::binary>>),
    do: put_metadata(client, id, :entity_use, flags, rest)

  defp take_metadata(client, id, <<index, 1, rest::binary>>) when index in [1, 7] do
    {value, rest} = Wire.take_varint(rest)
    put_metadata(client, id, if(index == 1, do: :entity_air, else: :entity_frozen), value, rest)
  end

  defp take_metadata(client, id, <<9, 3, health::float-32, rest::binary>>),
    do: put_metadata(client, id, :entity_health, health, rest)

  defp take_metadata(client, _id, _rest), do: client

  defp put_metadata(client, id, key, value, rest),
    do: take_metadata(Map.update(client, key, %{id => value}, &Map.put(&1, id, value)), id, rest)

  defp take_items(body, 0, items), do: {Enum.reverse(items), body}

  defp take_items(body, count, items) do
    {:ok, item, body} = ItemStack.take(body)
    take_items(body, count - 1, [item | items])
  end

  def begin_login(name) do
    client = connect()

    send_packet(client, :handshake, "intention", [
      Wire.varint(777),
      Wire.string("localhost"),
      <<25565::16, 2>>
    ])

    send_packet(client, :login, "hello", [Wire.string(name), <<0::128>>])
    client
  end

  def configure(name), do: configure_session(begin_login(name), name)

  def configure_session(client, name) do
    {_compression_id, body, client} = read(client)
    {threshold, <<>>} = Wire.take_varint(body)
    client = %{client | threshold: threshold}
    {body, client} = await(client, :login, "login_finished")
    <<uuid::binary-size(16), body::binary>> = body
    {^name, body} = Wire.take_string(body)
    {count, body} = Wire.take_varint(body)
    {properties, <<_session_id::binary-size(16)>>} = take_properties(body, count, [])
    client = Map.put(client, :properties, properties)

    client =
      if Map.get(client, :login_ack_sent, false),
        do: client,
        else: send_packet(client, :login, "login_acknowledged", <<>>)

    {packs, client} = await(client, :configuration, "select_known_packs")
    client = send_packet(client, :configuration, "select_known_packs", packs)
    {_, client} = await(client, :configuration, "finish_configuration")
    {uuid, client}
  end

  defp take_properties(body, 0, values), do: {Enum.reverse(values), body}

  defp take_properties(body, count, values) when count in 1..16 do
    {name, body} = Wire.take_string(body)
    {value, <<signed, body::binary>>} = Wire.take_string(body)
    {signature, body} = if signed == 1, do: Wire.take_string(body), else: {nil, body}
    take_properties(body, count - 1, [%{name: name, value: value, signature: signature} | values])
  end

  def login(name), do: login_session(begin_login(name), name)

  def login_session(client, name) do
    {uuid, client} = configure_session(client, name)
    client = send_packet(client, :configuration, "finish_configuration", <<>>)
    {_, client} = await(client, :play, "login")
    {body, client} = await(client, :play, "player_position")

    {_,
     <<x::float-64, y::float-64, z::float-64, _delta::binary-size(24), yaw::float-32,
       pitch::float-32, _flags::32>>} = Wire.take_varint(body)

    client = Map.put(client, :pose, %{x: x, y: y, z: z, yaw: yaw, pitch: pitch})
    client = auto_reply(client, :play, "player_position", body)
    {uuid, client}
  end

  def load_world(client, expected \\ 9, count \\ 0)
  def load_world(client, expected, expected), do: client

  def load_world(client, expected, count) do
    {id, body, client} = read(client)
    name = Data.name(:play, :clientbound, id)
    client = auto_reply(client, :play, name, body)
    load_world(client, expected, count + if(name == "level_chunk_with_light", do: 1, else: 0))
  end
end

defmodule Valimc.TestRegionGate do
  @moduledoc """
  Stall a region for tests: suspend its owner and hold published-snapshot reads
  (compiled in only with `region_read_gates: true`), so geometry stays in flight.
  """
  @table :valimc_region_read_gates

  def stall(pid) do
    ensure_table()
    :ets.insert(@table, {key(pid), pid})
    :sys.suspend(pid)
  end

  def resume(pid) do
    ensure_table()
    :ets.match_delete(@table, {:_, pid})
    if Process.alive?(pid), do: :sys.resume(pid)
    :ok
  end

  defp key(pid) do
    [key] = Registry.keys(Valimc.RegionRegistry, pid)
    key
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      # Owned by a long-lived holder so the table outlives individual tests.
      parent = self()

      spawn(fn ->
        :ets.new(@table, [:named_table, :public, :set])
        send(parent, :gate_table_ready)
        Process.sleep(:infinity)
      end)

      receive do
        :gate_table_ready -> :ok
      end
    end
  end
end

defmodule Valimc.TestPool do
  @moduledoc "Saturate the collision pool partition a given caller (e.g. a connection) uses."
  def partition(caller), do: {:via, PartitionSupervisor, {Valimc.CollisionWorkers, caller}}

  def fill(caller) do
    Stream.repeatedly(fn ->
      Task.Supervisor.start_child(partition(caller), fn ->
        receive do
          :stop -> :ok
        end
      end)
    end)
    |> Enum.take_while(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, pid} -> pid end)
  end

  def active(caller), do: DynamicSupervisor.count_children(partition(caller)).active

  def release(holders) do
    for holder <- holders, Process.alive?(holder) do
      ref = Process.monitor(holder)
      send(holder, :stop)

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      end
    end

    :ok
  end
end

defmodule Valimc.TestDisk do
  @moduledoc """
  Durable region state for tests, independent of the on-disk layout. Writes are
  fixtures for a region whose store is not running (a stopping store is awaited):
  before the region log exists they become legacy files (imported on first open),
  afterwards a log frame.
  """
  alias Valimc.World.{RegionLog, Store}

  def read(base, key, part), do: Store.durable(base, key, part)

  def write(base, key, part, value) when part in [:blocks, :items, :containers] do
    # A store stopping after its owner's death must not race this fixture.
    for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key), do: await_exit(pid)
    dir = Store.log_dir(base, key)

    if File.dir?(dir) do
      {:ok, log, _} = RegionLog.open(dir)
      {:ok, log, _} = RegionLog.append(log, [[{part, value}]])
      :ok = RegionLog.close(log)
    else
      File.mkdir_p!(base)

      case part do
        :blocks ->
          File.write!(
            Store.block_path(base, key),
            :erlang.term_to_binary({:valimc_region, 1, value})
          )

        :items ->
          write_v1(Store.item_path(base, key), value)

        :containers ->
          write_v1(Store.container_path(base, key), value)
      end
    end

    :ok
  end

  defp write_v1(path, nil), do: File.rm(path)
  defp write_v1(path, bytes), do: File.write!(path, bytes)

  @doc """
  Make the running store's next append fail with an I/O error (its segment file
  descriptor is closed). The store reports the failure exactly as for a failing
  disk and stops; nothing reaches the log.
  """
  def break_writer(writer) do
    :sys.replace_state(writer, fn
      %{log: %RegionLog{fd: fd}} = state ->
        :ok = File.close(fd)
        state
    end)

    :ok
  end

  @doc """
  Wait until a broken writer has stopped, so the next owner opens a fresh store
  instead of reclaiming the broken one.
  """
  def await_exit(writer, timeout \\ 2000) do
    ref = Process.monitor(writer)

    receive do
      {:DOWN, ^ref, :process, ^writer, _} -> :ok
    after
      timeout -> raise "store #{inspect(writer)} did not stop"
    end
  end
end

defmodule Valimc.TestConn do
  @moduledoc """
  A connection's state for assertions, with legacy flat views of jobs that moved
  into `Valimc.Session.Jobs` (e.g. `pose_job`), so tests stay independent of the
  internal layout.
  """
  @legacy_jobs [
    pose: :pose_job,
    pickup: :pickup_job,
    mining: :mining_job,
    placement: :placement_job,
    motion: :motion_job,
    experience: :experience_job
  ]

  def state(pid), do: view(:sys.get_state(pid))

  def view(%{jobs: %Valimc.Session.Jobs{} = jobs} = state) do
    Enum.reduce(@legacy_jobs, state, fn {kind, key}, acc ->
      Map.put(acc, key, Valimc.Session.Jobs.get(jobs, kind))
    end)
  end

  def view(state), do: state
end

defmodule Valimc.TestRegion do
  @moduledoc "Region owner probes that do not depend on how durable writes are queued."
  @doc "Whether a durable item/block/container write is planned or in flight."
  def writing?(resource),
    do: resource.item_pending != nil or Map.get(resource, :item_writes, []) != []

  @doc "Whether a durable write is in flight (not merely being planned)."
  def in_flight?(resource),
    do:
      Map.get(resource, :item_writes, []) != [] or
        match?(%{phase: :writing}, resource.item_pending)

  @doc "The oldest in-flight write: a queued item write or the writing slot."
  def in_flight(resource) do
    case Map.get(resource, :item_writes, []) do
      # Queued writes were adopted in memory: their proposal is the owner state.
      [write | _] -> Map.merge(%{items: resource.items, containers: resource.containers}, write)
      [] -> if match?(%{phase: :writing}, resource.item_pending), do: resource.item_pending
    end
  end

  @doc "The block at `position` as collision readers see it (the published snapshot)."
  def published_block({pid, epoch}, {x, _, z} = position) do
    key = Valimc.World.region_key(Valimc.World.chunk_key(x, z))
    {^pid, _, %{items: table}} = Valimc.World.Directory.lookup(key)
    {:ok, _revision, blocks} = Valimc.World.BlockSnapshot.read(table, epoch, [position])
    blocks[position]
  end

  @doc "The token of the oldest in-flight item write, or of the pending slot."
  def write_token(resource) do
    case Map.get(resource, :item_writes, []) do
      [write | _] -> write.token
      [] -> resource.item_pending && resource.item_pending[:token]
    end
  end
end
