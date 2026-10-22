defmodule Valimc.PlayerPlacementConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Connection, GameMode, Inventory, Players}
  alias Valimc.Player.State, as: PlayerState
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

      for x <- (rx - 1)..(rx + 1),
          z <- (rz - 1)..(rz + 1),
          {pid, _} <- Valimc.TestWorld.registered({x, z}),
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

  defp seed(c, mode, slots \\ %{}) do
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

    {:ok, bytes} = PlayerState.encode(c.uuid, PlayerState.capture(player, inventory))
    path = Valimc.Player.Storage.path(c.base, c.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    :ok = Valimc.TestBlocks.set(c.target, 0)
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
    {:ok, dry} = Valimc.ChestPlacement.single_state(90.0, 0)
    assert Valimc.TestBlocks.get(c.target) == dry
    assert Valimc.TestConn.state(pid).inventory.slots[36] == ItemStack.new("chest")
    {x, y, z} = c.target
    wet = {x - 2, y, z}
    :ok = Valimc.TestBlocks.set(wet, 89)
    send_place(client, wet, 1, 0.5, 1, 2)
    client = ack(client, 2)
    {:ok, wet_state} = Valimc.ChestPlacement.single_state(90.0, 89)
    assert Valimc.TestBlocks.get(wet) == wet_state
    assert Valimc.TestConn.state(pid).inventory.slots[45] == ItemStack.new("chest", 2)

    # Horizontal neighbors would need double-chest behavior, so refuse before spending a source sequence.
    send_place(client, {x + 1, y, z}, 1, 0.5, 0, 3)
    client = ack(client, 3)
    assert Valimc.TestBlocks.get({x + 1, y, z}) == 0
    assert Valimc.TestConn.state(pid).inventory.slots[36] == ItemStack.new("chest")

    send_place(client, c.target, 1, 0.5, 0, 4)
    client = ack(client, 4)
    {_body, client} = Client.await(client, :play, "open_screen")
    assert Valimc.TestConn.state(pid).table_menu.position == c.target
    Client.close(client)

    wait(fn ->
      not Process.alive?(pid) and Registry.lookup(Valimc.PlayerRegistry, c.uuid) == []
    end)

    {_fresh, fresh_pid} = login(c)
    assert Valimc.TestConn.state(fresh_pid).inventory.slots[36] == ItemStack.new("chest")
    assert Valimc.TestConn.state(fresh_pid).inventory.slots[45] == ItemStack.new("chest", 2)
    {:ok, owner} = Valimc.TestWorld.existing_owner(c.key)
    containers = Valimc.TestRegion.section(owner).containers
    assert containers.sequence == 2
    assert containers.entries[c.target].slots == Tuple.duplicate(nil, 27)
    assert containers.entries[wet].slots == Tuple.duplicate(nil, 27)
    assert Valimc.TestWorld.item_snapshot(c.key) == %{}
  end

  test "unsupported block entities are corrected without a shell or item loss", c do
    # Default states the 26.3 client sent for a copper chest and a barrel; the owner
    # refuses them too (placement_owner_test).
    held = %{36 => ItemStack.new("copper_chest", 2), 45 => ItemStack.new("barrel", 3)}
    seed(c, :survival, held)
    {x, y, z} = c.target
    floor = {x, y - 1, z}
    :ok = Valimc.TestBlocks.set(floor, 1)
    {client, pid} = login(c)

    # Click the solid floor's top face, as the client did, so the item targets the air above it.
    Enum.reduce([{0, 1}, {1, 2}], client, fn {hand, seq}, client ->
      send_place(client, floor, 1, 0.5, hand, seq)
      # The corrections precede the acknowledgement, as vanilla sends them.
      client |> corrected(c.target) |> ack(seq)
    end)

    assert Valimc.TestBlocks.get(c.target) == 0
    assert Map.take(Valimc.TestConn.state(pid).inventory.slots, [36, 45]) == held
    {:ok, owner} = Valimc.TestWorld.existing_owner(c.key)
    assert Valimc.TestRegion.section(owner).containers.entries == %{}
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
    assert Valimc.TestBlocks.get(c.target) == 1
    assert Valimc.TestConn.state(pid).inventory.slots[36].count == 6
    :ok = Valimc.TestBlocks.set(c.target, 89)
    send_place(client, c.target, 1, 0.5, 1, 2)
    client = ack(client, 2)
    assert Valimc.TestBlocks.get(c.target) == 15_179
    assert Valimc.TestConn.state(pid).inventory.slots[45].count == 10
    send_place(client, c.target, 1, 0.5, 1, 3)
    client = ack(client, 3)
    assert Valimc.TestBlocks.get(c.target) == 15_182
    assert Valimc.TestConn.state(pid).inventory.slots[45].count == 9
    assert Valimc.TestWorld.item_snapshot(c.key) == %{}
    Client.close(client)

    wait(fn ->
      not Process.alive?(pid) and Registry.lookup(Valimc.PlayerRegistry, c.uuid) == []
    end)

    {_fresh, fresh_pid} = login(c)
    assert Valimc.TestConn.state(fresh_pid).inventory.slots[36].count == 6
    assert Valimc.TestConn.state(fresh_pid).inventory.slots[45].count == 9
    assert Valimc.TestBlocks.get(c.target) == 15_182
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
    assert Valimc.TestBlocks.get(feet) == 0
    {x, y, z} = c.target
    assert :ok = Valimc.TestBlocks.set(c.target, 1)
    assert :ok = Valimc.TestBlocks.set({x, y + 1, z}, 15)
    send_place(client, c.target, 1, 0.5, 0, 3)
    client = ack(client, 3)
    send_place(client, {x, y, z + 40}, 1, 0.5, 0, 4)
    _client = ack(client, 4)
    assert Valimc.TestBlocks.get({x, y + 1, z}) == 15
    assert Valimc.TestConn.state(pid).inventory.slots == before
  end

  test "a block cannot be placed into another player standing there", c do
    seed(c, :survival)
    other = "Peer#{System.unique_integer([:positive])}"
    other_uuid = Connection.offline_uuid(other)
    {tx, _, tz} = c.target

    peer =
      Map.merge(c.pose, %{
        x: tx + 0.5,
        z: tz + 0.5,
        game_mode: GameMode.new(:survival),
        abilities: Valimc.PlayerAbilities.for_mode(:survival)
      })

    {:ok, bytes} = PlayerState.encode(other_uuid, PlayerState.capture(peer, %Inventory{}))
    path = Valimc.Player.Storage.path(c.base, other_uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    {_, peer_client} = Client.login(other)
    on_exit(fn -> Client.close(peer_client) end)
    Client.load_world(peer_client)
    wait(fn -> Enum.any?(Players.all(), &(&1.name == other)) end)
    {client, pid} = login(c)
    before = Valimc.TestConn.state(pid).inventory.slots
    send_place(client, c.target)
    _client = ack(client)
    assert Valimc.TestBlocks.get(c.target) == 0
    assert Valimc.TestConn.state(pid).inventory.slots == before
  end
end
