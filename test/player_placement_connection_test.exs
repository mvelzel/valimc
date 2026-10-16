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

  defp seed(c, mode \\ :creative) do
    player =
      Map.merge(c.pose, %{
        game_mode: GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode)
      })

    inventory = %Inventory{
      slots: %{
        36 => ItemStack.new("stone", 7),
        37 => ItemStack.new("oak_slab", 9),
        45 => ItemStack.new("oak_slab", 11)
      }
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

  test "unloaded and survival owners cannot authorize creative placement or consume stacks", c do
    seed(c, :survival)
    {client, pid} = login(c)
    before = :sys.get_state(pid).inventory
    send_place(client, c.target)
    _client = ack(client)
    assert World.get_block(c.target) == 0

    assert Map.take(:sys.get_state(pid).inventory, [
             :slots,
             :selected,
             :carried,
             :drag,
             :infinite_materials
           ]) ==
             Map.take(before, [:slots, :selected, :carried, :drag, :infinite_materials])
  end

  test "unloaded preview stays inert even with creative inventory permission", c do
    seed(c)
    {client, _pid} = login(c, false)
    send_place(client, c.target)
    _client = ack(client)
    assert World.get_block(c.target) == 0
  end

  test "region stalls leave the socket responsive and cannot spend expired authority", c do
    seed(c)
    {client, pid} = login(c)
    {:ok, {owner, _}} = World.existing_owner(c.key)
    :sys.suspend(owner)

    try do
      send_place(client, c.target)
      wait(fn -> :sys.get_state(pid).placement_job != nil end)
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

  test "an accepted command retains its original held item before a later selection", c do
    seed(c)
    {client, pid} = login(c)
    {:ok, {owner, _}} = World.existing_owner(c.key)
    :sys.suspend(owner)

    try do
      send_place(client, c.target)
      wait(fn -> :sys.get_state(pid).placement_job != nil end)
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
