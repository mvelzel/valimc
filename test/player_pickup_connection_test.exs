defmodule Valimc.PlayerPickupConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Connection, GameMode, Inventory, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.World.{ItemLedger, Region}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-live-pickup-#{nonce}")
    previous = Valimc.config(:world_path)
    simulation = Valimc.config(:item_simulation)
    Application.put_env(:valimc, :world_path, base)
    Application.put_env(:valimc, :item_simulation, true)
    key = {70000 + rem(nonce, 10000), 1900}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 0.0, pitch: 0.0}
    names = ["Pickup#{nonce}", "Race#{nonce}"]

    on_exit(fn ->
      for player <- Players.all(),
          player.name in names,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

      for name <- names,
          {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, Connection.offline_uuid(name)),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for x <- (rx - 1)..(rx + 1), z <- (rz - 1)..(rz + 1) do
        for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, {x, z}),
            do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

        for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, {x, z}),
            do: DynamicSupervisor.terminate_child(Valimc.RegionStoreSupervisor, pid)
      end

      Application.put_env(:valimc, :world_path, previous)
      Application.put_env(:valimc, :item_simulation, simulation)
      File.rm_rf!(base)
    end)

    %{
      base: base,
      key: key,
      pose: pose,
      names: names,
      name: hd(names),
      uuid: Connection.offline_uuid(hd(names))
    }
  end

  defp seed(c, mode \\ :survival, slots \\ %{}) do
    player =
      Map.merge(c.pose, %{
        game_mode: GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode)
      })

    {:ok, bytes} =
      PlayerSnapshot.encode(c.uuid, PlayerSnapshot.capture(player, %Inventory{slots: slots}))

    path = PlayerStore.path(c.base, c.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp login(c) do
    {_, client} = Client.login(c.name)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    pid = Enum.find(Players.all(), &(&1.name == c.name)).pid
    on_exit(fn -> Client.close(client) end)
    wait(fn -> Valimc.TestConn.state(pid).pose_checked != nil end)
    {client, pid}
  end

  defp wait(fun, tries \\ 600) do
    if result = fun.(),
      do: result,
      else:
        (
          assert tries > 0
          Process.sleep(5)
          wait(fun, tries - 1)
        )
  end

  defp spawn_item(c, stack, dx \\ 0.0) do
    at = {c.pose.x + dx, c.pose.y, c.pose.z}
    key = World.region_key(World.chunk_key(c.pose.x + dx, c.pose.z))
    {:ok, owner} = World.item_owner(key)
    {:ok, handle} = Region.create_item(owner, stack, at)
    {owner, handle, key}
  end

  defp saved(c) do
    {:ok, saved} = PlayerSnapshot.decode(File.read!(PlayerStore.path(c.base, c.uuid)), c.uuid)
    saved
  end

  defp relogin_mode(c, client, pid, mode) do
    Client.close(client)

    wait(fn ->
      not Process.alive?(pid) and Registry.lookup(Valimc.PlayerStoreRegistry, c.uuid) == []
    end)

    original = saved(c)
    next = %{original | game_mode: GameMode.new(mode), flying: false}
    {:ok, bytes} = PlayerSnapshot.encode(c.uuid, next)
    File.write!(PlayerStore.path(c.base, c.uuid), bytes)
    login(c)
  end

  defp records(c, key) do
    {:ok, saved} = ItemLedger.decode(Valimc.TestDisk.read(c.base, key, :items), key)
    saved.records
  end

  defp picked(pid, slot, count) do
    state = Valimc.TestConn.state(pid)
    state.recovery == nil and match?(%{count: ^count}, state.inventory.slots[slot])
  end

  test "automatic whole pickup sends native callback and survives fresh login exactly once", c do
    seed(c)
    {client, pid} = login(c)
    {_owner, {_, _, id, _}, key} = spawn_item(c, ItemStack.new("stone", 7))
    {body, client} = Client.await(client, :play, "take_item_entity")
    {^id, body} = Wire.take_varint(body)
    {collector, body} = Wire.take_varint(body)
    assert collector == Valimc.TestConn.state(pid).player.entity_id
    assert {7, <<>>} == Wire.take_varint(body)
    wait(fn -> picked(pid, 36, 7) end)
    assert records(c, key) == []
    assert saved(c).transfer_sequence == 1 and saved(c).outbox == nil
    Client.close(client)

    wait(fn ->
      not Process.alive?(pid) and Registry.lookup(Valimc.PlayerStoreRegistry, c.uuid) == []
    end)

    {_fresh, next} = login(c)
    assert picked(next, 36, 7)
    assert saved(c).transfer_sequence == 1 and records(c, key) == []
  end

  test "partial capacity mutates inventory/remainder without the native pickup callback", c do
    slots =
      Map.new(9..44, &{&1, ItemStack.new("stone", 64)}) |> Map.put(36, ItemStack.new("stone", 63))

    seed(c, :survival, slots)
    {client, pid} = login(c)
    {_owner, _, key} = spawn_item(c, ItemStack.new("stone", 7))
    wait(fn -> picked(pid, 36, 64) end)
    assert [%{stack: %{count: 6}}] = records(c, key)
    assert saved(c).transfer_sequence == 1
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {packets, _} = until_chat(client)
    refute Enum.any?(packets, fn {name, _} -> name == "take_item_entity" end)
  end

  defp until_chat(client, packets \\ []) do
    {id, body, client} = Client.read(client)
    name = Data.name(:play, :clientbound, id)

    if name == "system_chat",
      do: {Enum.reverse(packets), client},
      else: until_chat(client, [{name, body} | packets])
  end

  test "a full survival inventory refuses; creative overflow consumes without changing slots",
       c do
    slots = Map.new(9..44, &{&1, ItemStack.new("egg", 16)})
    seed(c, :survival, slots)
    {client, pid} = login(c)
    {_owner, _, key} = spawn_item(c, ItemStack.new("stone", 7))
    Process.sleep(300)
    assert Valimc.TestConn.state(pid).inventory.slots == slots
    assert [%{stack: %{count: 7}}] = records(c, key)
    assert saved(c).outbox == nil
    {_client, pid} = relogin_mode(c, client, pid, :creative)
    wait(fn -> records(c, key) == [] and saved(c).outbox == nil end)
    assert Valimc.TestConn.state(pid).inventory.slots == slots
    assert saved(c).transfer_sequence == 1
  end

  test "range and spectator negatives cannot withdraw; adjacent owner contact can", c do
    span = Valimc.config(:region_size) * 16
    c = %{c | pose: %{c.pose | x: elem(c.key, 0) * span + span - 1.5}}
    seed(c, :spectator)
    {client, pid} = login(c)
    {_owner, _, key} = spawn_item(c, ItemStack.new("stone", 7), 2.0)
    assert key != c.key
    Process.sleep(150)
    assert [%{stack: %{count: 7}}] = records(c, key)
    {client, pid} = relogin_mode(c, client, pid, :survival)
    Process.sleep(150)
    assert [%{stack: %{count: 7}}] = records(c, key)
    _client = Client.teleport(client, pid, %{c.pose | x: c.pose.x + 0.8})
    wait(fn -> picked(pid, 36, 7) end)
    assert records(c, key) == [] and saved(c).transfer_sequence == 1
  end

  test "pickup waits for the automatic owner delay clock", c do
    seed(c)
    {client, pid} = login(c)
    {owner, {_, epoch, id, revision}, key} = spawn_item(c, ItemStack.new("stone", 7), 2.0)

    step = %{
      id: id,
      revision: revision,
      position: {c.pose.x + 2.0, c.pose.y, c.pose.z},
      motion: %Valimc.ItemMotionState{no_gravity: true, pickup_delay: 4}
    }

    assert {:ok, [_]} = Region.advance_items(owner, [step])
    _client = Client.teleport(client, pid, %{c.pose | x: c.pose.x + 1.0})
    Process.sleep(100)
    {region, ^epoch} = owner
    assert :sys.get_state(region).resource.items.entries[id].motion.pickup_delay > 0
    assert Valimc.TestConn.state(pid).inventory.slots == %{}
    wait(fn -> picked(pid, 36, 7) end)
    assert records(c, key) == []
  end

  test "two live players racing an item conserve exactly one stack", c do
    second_name = List.last(c.names)
    second = %{c | name: second_name, uuid: Connection.offline_uuid(second_name)}
    seed(c)
    seed(second)
    {_client, pid} = login(c)
    {_second_client, second_pid} = login(second)
    {_owner, _, key} = spawn_item(c, ItemStack.new("stone", 7))
    wait(fn -> records(c, key) == [] end)

    wait(fn ->
      Valimc.TestConn.state(pid).recovery == nil and :sys.get_state(second_pid).recovery == nil
    end)

    totals =
      Enum.map([pid, second_pid], fn p ->
        case :sys.get_state(p).inventory.slots[36] do
          nil -> 0
          stack -> stack.count
        end
      end)

    assert Enum.sort(totals) == [0, 7]
    assert saved(c).outbox == nil and saved(second).outbox == nil
  end

  test "an uncollectable first candidate cannot starve a compatible later item", c do
    slots =
      Map.new(9..44, &{&1, ItemStack.new("stone", 64)}) |> Map.put(36, ItemStack.new("egg", 15))

    seed(c, :survival, slots)
    {_client, pid} = login(c)
    {_owner, _, key} = spawn_item(c, ItemStack.new("dirt", 7))
    spawn_item(c, ItemStack.new("egg"))
    wait(fn -> picked(pid, 36, 16) end)
    assert [%{stack: %{item_id: item, count: 7}}] = records(c, key)
    assert item == ItemStack.new("dirt").item_id
    assert saved(c).transfer_sequence == 1
  end

  test "a late contact grant cannot prepare an intent after the accepted player moves away", c do
    seed(c)
    {client, pid} = login(c)
    {owner, _, key} = spawn_item(c, ItemStack.new("stone", 7), 2.0)
    {region, _} = owner
    writer = :sys.get_state(region).resource.store
    :sys.suspend(writer)

    try do
      client = Client.teleport(client, pid, %{c.pose | x: c.pose.x + 1.0})
      wait(fn -> Valimc.TestRegion.in_flight?(:sys.get_state(region).resource) end)
      _client = Client.teleport(client, pid, %{c.pose | x: c.pose.x - 3.0})
      :sys.resume(writer)
      wait(fn -> Valimc.TestConn.state(pid).pickup_job == nil end)
      assert records(c, key) |> Enum.map(& &1.stack.count) == [7]
      assert Valimc.TestConn.state(pid).inventory.slots == %{} and saved(c).outbox == nil
      assert saved(c).transfer_sequence == 0
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "an expired permission during a paused source save rejects then retries without loss", c do
    seed(c)
    {client, pid} = login(c)
    {_owner, _, key} = spawn_item(c, ItemStack.new("stone", 7), 2.0)
    writer = Valimc.TestConn.state(pid).player_store
    :sys.suspend(writer)

    try do
      _client = Client.teleport(client, pid, %{c.pose | x: c.pose.x + 1.0})
      wait(fn -> match?(%{stage: :prepare}, Valimc.TestConn.state(pid).recovery) end)
      assert saved(c).inventory.slots == %{} and saved(c).outbox == nil
      assert [%{stack: %{count: 7}}] = records(c, key)
      Process.sleep(260)
      :sys.resume(writer)
      wait(fn -> picked(pid, 36, 7) end)
      assert records(c, key) == [] and saved(c).outbox == nil
      assert saved(c).transfer_sequence >= 2
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "disconnect while source preparation is queued retains the intent and recovers on fresh login",
       c do
    seed(c)
    {client, pid} = login(c)
    {_owner, _, key} = spawn_item(c, ItemStack.new("stone", 7), 2.0)
    writer = Valimc.TestConn.state(pid).player_store
    :sys.suspend(writer)

    try do
      client = Client.teleport(client, pid, %{c.pose | x: c.pose.x + 1.0})
      wait(fn -> match?(%{stage: :prepare}, Valimc.TestConn.state(pid).recovery) end)
      Client.close(client)
      Process.sleep(260)
      :sys.resume(writer)

      wait(fn ->
        not Process.alive?(pid) and Registry.lookup(Valimc.PlayerStoreRegistry, c.uuid) == []
      end)

      assert saved(c).outbox == nil and saved(c).inventory.slots == %{}
      assert saved(c).transfer_sequence == 1
      assert [%{stack: %{count: 7}}] = records(c, key)
      {_fresh, next} = login(c)
      wait(fn -> picked(next, 36, 7) end)
      assert records(c, key) == [] and saved(c).transfer_sequence >= 2
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "saturated pickup I/O workers leave the socket responsive and retry after capacity returns",
       c do
    seed(c)
    {client, pid} = login(c)

    workers =
      Stream.repeatedly(fn ->
        Task.Supervisor.start_child(Valimc.TransferWorkers, fn ->
          receive do
            :stop -> :ok
          end
        end)
      end)
      |> Enum.reduce_while([], fn
        {:ok, worker}, acc -> {:cont, [worker | acc]}
        {:error, :max_children}, acc -> {:halt, acc}
      end)

    try do
      {_owner, _, key} = spawn_item(c, ItemStack.new("stone", 7))
      Process.sleep(100)
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {chat, _client} = Client.await(client, :play, "system_chat")
      assert :binary.match(chat, "schedulers") != :nomatch

      assert Valimc.TestConn.state(pid).recovery == nil and
               Valimc.TestConn.state(pid).pickup_job == nil

      assert [%{stack: %{count: 7}}] = records(c, key)
      for worker <- workers, do: Task.Supervisor.terminate_child(Valimc.TransferWorkers, worker)
      wait(fn -> picked(pid, 36, 7) end)
      assert records(c, key) == []
    after
      for worker <- workers,
          Process.alive?(worker),
          do: Task.Supervisor.terminate_child(Valimc.TransferWorkers, worker)
    end
  end
end
