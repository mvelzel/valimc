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
        Valimc.Net.Listener.port(),
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
    :ok = Valimc.Net.Connection.teleport(pid, pose)
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

  @doc "Read until the entity `id` spawns."
  def await_spawn(client, id) do
    {body, client} = await(client, :play, "add_entity")
    if match?({^id, _}, Wire.take_varint(body)), do: client, else: await_spawn(client, id)
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
    # The position packet precedes the player's listing in `PlayerList`; tests look the
    # player up right after login (VMC-073).
    Valimc.TestWait.until(fn -> Enum.any?(Valimc.Player.PlayerList.all(), &(&1.name == name)) end)
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
  Stall a region owner for tests (suspend it): its calls and commits wait,
  while its published snapshots stay readable as they are.
  """
  def stall(pid), do: :sys.suspend(pid)

  def resume(pid) do
    if Process.alive?(pid), do: :sys.resume(pid)
    :ok
  end
end

defmodule Valimc.TestDisk do
  @moduledoc """
  Durable region state for tests, in the owners' codec formats: what a region's
  checkpoint and log frames hold (`RegionStorage.records/3`), and fixtures
  written as its checkpoint while the region does not run.
  """
  alias Valimc.Storage.{Checkpoint, Log}
  alias Valimc.World.{Containers, RegionStorage}
  alias Valimc.Entity.Store

  @junk "corrupt"

  @doc """
  `:items` as `%{records, ledger}` (the entity records and the handoff
  ledger), `:containers` as their
  codec encodes them (nil while empty), `:blocks` the cells not folded into
  column images; `:corrupt` when the checkpoint is unreadable.
  """
  def read(base, key, part) do
    case RegionStorage.read(base, :overworld, key) do
      {:ok, parts} -> encode(part, key, parts)
      {:error, :invalid_checkpoint} -> :corrupt
    end
  end

  defp encode(:blocks, _key, parts), do: parts.cells

  defp encode(:items, _key, parts) do
    if parts.items == [] and parts.ledger == Store.empty_ledger(),
      do: nil,
      else: %{records: parts.items, ledger: parts.ledger}
  end

  defp encode(:containers, key, parts) do
    if parts.containers == %Containers{} do
      nil
    else
      {:ok, bytes} = Containers.encode(key, parts.containers)
      bytes
    end
  end

  @doc """
  Replace `part` of a region that is not running: `:items` as `%{records}`
  (and optionally `ledger`), `:containers` bytes of their codec (nil
  for none), `:blocks` cells to add.
  """
  def write(base, key, part, value) when part in [:blocks, :items, :containers] do
    {:ok, seq, records} = RegionStorage.records(base, :overworld, key)

    records =
      records
      |> Map.reject(fn {record, _} -> part != :blocks and owns?(part, record) end)
      |> Map.merge(records(part, key, value))

    :ok = Checkpoint.write(path(base, key), seq, records)
  end

  defp owns?(:items, {kind, _}) when kind in [:entity, :handoff, :handoff_in],
    do: true

  defp owns?(:containers, {kind, _}) when kind in [:container, :containers],
    do: true

  defp owns?(_, _), do: false

  defp records(_part, _key, nil), do: %{}

  defp records(:blocks, _key, cells),
    do: Map.new(cells, fn {pos, block} -> {{:cell, pos}, block} end)

  defp records(:items, key, data) do
    ledger = Map.get(data, :ledger, Store.empty_ledger())
    {:ok, items} = Store.restore(key, data.records, ledger)

    RegionStorage.part_records(:items, items)
  end

  defp records(:containers, key, bytes) do
    {:ok, containers} = Containers.decode(bytes, key)
    RegionStorage.part_records(:containers, containers)
  end

  @doc "Make a stopped region's checkpoint unreadable; `repair/2` undoes it."
  def corrupt(base, key) do
    path = path(base, key)

    original =
      case File.read(path) do
        {:ok, bytes} -> bytes
        {:error, :enoent} -> ""
      end

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, original <> @junk)
  end

  def repair(base, key) do
    path = path(base, key)
    bytes = File.read!(path)

    case binary_part(bytes, 0, byte_size(bytes) - byte_size(@junk)) do
      "" -> File.rm!(path)
      original -> File.write!(path, original)
    end
  end

  defp path(base, key), do: Checkpoint.path(base, {:region, :overworld, key})

  @doc """
  The log stripe section `key` of the world at `base` commits to (started if
  needed): its group's (VMC-077j), once the regionizer has placed it.
  """
  def stripe(base, key) do
    route = route(key)
    :ok = Log.sync(base, route)
    [{pid, _}] = Registry.lookup(Valimc.StorageRegistry, {base, Log.stripe(route)})
    pid
  end

  defp route(key) do
    _ = Valimc.World.Regionizer.groups(:overworld)

    case Valimc.TestWorld.lookup(key) do
      {pid, _, _} -> :sys.get_state(pid, 30_000).route
      nil -> {:region, :overworld, key}
    end
  end

  @doc """
  Make the next append of region `key`'s stripe fail with an I/O error (its
  segment moved to a directory that does not exist, so it will not open): the
  owners whose frames it held stop, as for a failing disk; nothing reaches the
  log. The stripe appends again once the directory exists.
  """
  def break_log(base, key) do
    :sys.replace_state(stripe(base, key), fn %{log: log} = state ->
      %{state | log: %{log | segment: Path.join([log.dir, "missing", "log"])}}
    end)

    :ok
  end

  def await_exit(pid, timeout \\ 30_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      timeout -> raise "#{inspect(pid)} did not stop"
    end
  end
end

defmodule Valimc.TestConn do
  @moduledoc "A connection's state for assertions; its asynchronous jobs live in `Valimc.Player.Jobs`."

  # Generous on a loaded host; a free owner answers at once (VMC-073).
  # A connection answers with its session merged in, wherever the session runs
  # (VMC-077i3); any other process with its state.
  def state(pid, timeout \\ 30_000) do
    if connection?(pid),
      do: GenServer.call(pid, :debug_state, timeout),
      else: :sys.get_state(pid, timeout)
  end

  @doc "Replace the session wherever it runs; returns the new state, as `:sys.replace_state/2`."
  def replace(pid, fun) do
    if connection?(pid),
      do: GenServer.call(pid, {:debug_update, fun}, 30_000),
      else: :sys.replace_state(pid, fun)
  end

  defp connection?(pid) when is_pid(pid),
    do: match?({Valimc.Net.Connection, :init, _}, :proc_lib.initial_call(pid))

  defp connection?(_), do: false

  @doc "The connection's active job of `kind` (`:mining`, `:placement`, ...), or nil."
  def job(state, kind), do: Valimc.Player.Jobs.get(state.jobs, kind)
end

defmodule Valimc.TestRegion do
  @moduledoc "Region owner probes that do not depend on how durable writes are queued."

  @doc """
  The state of a section (VMC-077j): of an owner handle `{pid, epoch}`
  wherever the section moved since, or of group `pid`'s section `key` (its
  only or first section by default).
  """
  def section(owner, key \\ nil)

  def section({pid, epoch}, nil) when is_pid(pid) and is_reference(epoch) do
    state = :sys.get_state(pid, 30_000)

    case state.epochs do
      %{^epoch => key} -> state.sections[key].resource
      _ -> section({moved_to!(state, epoch), epoch})
    end
  end

  def section(pid, key) when is_pid(pid) do
    sections = :sys.get_state(pid, 30_000).sections
    key = key || sections |> Map.keys() |> Enum.min()
    sections[key].resource
  end

  # The group the section of `epoch` moved to from this one.
  defp moved_to!(state, epoch) do
    case state.moved do
      %{^epoch => {pid, _}} -> pid
      _ -> raise "no section of epoch #{inspect(epoch)} here or moved from here"
    end
  end

  @doc "Change a section's state: of an owner handle, or group `pid`'s (`key`, or its first)."
  def replace_section(owner, fun, key \\ nil)

  def replace_section({pid, epoch}, fun, nil) when is_pid(pid) and is_reference(epoch) do
    # In one step with the lookup, so a move cannot come between them.
    moved =
      :sys.replace_state(pid, fn s ->
        case s.epochs do
          %{^epoch => key} ->
            %{s | sections: Map.update!(s.sections, key, &%{&1 | resource: fun.(&1.resource)})}

          _ ->
            s
        end
      end)

    case moved.epochs do
      %{^epoch => _} -> :ok
      _ -> replace_section({moved_to!(moved, epoch), epoch}, fun)
    end
  end

  def replace_section(pid, fun, key) when is_pid(pid) do
    :sys.replace_state(pid, fn s ->
      key = key || s.sections |> Map.keys() |> Enum.min()
      %{s | sections: Map.update!(s.sections, key, &%{&1 | resource: fun.(&1.resource)})}
    end)

    :ok
  end

  @doc "Whether a durable mutation is being planned or a frame (or a reply on one) is in flight."
  def writing?(resource),
    do:
      Valimc.World.Jobs.running?(resource.jobs, :plan) or
        Valimc.World.RegionStorage.busy?(resource.storage)

  @doc "Whether a frame of the owner is on its way to the log."
  def in_flight?(resource), do: map_size(resource.storage.in_flight) > 0

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
    {:ok, owner} = Valimc.TestWorld.existing_owner(key)
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

  @doc "Expire every permit an owner holds, now (grant lifetimes without sleeping, VMC-073)."
  def expire_permits({pid, _epoch}), do: expire_permits(pid)

  def expire_permits(pid) do
    past = System.monotonic_time(:millisecond) - 1

    Valimc.TestRegion.replace_section(pid, fn resource ->
      entries =
        Map.new(resource.permits.entries, fn {token, e} -> {token, %{e | expires: past}} end)

      %{resource | permits: %{resource.permits | entries: entries}}
    end)
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
  Teardown before removing a test world: stop the region owners around
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
        {pid, _} <- Valimc.TestWorld.registered(region),
        do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

    :ok
  end

  @doc """
  Teardown for serial suites whose every Nether and End owner is their own: stop
  the region owners and generation schedulers of other dimensions. Their chunks
  may still be generating (VMC-075), and a region can start a scheduler again,
  so this repeats until none is left.
  """
  def stop_dimensions do
    elsewhere = [{{{:"$1", :_, :_}, :"$2", :_}, [{:"=/=", :"$1", :overworld}], [:"$2"]}]
    schedulers = [{{{:_, :"$1"}, :"$2", :_}, [{:"=/=", :"$1", :overworld}], [:"$2"]}]

    running =
      for {registry, supervisor, pattern} <- [
            {Valimc.RegionRegistry, Valimc.RegionSupervisor, elsewhere},
            {Valimc.Worldgen.Schedulers, Valimc.Worldgen.SchedulerSupervisor, schedulers}
          ],
          pid <- Registry.select(registry, pattern),
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
  Stop the connections whose players save under the world `base` and wait
  until their files hold their last frames, so no save races `File.rm_rf!`
  (VMC-073).
  """
  def stop_players(base) do
    players =
      for player <- Valimc.Player.PlayerList.all(),
          match?(%{storage: %{base: b}} when is_binary(b), state = safe_state(player.pid)),
          String.starts_with?(state.storage.base, base),
          do: player

    for player <- players,
        do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

    for player <- players,
        do:
          Valimc.TestWait.until(fn ->
            Registry.lookup(Valimc.PlayerRegistry, player.uuid) == []
          end)

    :ok
  end

  defp safe_state(pid) do
    Valimc.TestConn.state(pid)
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
  def simulate(owner, {rx, rz} = key) do
    size = Valimc.config(:region_size)
    chunks = for x <- 0..(size - 1), z <- 0..(size - 1), do: {rx * size + x, rz * size + z}
    Valimc.World.Region.ticket(owner, key, :forced, nil, chunks)
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
  alias Valimc.Net.Connection
  alias Valimc.Player.PlayerList
  alias Valimc.Player.State, as: PlayerState
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
      for p <- PlayerList.all(),
          p.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

      for {pid, _} <- Valimc.TestWorld.registered(key),
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
      path: Valimc.Player.Storage.path(base, uuid),
      pose: %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}
    }
  end

  @doc "Write `player` (a pose and saved fields) with `inventory` as the saved player."
  def save(ctx, player, inventory) do
    {:ok, bytes} = PlayerState.encode(ctx.uuid, PlayerState.capture(player, inventory))
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
  end

  def state(pid), do: Valimc.TestConn.state(pid)

  @doc "Wait until the player's file holds the live state of the connection `pid`'s session."
  def checkpointed(pid) do
    Valimc.TestWait.until(fn ->
      send(pid, :save_player_now)
      %{storage: storage} = state = Valimc.TestConn.state(pid)

      storage.seq == storage.checkpoint_seq and storage.checkpointing == nil and
        PlayerState.records(PlayerState.capture(state.player, state.inventory)) ==
          storage.committed
    end)
  end

  @doc """
  The player's file once it satisfies `predicate`, asking the session of the
  connection `pid` for a checkpoint (`/save-all`) meanwhile (VMC-077i3).
  """
  def saved(%{path: path, uuid: uuid}, pid, predicate \\ fn _ -> true end) do
    Valimc.TestWait.until(fn ->
      send(pid, :save_player_now)

      with {:ok, bytes} <- File.read(path),
           {:ok, saved} <- PlayerState.decode(bytes, uuid),
           true <- predicate.(saved) do
        saved
      else
        _ -> false
      end
    end)
  end

  @doc "The connection's `%Valimc.Living{}`."
  def living(pid), do: state(pid).player.living

  @doc "Replace fields of the connection's living state (`fields`, or a function of it)."
  def put_living(pid, fields) do
    update = if is_function(fields, 1), do: fields, else: &struct!(&1, fields)

    Valimc.TestConn.replace(pid, fn s ->
      %{s | player: %{s.player | living: update.(s.player.living)}}
    end)
  end

  @doc "Retire the wall-clock tick, so only `tick/2` runs the owner's simulation."
  def park(pid) do
    Valimc.TestConn.replace(pid, fn s ->
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
    pid = Valimc.TestWait.until(fn -> Enum.find(PlayerList.all(), &(&1.name == ctx.name)) end).pid
    park(pid)
    client = Keyword.get(opts, :before_load, fn client, _ -> client end).(client, pid)
    client = Client.load_world(client)
    loaded = Keyword.get(opts, :loaded, true)
    if loaded, do: Client.send_packet(client, :play, "player_loaded", <<>>)

    Valimc.TestWait.until(fn ->
      s = state(pid)
      not s.teleport_pending and (not loaded or Valimc.Player.Input.loaded?(s.player.input))
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
      Valimc.TestConn.replace(pid, fn s ->
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

        (settle == :alive and s.life_stage != :alive) or settle != :simulation or
          not s.simulation_due
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
        with {:ok, owner} <- Valimc.TestWorld.owner(key),
             {:ok, view} <- Region.observe_blocks(owner, [position]) do
          {owner, view}
        else
          {:error, {:retry, _}} ->
            nil
        end
      end,
      120_000
    )
  end
end

defmodule Valimc.TestWorld do
  @moduledoc """
  World routing for tests (VMC-077j): sections named by plain keys `{sx, sz}`
  of the test process's dimension (the overworld unless it set one), by
  addresses `{dimension, {sx, sz}}` or by section keys `{dimension, sx, sz}`.
  """
  alias Valimc.World

  def section({_, _, _} = key), do: key
  def section({dimension, {sx, sz}}) when is_atom(dimension), do: {dimension, sx, sz}

  def section({sx, sz}) when is_integer(sx) and is_integer(sz),
    do: {Valimc.World.Dimension.current(), sx, sz}

  def owner(key), do: World.owner(section(key))
  def existing_owner(key), do: World.existing_owner(section(key))
  def item_owner(key), do: World.item_owner(section(key))
  def region(key), do: World.region(section(key))
  def lookup(key), do: World.Directory.lookup(section(key))
  def admit(key), do: World.Directory.admit(section(key))
  def registered(key), do: Registry.lookup(Valimc.RegionRegistry, section(key))
  def item_snapshot(key), do: World.item_snapshot(section(key))
  def chunk(chunk), do: World.chunk(Valimc.World.Dimension.current(), chunk)
  def sendable(keys, limit), do: World.sendable(Valimc.World.Dimension.current(), keys, limit)

  def subscribe(keys, previous),
    do: World.subscribe(MapSet.new(keys, &section/1), MapSet.new(previous, &section/1))

  def visible_items(keys, chunks), do: World.visible_items(MapSet.new(keys, &section/1), chunks)
end

defmodule Valimc.TestMenu do
  @moduledoc """
  The click engine (`Valimc.Menus.Click`) at inventory addresses, in the shape
  inventory tests use: `plan/4` gives `{:ok, inventory, drops}`, `click/4`
  `{:ok, inventory}` and refuses drops. The open grid picks the menu.
  """
  alias Valimc.Menus.{Menu, Click}

  def plan(inventory, action, address, button) do
    menu = Menu.crafting(inventory)

    case Click.plan(menu, nil, inventory, action, wire(menu, address), button) do
      {:ok, nil, next, drops} -> {:ok, next, drops}
      error -> error
    end
  end

  def click(inventory, action, address, button) do
    case plan(inventory, action, address, button) do
      {:ok, next, []} -> {:ok, next}
      {:ok, _, [_ | _]} -> {:error, :world_drop_required}
      error -> error
    end
  end

  defp wire(%{kind: :table}, {:table, index}), do: index + 1
  defp wire(%{kind: :table}, slot) when slot in 9..44, do: slot + 1
  defp wire(_menu, slot), do: slot
end
