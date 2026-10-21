defmodule Valimc.PlayerPlacementConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Connection, GameMode, Inventory, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-live-place-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {70_000 + rem(nonce, 3_333) * 3, 1800}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 0.0, pitch: 0.0}
    name = "Place#{nonce}"
    uuid = Connection.offline_uuid(name)

    on_exit(fn ->
      for player <- Players.all(),
          player.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for x <- (rx - 1)..(rx + 1),
          z <- (rz - 1)..(rz + 1),
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, {x, z}),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{
      base: base,
      key: key,
      pose: pose,
      name: name,
      uuid: uuid,
      target: {floor(pose.x), 64, floor(pose.z) + 3}
    }
  end

  defp seed(c, mode \\ :creative, slots \\ %{}) do
    player =
      Map.merge(c.pose, %{
        game_mode: GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode)
      })

    inventory = %Inventory{
      slots:
        Map.merge(
          %{
            36 => ItemStack.new("stone", 7),
            37 => ItemStack.new("oak_slab", 9),
            45 => ItemStack.new("oak_slab", 11)
          },
          slots
        )
    }

    {:ok, bytes} = PlayerSnapshot.encode(c.uuid, PlayerSnapshot.capture(player, inventory))
    path = PlayerStore.path(c.base, c.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    :ok = World.set_block(c.target, 0)
  end

  defp login(c, loaded \\ true) do
    {_, client} = Client.login(c.name)
    client = Client.load_world(client)
    if loaded, do: Client.send_packet(client, :play, "player_loaded", <<>>)
    pid = Enum.find(Players.all(), &(&1.name == c.name)).pid
    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp send_place(client, position, face \\ 1, y \\ 0.5, hand \\ 0, seq \\ 1) do
    Client.send_packet(client, :play, "use_item_on", [
      Wire.varint(hand),
      Wire.position(position),
      Wire.varint(face),
      <<0.5::float-32, y::float-32, 0.5::float-32, 0, 0>>,
      Wire.varint(seq)
    ])
  end

  defp ack(client, seq \\ 1) do
    {bytes, client} = Client.await(client, :play, "block_changed_ack")
    assert {seq, <<>>} == Wire.take_varint(bytes)
    client
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  test "survival chest placement consumes either hand, owns an immediately usable menu and survives login",
       c do
    c = %{c | pose: %{c.pose | yaw: 90.0}}
    seed(c, :survival, %{36 => ItemStack.new("chest", 2), 45 => ItemStack.new("chest", 3)})
    {client, pid} = login(c)
    send_place(client, c.target)
    client = ack(client)
    {:ok, dry} = Valimc.Physics.ChestPlacement.single_state(90.0, 0)
    assert World.get_block(c.target) == dry
    assert Valimc.TestConn.state(pid).inventory.slots[36] == ItemStack.new("chest")
    {x, y, z} = c.target
    wet = {x - 2, y, z}
    :ok = World.set_block(wet, 89)
    send_place(client, wet, 1, 0.5, 1, 2)
    client = ack(client, 2)
    {:ok, wet_state} = Valimc.Physics.ChestPlacement.single_state(90.0, 89)
    assert World.get_block(wet) == wet_state
    assert Valimc.TestConn.state(pid).inventory.slots[45] == ItemStack.new("chest", 2)

    # Horizontal neighbors would need double-chest behavior, so refuse before spending a source sequence.
    send_place(client, {x + 1, y, z}, 1, 0.5, 0, 3)
    client = ack(client, 3)
    assert World.get_block({x + 1, y, z}) == 0
    assert saved(c).transfer_sequence == 2 and saved(c).outbox == nil
    assert Valimc.TestConn.state(pid).inventory.slots[36] == ItemStack.new("chest")

    send_place(client, c.target, 1, 0.5, 0, 4)
    client = ack(client, 4)
    {_body, client} = Client.await(client, :play, "open_screen")
    assert Valimc.TestConn.state(pid).table_menu.position == c.target
    Client.close(client)

    wait(fn ->
      not Process.alive?(pid) and Registry.lookup(Valimc.PlayerStoreRegistry, c.uuid) == []
    end)

    {_fresh, fresh_pid} = login(c)
    assert :sys.get_state(fresh_pid).inventory.slots[36] == ItemStack.new("chest")
    assert :sys.get_state(fresh_pid).inventory.slots[45] == ItemStack.new("chest", 2)
    assert saved(c).transfer_sequence == 2 and saved(c).outbox == nil
    {:ok, {region, _}} = World.existing_owner(c.key)
    containers = :sys.get_state(region).resource.containers
    assert containers.sequence == 2 and containers.receipts == %{}
    assert containers.entries[c.target].slots == Tuple.duplicate(nil, 27)
    assert containers.entries[wet].slots == Tuple.duplicate(nil, 27)
    assert World.item_snapshot(c.key) == %{}
  end

  test "unsupported block entities are corrected without a shell or item loss", c do
    # Default states the 26.3 client sent for a copper chest and a barrel; the owner
    # refuses them too (placement_owner_test).
    held = %{36 => ItemStack.new("copper_chest", 2), 45 => ItemStack.new("barrel", 3)}
    seed(c, :survival, held)
    {x, y, z} = c.target
    floor = {x, y - 1, z}
    :ok = World.set_block(floor, 1)
    {client, pid} = login(c)

    # Click the solid floor's top face, as the client did, so the item targets the air above it.
    Enum.reduce([{0, 1}, {1, 2}], client, fn {hand, seq}, client ->
      send_place(client, floor, 1, 0.5, hand, seq)
      client |> ack(seq) |> corrected(c.target)
    end)

    assert World.get_block(c.target) == 0
    assert Map.take(Valimc.TestConn.state(pid).inventory.slots, [36, 45]) == held
    {:ok, {region, _}} = World.existing_owner(c.key)
    assert :sys.get_state(region).resource.containers.entries == %{}
  end

  # The client's predicted block in the target air cell is reset.
  defp corrected(client, position) do
    {bytes, client} = Client.await(client, :play, "block_update")

    if bytes == IO.iodata_to_binary([Wire.position(position), Wire.varint(0)]),
      do: client,
      else: corrected(client, position)
  end

  test "survival consumes owned main/offhand stacks and persists wet/double placements across fresh login",
       c do
    seed(c, :survival)
    {client, pid} = login(c)
    send_place(client, c.target)
    client = ack(client)
    assert World.get_block(c.target) == 1
    assert Valimc.TestConn.state(pid).inventory.slots[36].count == 6
    :ok = World.set_block(c.target, 89)
    send_place(client, c.target, 1, 0.5, 1, 2)
    client = ack(client, 2)
    assert World.get_block(c.target) == 15_179
    assert Valimc.TestConn.state(pid).inventory.slots[45].count == 10
    send_place(client, c.target, 1, 0.5, 1, 3)
    client = ack(client, 3)
    assert World.get_block(c.target) == 15_182
    assert Valimc.TestConn.state(pid).inventory.slots[45].count == 9
    assert saved(c).transfer_sequence == 3 and saved(c).outbox == nil
    assert World.item_snapshot(c.key) == %{}
    Client.close(client)

    wait(fn ->
      not Process.alive?(pid) and Registry.lookup(Valimc.PlayerStoreRegistry, c.uuid) == []
    end)

    {_fresh, fresh_pid} = login(c)
    assert :sys.get_state(fresh_pid).inventory.slots[36].count == 6
    assert :sys.get_state(fresh_pid).inventory.slots[45].count == 9
    assert World.get_block(c.target) == 15_182
  end

  defp saved(c) do
    {:ok, snapshot} = PlayerSnapshot.decode(File.read!(PlayerStore.path(c.base, c.uuid)), c.uuid)
    snapshot
  end

  test "survival body, occupied, reach and unloaded refusals preserve source stacks and counters",
       c do
    seed(c, :survival)
    {client, pid} = login(c, false)
    before = Valimc.TestConn.state(pid).inventory.slots
    send_place(client, c.target)
    client = ack(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    feet = {floor(c.pose.x), 64, floor(c.pose.z)}
    send_place(client, feet, 1, 0.5, 0, 2)
    client = ack(client, 2)
    assert World.get_block(feet) == 0
    {x, y, z} = c.target
    assert :ok = World.set_block(c.target, 1)
    assert :ok = World.set_block({x, y + 1, z}, 15)
    send_place(client, c.target, 1, 0.5, 0, 3)
    client = ack(client, 3)
    send_place(client, {x, y, z + 40}, 1, 0.5, 0, 4)
    _client = ack(client, 4)
    assert World.get_block({x, y + 1, z}) == 15
    assert Valimc.TestConn.state(pid).inventory.slots == before
    assert :sys.get_state(Valimc.TestConn.state(pid).player_store).snapshot.transfer_sequence == 0
  end

  test "pending source save blocks selection, not chat or world reads, and precedes destination mutation",
       c do
    seed(c, :survival)
    {client, pid} = login(c)
    writer = Valimc.TestConn.state(pid).player_store
    :sys.suspend(writer)

    try do
      send_place(client, c.target)
      wait(fn -> match?(%{stage: :prepare}, Valimc.TestConn.state(pid).recovery) end)
      Client.send_packet(client, :play, "set_carried_item", <<1::signed-16>>)
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_body, client} = Client.await_stats(client)
      assert Valimc.TestConn.state(pid).inventory.selected == 0
      assert Valimc.TestConn.state(pid).inventory.slots[36].count == 7
      assert World.get_block(c.target) == 0
      :sys.resume(writer)
      _client = ack(client)
      assert World.get_block(c.target) == 1
      assert Valimc.TestConn.state(pid).inventory.slots[36].count == 6
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "disconnect during destination storage recovers the already-consumed stack exactly once",
       c do
    seed(c, :survival)
    {client, pid} = login(c)
    {:ok, {region, _} = owner} = World.existing_owner(c.key)
    writer = :sys.get_state(region).resource.store
    :sys.suspend(writer)

    try do
      send_place(client, c.target)
      wait(fn -> Enum.any?(:sys.get_state(region).resource.item_writes, & &1.blocks) end)
      assert saved(c).outbox.kind == :placement
      assert saved(c).inventory.slots[36].count == 6
      assert Valimc.TestRegion.published_block(owner, c.target) == 0
      Client.close(client)
      wait(fn -> not Process.alive?(pid) end)
      :sys.resume(writer)
      wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, c.uuid) == [] end)
      {_fresh, fresh_pid} = login(c)
      assert World.get_block(c.target) == 1
      assert :sys.get_state(fresh_pid).inventory.slots[36].count == 6
      assert saved(c).transfer_sequence == 1 and saved(c).outbox == nil
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "stalled survival sampling fences selection and expires without source consumption", c do
    seed(c, :survival)
    {client, pid} = login(c)
    {:ok, {owner, _}} = World.existing_owner(c.key)
    Valimc.TestRegionGate.stall(owner)

    try do
      send_place(client, c.target)
      # The use first asks the stalled owner whether it clicked a table or container.
      wait(fn -> Valimc.TestConn.state(pid).table_job end)
      Client.send_packet(client, :play, "set_carried_item", <<1::signed-16>>)
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_body, client} = Client.await_stats(client)
      assert Valimc.TestConn.state(pid).inventory.selected == 0
      # The command's authority lapses while the owner is stalled, however fast the host.
      past = System.monotonic_time(:millisecond)

      :sys.replace_state(pid, &put_in(&1.table_job.placement.command.expires, past))

      Valimc.TestRegionGate.resume(owner)
      _client = ack(client)
      assert World.get_block(c.target) == 0
      assert Valimc.TestConn.state(pid).inventory.slots[36].count == 7

      assert :sys.get_state(Valimc.TestConn.state(pid).player_store).snapshot.transfer_sequence ==
               0
    after
      Valimc.TestRegionGate.resume(owner)
    end
  end

  test "an accepted command retains its original held item before a later selection", c do
    seed(c)
    {client, pid} = login(c)
    {:ok, {owner, _}} = World.existing_owner(c.key)
    Valimc.TestRegionGate.stall(owner)

    try do
      send_place(client, c.target)

      wait(fn ->
        state = Valimc.TestConn.state(pid)
        state.table_job != nil or Valimc.TestConn.job(state, :placement) != nil
      end)

      Client.send_packet(client, :play, "set_carried_item", <<1::signed-16>>)
      {<<1>>, client} = Client.await(client, :play, "set_held_slot")
      Valimc.TestRegionGate.resume(owner)
      client = ack(client)
      assert World.get_block(c.target) == 1
      :ok = World.set_block(c.target, 0)
      send_place(client, c.target, 1, 0.5, 0, 2)
      _client = ack(client, 2)
      assert World.get_block(c.target) == 15_180
    after
      Valimc.TestRegionGate.resume(owner)
    end
  end
end
