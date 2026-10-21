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
        30_000
      )

    %{socket: socket, buffer: <<>>, threshold: nil}
  end

  def close(client), do: :gen_tcp.close(client.socket)

  def await_position(pid, expected, _budget \\ nil) do
    Valimc.TestWait.until(fn ->
      player = :sys.get_state(pid, 30_000).player
      if Map.take(player, Map.keys(expected)) == expected, do: player
    end)
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
        # Generous on a loaded host; a passing read returns as data arrives (VMC-073).
        {:ok, bytes} = :gen_tcp.recv(client.socket, 0, 30_000)

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

  # The fastest rate vanilla accepts keeps test streams short (VMC-070).
  def auto_reply(client, :play, "chunk_batch_finished", _),
    do: send_packet(client, :play, "chunk_batch_received", <<64.0::float-32>>)

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
    # The position packet precedes the player's listing in `Players`; tests look the
    # player up right after login (VMC-073).
    Valimc.TestWait.until(fn -> Enum.any?(Valimc.Players.all(), &(&1.name == name)) end)
    {uuid, client}
  end

  # Every packet sent before `/stats` has been handled once its reply arrives. Other
  # system chat on the way (join and leave lines) is skipped (VMC-073).
  def barrier(client) do
    client = send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_body, client} = await_stats(client)
    client
  end

  # The reply can trail a long burst (inventory and chunk packets), so the read
  # limit is generous.
  def await_stats(client) do
    {body, client} = await(client, :play, "system_chat", 5000)

    if :binary.match(body, " schedulers") != :nomatch,
      do: {body, client},
      else: await_stats(client)
  end

  # View distance 2, the vanilla minimum the test server allows: 7×7 chunks.
  def load_world(client, expected \\ 49, count \\ 0)
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
  one region log frame, as the store itself writes.
  """
  alias Valimc.World.{RegionLog, Store}

  def read(base, key, part), do: Store.durable(base, key, part)

  def write(base, key, part, value) when part in [:blocks, :items, :containers] do
    # A store stopping after its owner's death must not race this fixture.
    for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key), do: await_exit(pid)
    {:ok, log, _} = RegionLog.open(Store.log_dir(base, key))
    {:ok, log, _} = RegionLog.append(log, [[{part, value}]])
    :ok = RegionLog.close(log)
  end

  @doc """
  Make the running store's next append fail with an I/O error (its segment is
  moved to a directory that does not exist, so it will not open). The store
  reports the failure exactly as for a failing disk and stops; nothing reaches
  the log.
  """
  def break_writer(writer) do
    :sys.replace_state(writer, fn
      %{log: %RegionLog{} = log} = state ->
        %{state | log: %{log | segment: Path.join([log.dir, "missing", "log"])}}
    end)

    :ok
  end

  @doc """
  Wait until a broken writer has stopped, so the next owner opens a fresh store
  instead of reclaiming the broken one.
  """
  def await_exit(writer, timeout \\ 30_000) do
    ref = Process.monitor(writer)

    receive do
      {:DOWN, ^ref, :process, ^writer, _} -> :ok
    after
      timeout -> raise "store #{inspect(writer)} did not stop"
    end
  end
end

defmodule Valimc.TestConn do
  @moduledoc "A connection's state for assertions; its asynchronous jobs live in `Valimc.Session.Jobs`."

  # Generous on a loaded host; a free owner answers at once (VMC-073).
  def state(pid), do: :sys.get_state(pid, 30_000)

  @doc "The connection's active job of `kind` (`:pose`, `:motion`, `:mining`, ...), or nil."
  def job(state, kind), do: Valimc.Session.Jobs.get(state.jobs, kind)
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

  @doc """
  The expiry of a contact grant a test builds itself (container contexts, table
  grants): `ms` scaled like the owner's widest accepted window (VMC-073).
  """
  def grant_expires(ms \\ 250),
    do: System.monotonic_time(:millisecond) + ms * Valimc.config(:owner_call_scale)

  @doc """
  Wait until collision readers see `block` at `position`: the published snapshot
  follows durable writes once the owner is quiescent, which a loaded host can lag
  behind the edit (VMC-073).
  """
  def await_published({x, _, z} = position, block) do
    key = Valimc.World.region_key(Valimc.World.chunk_key(x, z))
    {:ok, owner} = Valimc.World.existing_owner(key)
    Valimc.TestWait.until(fn -> published_block(owner, position) == block end)
    :ok
  end

  @doc "`TestBlocks.set/2`, then `await_published/2`: the edit as collision readers will see it."
  def set_published(position, block) do
    with :ok <- Valimc.TestBlocks.set(position, block), do: await_published(position, block)
  end

  @doc """
  `set_published/2`, then wait until `connection` has seen the edit, as it has before
  its next tick on an idle host: the edit drops geometry it sampled earlier, so a tick
  between the two would have no frame (VMC-073).
  """
  def set_published(position, block, connection) do
    generation = :sys.get_state(connection, 30_000).pose_generation

    with :ok <- set_published(position, block) do
      Valimc.TestWait.until(fn ->
        :sys.get_state(connection, 30_000).pose_generation > generation
      end)

      :ok
    end
  end

  @doc "The block at `position` as collision readers see it (the published snapshot)."
  def published_block({_pid, _epoch}, position),
    do: Valimc.World.View.block(Valimc.World.View.new(), position)

  @doc """
  Expire, now, the deadlines of the grants an owner answers once its in-flight
  writes are durable (pickup and item-merge grants): a test reaches the deadline
  without sleeping past it, however loaded the host (VMC-073).
  """
  def expire_held_replies({pid, _epoch}), do: expire_held_replies(pid)

  def expire_held_replies(pid) do
    past = System.monotonic_time(:millisecond) - 1

    :sys.replace_state(pid, fn s ->
      writes =
        Enum.map(s.resource.item_writes, fn write ->
          held = Enum.map(write.held, fn {from, reply} -> {from, expire(reply, past)} end)
          %{write | reply: expire(write.reply, past), held: held}
        end)

      %{s | resource: %{s.resource | item_writes: writes}}
    end)

    :ok
  end

  defp expire({:pickup_grant, actor, uuid, _}, past), do: {:pickup_grant, actor, uuid, past}
  defp expire({:item_merge_grant, request, _}, past), do: {:item_merge_grant, request, past}
  defp expire(reply, _past), do: reply

  @doc "Expire every permit an owner holds, now (grant lifetimes without sleeping, VMC-073)."
  def expire_permits({pid, _epoch}), do: expire_permits(pid)

  def expire_permits(pid) do
    past = System.monotonic_time(:millisecond) - 1

    :sys.replace_state(pid, fn s ->
      entries =
        Map.new(s.resource.permits.entries, fn {token, e} -> {token, %{e | expires: past}} end)

      %{s | resource: %{s.resource | permits: %{s.resource.permits | entries: entries}}}
    end)

    :ok
  end

  @doc "The token of the oldest in-flight item write, or of the pending slot."
  def write_token(resource) do
    case Map.get(resource, :item_writes, []) do
      [write | _] -> write.token
      [] -> resource.item_pending && resource.item_pending[:token]
    end
  end
end

defmodule Valimc.TestScope do
  @moduledoc """
  Per-owner config for concurrent tests: owners started for the given region keys or
  player UUIDs read `overrides` (e.g. `world_path: base, item_simulation: true`)
  instead of the global app env, until the test exits. See `Valimc.config/2`.
  """
  @table Valimc.ScopedConfig

  @doc "Create the override table, owned by a process that outlives every test."
  def start do
    {:ok, _} = Agent.start(fn -> :ets.new(@table, [:named_table, :public]) end)
    :ok
  end

  @doc "Apply `overrides` to the owners of `scopes` started during this test."
  def isolate(scopes, overrides) do
    rows = for scope <- List.wrap(scopes), {key, value} <- overrides, do: {{scope, key}, value}
    true = :ets.insert(@table, rows)
    ExUnit.Callbacks.on_exit(fn -> Enum.each(rows, &:ets.delete_object(@table, &1)) end)
    :ok
  end

  @doc """
  Cleanup for an owner or store: kill it rather than `terminate_child/2`, whose
  graceful shutdown would hold the shared supervisor (and every concurrent test's
  admissions) while a suspended writer stalls the owner's final flush.
  """
  def kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end
  end

  @doc """
  Teardown before removing a test world: stop the region owners and stores around
  `key`, gracefully so their final writes finish first. A player's view (distance
  2) loads the neighbouring regions, which would otherwise keep writing into the
  removed directory (VMC-073).
  """
  def stop_neighbourhood(key, opts \\ []) do
    # Serial socket tests also stop the regions around the world spawn, which a
    # respawn or a spawn-point join loads with the test's world path.
    regions =
      if opts[:spawn], do: neighborhood(key) ++ neighborhood({0, 0}), else: neighborhood(key)

    for region <- Enum.uniq(regions),
        {registry, supervisor} <- [
          {Valimc.RegionRegistry, Valimc.RegionSupervisor},
          {Valimc.RegionStoreRegistry, Valimc.RegionStoreSupervisor}
        ],
        {pid, _} <- Registry.lookup(registry, region),
        do: DynamicSupervisor.terminate_child(supervisor, pid)

    :ok
  end

  @doc """
  Teardown for serial suites whose every Nether and End owner is their own: stop
  the region owners, proto owners and stores of other dimensions. Their chunks may
  still be generating (VMC-075), and a region or a transaction can start a proto
  owner again, so this repeats until none is left.
  """
  def stop_dimensions do
    elsewhere = [{{{:"$1", :_}, :"$2", :_}, [{:is_atom, :"$1"}], [:"$2"]}]

    running =
      for {registry, supervisor} <- [
            {Valimc.RegionRegistry, Valimc.RegionSupervisor},
            {Valimc.ProtoRegistry, Valimc.ProtoSupervisor},
            {Valimc.RegionStoreRegistry, Valimc.RegionStoreSupervisor}
          ],
          pid <- Registry.select(registry, elsewhere),
          Process.alive?(pid),
          do: {supervisor, pid}

    if running == [] do
      :ok
    else
      for {supervisor, pid} <- running, do: DynamicSupervisor.terminate_child(supervisor, pid)
      stop_dimensions()
    end
  end

  @doc """
  Stop the connections and player stores writing under the world `base`: a store
  writes its player file when its session closes, which can race `File.rm_rf!`
  (VMC-073).
  """
  def stop_players(base) do
    stores =
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Valimc.PlayerStoreSupervisor),
          state = safe_state(pid),
          is_map(state) and String.starts_with?(Map.get(state, :path, ""), base),
          do: {pid, state}

    uuids = MapSet.new(stores, fn {_, state} -> state.uuid end)

    for player <- Valimc.Players.all(),
        MapSet.member?(uuids, player.uuid),
        do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

    for {pid, _} <- stores,
        do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

    :ok
  end

  defp safe_state(pid) do
    :sys.get_state(pid, 30_000)
  catch
    :exit, _ -> nil
  end

  @doc "`key` and the region keys within `radius` of it (owners a handoff may start)."
  def neighborhood({rx, rz}, radius \\ 1),
    do: for(x <- (rx - radius)..(rx + radius), z <- (rz - radius)..(rz + radius), do: {x, z})

  @doc """
  The calling test holds a `:forced` ticket over every chunk of region `key`
  (owner `owner`), so its chunks tick when stepped (VMC-077e).
  """
  def simulate(owner, {rx, rz}) do
    size = Valimc.config(:region_size)
    chunks = for x <- 0..(size - 1), z <- 0..(size - 1), do: {rx * size + x, rz * size + z}
    Valimc.World.Region.ticket(owner, :forced, nil, chunks)
  end
end

defmodule Valimc.TestWait do
  @moduledoc """
  Waiting on a loaded host (VMC-073): poll a condition until it holds or a generous
  wall-clock deadline passes, never a fixed count of short sleeps. A passing wait
  returns as soon as its condition does.
  """
  @deadline 30_000

  @doc "The condition's truthy value once it holds; fails the test at the deadline."
  def until(fun, timeout \\ @deadline) do
    poll(fun, System.monotonic_time(:millisecond) + timeout)
  end

  defp poll(fun, deadline) do
    if value = fun.() do
      value
    else
      if System.monotonic_time(:millisecond) >= deadline,
        do: ExUnit.Assertions.flunk("condition not reached within the deadline")

      Process.sleep(5)
      poll(fun, deadline)
    end
  end
end

defmodule Valimc.TestPlayer do
  @moduledoc """
  One socket player in a private world whose simulation ticks only the test
  drives (VMC-073): `scope/3` in setup, `save/3` for its saved state, `login/2`
  to join with a parked clock and `tick/2` for one owner tick.
  """
  import ExUnit.Assertions
  alias Valimc.{Connection, Players, PlayerSnapshot, PlayerStore}
  alias Valimc.TestClient, as: Client
  alias Valimc.World.Clock

  @doc """
  A fresh `prefix`-named player with manual ticks and a private world near region
  `{x_base + n, z}`. `survival: {difficulty, natural_regeneration}` applies those
  world rules for the test.
  """
  def scope(prefix, {x_base, z}, opts \\ []) do
    nonce = System.unique_integer([:positive])
    name = prefix <> Integer.to_string(nonce)
    uuid = Connection.offline_uuid(name)
    Valimc.TestScope.isolate(uuid, player_ticks: :manual)
    base = Path.join(System.tmp_dir!(), "valimc-#{String.downcase(prefix)}-#{nonce}")
    key = {x_base + rem(nonce, 3_333) * 3, z}
    {rx, rz} = key
    old = Valimc.config(:world_path)
    rules = Clock.survival()

    with {difficulty, regeneration} <- Keyword.get(opts, :survival) do
      :ok = Clock.configure({:difficulty, difficulty, true})
      :ok = Clock.configure({:natural_regeneration, regeneration})
    end

    Application.put_env(:valimc, :world_path, base)

    ExUnit.Callbacks.on_exit(fn ->
      for p <- Players.all(),
          p.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)

      if Keyword.has_key?(opts, :survival) do
        {difficulty, regeneration} = rules
        :ok = Clock.configure({:difficulty, difficulty, true})
        :ok = Clock.configure({:natural_regeneration, regeneration})
      end

      Valimc.TestScope.stop_neighbourhood(key, spawn: true)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{
      name: name,
      uuid: uuid,
      key: key,
      base: base,
      path: PlayerStore.path(base, uuid),
      pose: %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}
    }
  end

  @doc "Write `player` (a pose and saved fields) with `inventory` as the saved player."
  def save(ctx, player, inventory) do
    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, inventory))
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
  end

  def state(pid), do: Valimc.TestConn.state(pid)

  @doc "The connection's `%Valimc.Living{}`."
  def living(pid), do: state(pid).player.living

  @doc "Replace fields of the connection's living state (`fields`, or a function of it)."
  def put_living(pid, fields) do
    update = if is_function(fields, 1), do: fields, else: &struct!(&1, fields)

    :sys.replace_state(pid, fn s ->
      %{s | player: %{s.player | living: update.(s.player.living)}}
    end)
  end

  @doc "Retire the wall-clock tick, so only `tick/2` runs the owner's simulation."
  def park(pid) do
    :sys.replace_state(pid, fn s ->
      clock = %{
        s.simulation_clock
        | token: {s.simulation_clock.epoch, make_ref()},
          deadline: System.monotonic_time(:millisecond) + 60_000
      }

      %{s | simulation_clock: clock}
    end)
  end

  @doc """
  Join as the scope's player with a parked clock. `before_load` reads packets that
  precede the world (`fn client, pid -> client end`); `loaded: false` withholds the
  client's load acknowledgement.
  """
  def login(ctx, opts \\ []) do
    {_, client} = Client.login(ctx.name)
    pid = Valimc.TestWait.until(fn -> Enum.find(Players.all(), &(&1.name == ctx.name)) end).pid
    park(pid)
    client = Keyword.get(opts, :before_load, fn client, _ -> client end).(client, pid)
    client = Client.load_world(client)
    loaded = Keyword.get(opts, :loaded, true)
    if loaded, do: Client.send_packet(client, :play, "player_loaded", <<>>)

    Valimc.TestWait.until(fn ->
      s = state(pid)
      not s.teleport_pending and (not loaded or Valimc.PlayerInput.loaded?(s.player.input))
    end)

    ExUnit.Callbacks.on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  @doc """
  One owner tick with a single-use token, after which the clock is parked again.
  `settle: true` then waits for the player's geometry work, `:alive` only while
  the player lives, `:simulation` also for the owner's simulation step. Returns
  the token.
  """
  def tick(pid, settle \\ false) do
    before =
      :sys.replace_state(pid, fn s ->
        %{
          s
          | simulation_clock: %{
              s.simulation_clock
              | deadline: System.monotonic_time(:millisecond)
            }
        }
      end)

    send(pid, {:player_tick, before.simulation_clock.token})
    assert state(pid).simulation_clock.tick == before.simulation_clock.tick + 1
    park(pid)

    if settle do
      Valimc.TestWait.until(fn ->
        s = state(pid)

        (settle == :alive and s.life_stage != :alive) or
          (Valimc.TestConn.job(s, :pose) == nil and Valimc.TestConn.job(s, :motion) == nil and
             (settle != :simulation or not s.simulation_due))
      end)
    end

    before.simulation_clock.token
  end

  def ticks(pid, count, settle \\ false), do: Enum.each(1..count, fn _ -> tick(pid, settle) end)
end

defmodule Valimc.TestBlocks do
  @moduledoc """
  Block reads and writes for tests through the fenced owner API (VMC-077a):
  `Valimc.World` has no raw block calls. A read or write of a chunk that is
  still generating waits for it, as the region generates the chunks it is
  asked about.
  """
  alias Valimc.World
  alias Valimc.World.Region

  @doc "The block at `position`, read by its owner (`Region.observe_blocks/2`)."
  def get(position) do
    {_owner, view} = observe(position)
    view.blocks[position]
  end

  @doc """
  Write `block` at `position` at the fence it was read at: `:ok` or `{:error,
  reason}`. A block entity type ValiMC does not model is written without its
  record, as fixtures need.
  """
  def set(position, block, attempts \\ 3) do
    {owner, view} = observe(position)

    case Region.set_blocks(owner, view.fence, %{position => block}, MapSet.new([position])) do
      {:ok, _revision} -> :ok
      {:error, :stale_revision} when attempts > 0 -> set(position, block, attempts - 1)
      error -> error
    end
  end

  @doc "Remove the block at `position` as creative destruction does (keeping contained fluid)."
  def remove(position) do
    {owner, view} = observe(position)
    deadline = System.monotonic_time(:millisecond) + Valimc.Txn.Permits.window(250)

    case Region.destroy_block(owner, view.fence, position, deadline) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp observe({x, _, z} = position) do
    key = World.region_key(World.chunk_key(x, z))

    Valimc.TestWait.until(
      fn ->
        with {:ok, owner} <- World.owner(key),
             {:ok, view} <- Region.observe_blocks(owner, [position]) do
          {owner, view}
        else
          {:error, reason}
          when reason in [
                 :chunk_generating,
                 :region_unavailable,
                 :region_restarting,
                 :stale_owner
               ] ->
            nil
        end
      end,
      120_000
    )
  end
end
