defmodule Valimc.InteractionRangeConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{GameMode, Inventory, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-range-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    name = "Range" <> Integer.to_string(nonce)
    uuid = Valimc.Connection.offline_uuid(name)
    key = {100_000 + rem(nonce, 10_000), 800}
    {rx, rz} = key
    pose = %{x: rx * 128 + 64.5, y: 64.0, z: rz * 128 + 64.5, yaw: 0.0, pitch: 0.0}

    player =
      Map.merge(pose, %{game_mode: GameMode.new(:creative), abilities: %Valimc.PlayerAbilities{}})

    inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
    {:ok, bytes} = PlayerSnapshot.encode(uuid, PlayerSnapshot.capture(player, inventory))
    path = PlayerStore.path(base, uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    {_, client} = Client.login(name)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    pid = Enum.find(Players.all(), &(&1.name == name)).pid

    on_exit(fn ->
      Client.close(client)

      if Process.alive?(pid),
        do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, pid)

      for {writer, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, writer)

      for {owner, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, owner)

      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    %{client: client, pid: pid, x: floor(pose.x), z: floor(pose.z)}
  end

  defp place(client, pos, face, {cx, cy, cz}) do
    Client.send_packet(client, :play, "use_item_on", [
      <<0>>,
      Wire.position(pos),
      Wire.varint(face),
      <<cx::float-32, cy::float-32, cz::float-32, 0, 0, 1>>
    ])

    {<<1>>, client} = Client.await(client, :play, "block_changed_ack")
    client
  end

  defp break(client, pos) do
    Client.send_packet(client, :play, "player_action", [
      Wire.varint(ItemTypes.action_id("start_destroy_block")),
      Wire.position(pos),
      <<1, 2>>
    ])

    {<<2>>, client} = Client.await(client, :play, "block_changed_ack")
    client
  end

  test "creative removal retains contained water and dry removal still becomes air", ctx do
    target = {ctx.x + 1, 65, ctx.z}
    assert :ok = World.set_block(target, 15179)
    client = break(ctx.client, target)
    assert World.get_block(target) == 89
    assert :ok = World.set_block(target, 15180)
    _client = break(client, target)
    assert World.get_block(target) == 0
  end

  test "placement validates the clicked box, even when the adjacent destination is outside reach",
       ctx do
    clicked = {ctx.x + 6, 65, ctx.z}
    target = {ctx.x + 7, 65, ctx.z}
    :ok = World.set_block(clicked, 1)
    assert World.get_block(target) == 0
    client = place(ctx.client, clicked, 5, {1.0, 0.5, 0.5})
    assert World.get_block(target) == 1
    client = break(client, target)
    assert World.get_block(target) == 1
    _client = break(client, clicked)
    assert World.get_block(clicked) == 0
    assert :sys.get_state(ctx.pid).inventory.slots[36].count == 7
  end

  test "invalid hit coordinates retain blocks and inventory, while tolerated native bounds work",
       ctx do
    clicked = {ctx.x + 1, 65, ctx.z}
    target = {ctx.x + 2, 65, ctx.z}
    :ok = World.set_block(clicked, 1)

    client =
      Enum.reduce(
        [{-0.500001, 0.5, 0.5}, {0.5, 1.500001, 0.5}, {0.5, 0.5, 1.500001}],
        ctx.client,
        fn hit, client ->
          client = place(client, clicked, 5, hit)
          assert World.get_block(target) == 0
          client
        end
      )

    _client = place(client, clicked, 5, {1.5, 0.5, 0.5})
    assert World.get_block(target) == 1
    assert :sys.get_state(ctx.pid).inventory.slots[36].count == 7
  end

  test "remote placement and break are acknowledged without allocating a region", ctx do
    pos = {-30_000_000, 65, -30_000_000}
    key = World.region_key(World.chunk_key(elem(pos, 0), elem(pos, 2)))
    assert Registry.lookup(Valimc.RegionRegistry, key) == []
    client = place(ctx.client, pos, 1, {0.5, 1.0, 0.5})
    _client = break(client, pos)
    assert Registry.lookup(Valimc.RegionRegistry, key) == []
    assert :sys.get_state(ctx.pid).inventory.slots[36].count == 7
  end

  test "native NaN/infinite hit rejection retains accepted state and keeps the session usable",
       ctx do
    clicked = {ctx.x + 1, 65, ctx.z}
    target = {ctx.x + 2, 65, ctx.z}
    :ok = World.set_block(clicked, 1)

    client =
      Enum.reduce([0x7FC00000, 0x7F800000, 0xFF800000], ctx.client, fn bits, client ->
        Client.send_packet(client, :play, "use_item_on", [
          <<0>>,
          Wire.position(clicked),
          <<5>>,
          <<bits::32, 0.5::float-32, 0.5::float-32, 0, 0, 1>>
        ])

        {<<1>>, client} = Client.await(client, :play, "block_changed_ack")
        assert World.get_block(target) == 0
        client
      end)

    _client = place(client, clicked, 5, {1.0, 0.5, 0.5})
    assert World.get_block(target) == 1
    assert :sys.get_state(ctx.pid).inventory.slots[36].count == 7
  end
end
