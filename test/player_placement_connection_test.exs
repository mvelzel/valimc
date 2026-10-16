defmodule Valimc.PlayerPlacementConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.{Connection, GameMode, Inventory, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-live-place-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {70_000 + rem(nonce, 10_000), 1800}
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

  defp wait(fun, tries \\ 200) do
    if result = fun.(),
      do: result,
      else:
        (
          assert tries > 0
          Process.sleep(5)
          wait(fun, tries - 1)
        )
  end

  test "actual packets replace clicked air and source water, orient halves and merge dry doubles",
       c do
    seed(c)
    {client, pid} = login(c)
    send_place(client, c.target)
    client = ack(client)
    assert World.get_block(c.target) == 1

    :ok = World.set_block(c.target, 89)
    send_place(client, c.target, 1, 0.5, 1, 2)
    client = ack(client, 2)
    assert World.get_block(c.target) == 15_179
    send_place(client, c.target, 1, 0.5, 1, 3)
    client = ack(client, 3)
    assert World.get_block(c.target) == 15_182

    :ok = World.set_block(c.target, 0)
    send_place(client, c.target, 2, 0.75, 1, 4)
    _client = ack(client, 4)
    assert World.get_block(c.target) == 15_178
    assert :sys.get_state(pid).inventory.slots[36].count == 7
    assert :sys.get_state(pid).inventory.slots[45].count == 11
    assert World.item_snapshot(c.key) == %{}
  end

  test "body obstruction and occupied adjacency correct predictions without overwriting", c do
    seed(c)
    {client, _pid} = login(c)
    feet = {floor(c.pose.x), 64, floor(c.pose.z)}
    send_place(client, feet)
    client = ack(client)
    assert World.get_block(feet) == 0

    {x, y, z} = c.target
    :ok = World.set_block(c.target, 1)
    :ok = World.set_block({x, y + 1, z}, 15)
    send_place(client, c.target, 1, 0.5, 0, 2)
    _client = ack(client, 2)
    assert World.get_block({x, y + 1, z}) == 15
  end

  test "survival consumes owned main/offhand stacks and persists wet/double placements across fresh login",
       c do
    seed(c, :survival)
    {client, pid} = login(c)
    send_place(client, c.target)
    client = ack(client)
    assert World.get_block(c.target) == 1
    assert :sys.get_state(pid).inventory.slots[36].count == 6
    :ok = World.set_block(c.target, 89)
    send_place(client, c.target, 1, 0.5, 1, 2)
    client = ack(client, 2)
    assert World.get_block(c.target) == 15_179
    assert :sys.get_state(pid).inventory.slots[45].count == 10
    send_place(client, c.target, 1, 0.5, 1, 3)
    client = ack(client, 3)
    assert World.get_block(c.target) == 15_182
    assert :sys.get_state(pid).inventory.slots[45].count == 9
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

  test "last-item placement depletes exactly its hand and subsequent empty use is inert", c do
    seed(c, :survival, %{36 => ItemStack.new("stone"), 45 => ItemStack.new("oak_slab")})
    {client, pid} = login(c)
    send_place(client, c.target)
    client = ack(client)
    assert :sys.get_state(pid).inventory.slots[36] == nil
    assert saved(c).inventory.slots[36] == nil
    assert :ok = World.set_block(c.target, 0)
    send_place(client, c.target, 1, 0.5, 1, 2)
    client = ack(client, 2)
    assert World.get_block(c.target) == 15_180
    assert :sys.get_state(pid).inventory.slots[45] == nil
    assert saved(c).transfer_sequence == 2 and saved(c).outbox == nil
    assert :ok = World.set_block(c.target, 0)
    send_place(client, c.target, 1, 0.5, 1, 3)
    _client = ack(client, 3)
    assert World.get_block(c.target) == 0 and saved(c).transfer_sequence == 2
  end

  test "survival body, occupied, reach and unloaded refusals preserve source stacks and counters",
       c do
    seed(c, :survival)
    {client, pid} = login(c, false)
    before = :sys.get_state(pid).inventory.slots
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
    assert :sys.get_state(pid).inventory.slots == before
    assert :sys.get_state(:sys.get_state(pid).player_store).snapshot.transfer_sequence == 0
  end

  test "pending source save blocks selection, not chat or world reads, and precedes destination mutation",
       c do
    seed(c, :survival)
    {client, pid} = login(c)
    writer = :sys.get_state(pid).player_store
    :sys.suspend(writer)

    try do
      send_place(client, c.target)
      wait(fn -> match?(%{stage: :prepare}, :sys.get_state(pid).recovery) end)
      Client.send_packet(client, :play, "set_carried_item", <<1::signed-16>>)
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_body, client} = Client.await(client, :play, "system_chat")
      assert :sys.get_state(pid).inventory.selected == 0
      assert :sys.get_state(pid).inventory.slots[36].count == 7
      assert World.get_block(c.target) == 0
      :sys.resume(writer)
      _client = ack(client)
      assert World.get_block(c.target) == 1
      assert :sys.get_state(pid).inventory.slots[36].count == 6
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "disconnect during destination storage recovers the already-consumed stack exactly once",
       c do
    seed(c, :survival)
    {client, pid} = login(c)
    {:ok, {region, _}} = World.existing_owner(c.key)
    writer = :sys.get_state(region).resource.store
    :sys.suspend(writer)

    try do
      send_place(client, c.target)

      wait(fn ->
        match?(%{kind: :placement, phase: :writing}, :sys.get_state(region).resource.item_pending)
      end)

      assert saved(c).outbox.kind == :placement
      assert saved(c).inventory.slots[36].count == 6
      assert World.get_block(c.target) == 0
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

  test "unloaded preview stays inert even with creative inventory permission", c do
    seed(c)
    {client, _pid} = login(c, false)
    send_place(client, c.target)
    _client = ack(client)
    assert World.get_block(c.target) == 0
  end

  test "adventure and spectator placement cannot mutate blocks or source stacks", c do
    for mode <- [:adventure, :spectator] do
      seed(c, mode)
      {client, pid} = login(c)
      before = :sys.get_state(pid).inventory.slots
      send_place(client, c.target)
      client = ack(client)
      assert World.get_block(c.target) == 0
      assert :sys.get_state(pid).inventory.slots == before
      Client.close(client)

      wait(fn ->
        not Process.alive?(pid) and Registry.lookup(Valimc.PlayerStoreRegistry, c.uuid) == []
      end)
    end
  end

  test "region stalls leave the socket responsive and cannot spend expired authority", c do
    seed(c)
    {client, pid} = login(c)
    {:ok, {owner, _}} = World.existing_owner(c.key)
    :sys.suspend(owner)

    try do
      send_place(client, c.target)

      wait(fn ->
        state = :sys.get_state(pid)
        state.table_job != nil or state.placement_job != nil
      end)

      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_body, client} = Client.await(client, :play, "system_chat")
      Process.sleep(275)
      :sys.resume(owner)
      _client = ack(client)
      assert World.get_block(c.target) == 0
      assert Process.alive?(pid)
    after
      :sys.resume(owner)
    end
  end

  test "stalled survival sampling fences selection and expires without source consumption", c do
    seed(c, :survival)
    {client, pid} = login(c)
    {:ok, {owner, _}} = World.existing_owner(c.key)
    :sys.suspend(owner)

    try do
      send_place(client, c.target)

      wait(fn ->
        state = :sys.get_state(pid)
        state.table_job != nil or state.placement_job != nil
      end)

      Client.send_packet(client, :play, "set_carried_item", <<1::signed-16>>)
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_body, client} = Client.await(client, :play, "system_chat")
      assert :sys.get_state(pid).inventory.selected == 0
      Process.sleep(275)
      :sys.resume(owner)
      _client = ack(client)
      assert World.get_block(c.target) == 0
      assert :sys.get_state(pid).inventory.slots[36].count == 7
      assert :sys.get_state(:sys.get_state(pid).player_store).snapshot.transfer_sequence == 0
    after
      :sys.resume(owner)
    end
  end

  test "ordinary cube families use creative collision admission without consumption", c do
    ordinary_cubes(c, :creative)
  end

  test "ordinary cube families use the survival journal and preserve counts on body refusal", c do
    ordinary_cubes(c, :survival)
  end

  defp ordinary_cubes(c, mode) do
    names = ~w(polished_granite spruce_planks iron_block red_concrete crafting_table)

    slots =
      names
      |> Enum.with_index(36)
      |> Map.new(fn {name, slot} -> {slot, ItemStack.new(name, 2)} end)

    seed(c, mode, slots)
    {client, pid} = login(c)
    feet = {floor(c.pose.x), 64, floor(c.pose.z)}

    Enum.reduce(Enum.with_index(names), client, fn {name, slot}, client ->
      Client.send_packet(client, :play, "set_carried_item", <<slot::signed-16>>)
      {_packet, client} = Client.await(client, :play, "set_held_slot")
      assert :ok = World.set_block(c.target, 0)
      send_place(client, c.target, 1, 0.5, 0, 2 * slot + 1)
      client = ack(client, 2 * slot + 1)

      assert World.get_block(c.target) ==
               Valimc.Protocol.Data.item_block(ItemStack.new(name).item_id)

      count = if mode == :survival, do: 1, else: 2
      assert :sys.get_state(pid).inventory.slots[36 + slot].count == count
      send_place(client, feet, 1, 0.5, 0, 2 * slot + 2)
      client = ack(client, 2 * slot + 2)
      assert World.get_block(feet) == 0
      assert :sys.get_state(pid).inventory.slots[36 + slot].count == count

      if mode == :survival do
        assert saved(c).transfer_sequence == slot + 1 and saved(c).outbox == nil
        assert saved(c).inventory.slots[36 + slot].count == 1
      end

      client
    end)
  end

  test "pillar packets preserve all axes and both creative hand counts", c do
    pillars(c, :creative)
  end

  test "survival table placement consumes either hand once and survives a fresh connection", c do
    seed(c, :survival, %{
      36 => ItemStack.new("crafting_table"),
      45 => ItemStack.new("crafting_table")
    })

    {client, pid} = login(c)
    table = Valimc.Protocol.Data.item_block(ItemStack.new("crafting_table").item_id)
    other = {elem(c.target, 0) + 1, 64, elem(c.target, 2)}
    :ok = World.set_block(other, 0)

    send_place(client, c.target)
    client = ack(client)
    assert World.get_block(c.target) == table
    assert :sys.get_state(pid).inventory.slots[36] == nil
    assert saved(c).transfer_sequence == 1 and saved(c).outbox == nil

    send_place(client, other, 1, 0.5, 1, 2)
    _client = ack(client, 2)
    assert World.get_block(other) == table
    assert :sys.get_state(pid).inventory.slots[45] == nil
    assert saved(c).transfer_sequence == 2 and saved(c).outbox == nil

    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, c.uuid) == [] end)
    {_fresh, fresh_pid} = login(c)
    assert :sys.get_state(fresh_pid).inventory.slots[36] == nil
    assert :sys.get_state(fresh_pid).inventory.slots[45] == nil
    assert World.get_block(c.target) == table and World.get_block(other) == table
    assert saved(c).transfer_sequence == 2 and saved(c).outbox == nil
  end

  test "pillar packets consume and persist both survival hands without changing axes", c do
    pillars(c, :survival)
  end

  defp pillars(c, mode) do
    seed(c, mode, %{
      36 => ItemStack.new("oak_log", 3),
      45 => ItemStack.new("stripped_spruce_log", 3)
    })

    {client, pid} = login(c)
    cases = [{0, 0, 140}, {1, 1, 178}, {2, 0, 141}, {3, 1, 179}, {4, 0, 139}, {5, 1, 177}]

    Enum.reduce(Enum.with_index(cases, 1), client, fn {{face, hand, expected}, seq}, client ->
      :ok = World.set_block(c.target, 0)
      send_place(client, c.target, face, 0.5, hand, seq)
      client = ack(client, seq)
      assert World.get_block(c.target) == expected
      remaining = if mode == :survival, do: 3 - div(seq + 1, 2), else: 3
      slot = if hand == 0, do: 36, else: 45
      stack = :sys.get_state(pid).inventory.slots[slot]
      if remaining == 0, do: assert(stack == nil), else: assert(stack.count == remaining)
      assert saved(c).transfer_sequence == if(mode == :survival, do: seq, else: 0)
      assert saved(c).outbox == nil
      client
    end)

    slots = :sys.get_state(pid).inventory.slots
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, c.uuid) == [] end)
    {_fresh, pid} = login(c)
    assert :sys.get_state(pid).inventory.slots == slots
    assert World.get_block(c.target) == 177
    assert saved(c).transfer_sequence == if(mode == :survival, do: 6, else: 0)
  end

  test "an accepted command retains its original held item before a later selection", c do
    seed(c)
    {client, pid} = login(c)
    {:ok, {owner, _}} = World.existing_owner(c.key)
    :sys.suspend(owner)

    try do
      send_place(client, c.target)

      wait(fn ->
        state = :sys.get_state(pid)
        state.table_job != nil or state.placement_job != nil
      end)

      Client.send_packet(client, :play, "set_carried_item", <<1::signed-16>>)
      {<<1>>, client} = Client.await(client, :play, "set_held_slot")
      :sys.resume(owner)
      client = ack(client)
      assert World.get_block(c.target) == 1
      :ok = World.set_block(c.target, 0)
      send_place(client, c.target, 1, 0.5, 0, 2)
      _client = ack(client, 2)
      assert World.get_block(c.target) == 15_180
    after
      :sys.resume(owner)
    end
  end
end
