defmodule Valimc.UnsupportedBlockEntityTest do
  use ExUnit.Case, async: false
  alias Valimc.{Connection, GameMode, Inventory, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Physics.{BlockEntities, ChestPlacement, CookingBlocks}
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.World.Region

  # Default states the 26.3 client sent for a copper chest and a barrel.
  @copper_chest 32_926
  @barrel 24_100

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-unsupported-entity-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {74_000 + rem(nonce, 10_000), 1900}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 90.0, pitch: 0.0}
    name = "Shell#{rem(nonce, 1_000_000_000)}"
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

  test "generated facts mark container variants unsupported and owned kinds supported" do
    assert Data.item_block(Data.item("copper_chest")) == @copper_chest
    assert Data.item_block(Data.item("barrel")) == @barrel

    for state <- [@copper_chest, @barrel] do
      assert BlockEntities.native?(state) and BlockEntities.unsupported?(state)
    end

    {:ok, chest} = ChestPlacement.single_state(90.0, 0)
    {:ok, furnace} = CookingBlocks.placement(:furnace, 90.0)

    for state <- [chest, furnace, furnace - 1] do
      assert BlockEntities.native?(state) and not BlockEntities.unsupported?(state)
    end

    refute BlockEntities.native?(1) or BlockEntities.unsupported?(0)
  end

  test "owner block commits refuse unsupported block entities and keep supported ones", c do
    {:ok, {pid, _} = owner} = World.owner(c.key)

    for state <- [@copper_chest, @barrel] do
      revision = Valimc.TestConn.state(pid).resource.revision

      assert {:error, :unsupported_block_entity} =
               Region.set_blocks(owner, revision, %{c.target => state})

      assert World.get_block(c.target) == 0
    end

    {:ok, furnace} = CookingBlocks.placement(:furnace, 90.0)
    revision = Valimc.TestConn.state(pid).resource.revision
    assert {:ok, _} = Region.set_blocks(owner, revision, %{c.target => furnace})
    assert World.get_block(c.target) == furnace
  end

  for mode <- [:creative, :survival] do
    test "#{mode} copper chest and barrel placement is corrected without a shell or item loss",
         c do
      held = %{36 => ItemStack.new("copper_chest", 2), 45 => ItemStack.new("barrel", 3)}
      seed(c, unquote(mode), held)
      {client, pid} = login(c)

      # Click the solid floor's top face, as the client did, so the item targets the air above it.
      Enum.reduce([{0, 1}, {1, 2}], client, fn {hand, seq}, client ->
        send_place(client, below(c.target), hand, seq)
        client |> ack(seq) |> corrected(c.target)
      end)

      assert World.get_block(c.target) == 0
      assert Valimc.TestConn.state(pid).inventory.slots == held
      {:ok, {region, _}} = World.existing_owner(c.key)
      assert :sys.get_state(region).resource.containers.entries == %{}
    end

    test "#{mode} chest and furnace placement still own their records", c do
      seed(c, unquote(mode), %{36 => ItemStack.new("chest", 2), 45 => ItemStack.new("furnace", 3)})

      {client, _pid} = login(c)
      {x, y, z} = c.target
      furnace_at = {x - 2, y, z}
      :ok = World.set_block(furnace_at, 0)
      :ok = World.set_block(below(furnace_at), 1)
      send_place(client, below(c.target), 0, 1)
      client = ack(client, 1)
      send_place(client, below(furnace_at), 1, 2)
      _client = ack(client, 2)
      {:ok, chest} = ChestPlacement.single_state(90.0, 0)
      {:ok, furnace} = CookingBlocks.placement(:furnace, 90.0)
      assert World.get_block(c.target) == chest and World.get_block(furnace_at) == furnace
      {:ok, {region, _}} = World.existing_owner(c.key)
      entries = :sys.get_state(region).resource.containers.entries
      assert entries[c.target].slots == Tuple.duplicate(nil, 27)
      assert entries[furnace_at].kind == :furnace
    end
  end

  defp seed(c, mode, slots) do
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
    :ok = World.set_block(c.target, 0)
    :ok = World.set_block(below(c.target), 1)
  end

  defp below({x, y, z}), do: {x, y - 1, z}

  defp login(c) do
    {_, client} = Client.login(c.name)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    pid = Enum.find(Players.all(), &(&1.name == c.name)).pid
    wait(fn -> Valimc.PlayerInput.loaded?(Valimc.TestConn.state(pid).player.input) end)
    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp send_place(client, position, hand, seq) do
    Client.send_packet(client, :play, "use_item_on", [
      Wire.varint(hand),
      Wire.position(position),
      Wire.varint(1),
      <<0.5::float-32, 0.5::float-32, 0.5::float-32, 0, 0>>,
      Wire.varint(seq)
    ])
  end

  defp ack(client, seq) do
    {bytes, client} = Client.await(client, :play, "block_changed_ack")
    assert {seq, <<>>} == Wire.take_varint(bytes)
    client
  end

  # The client's predicted block in the target air cell is reset.
  defp corrected(client, position) do
    {bytes, client} = Client.await(client, :play, "block_update")

    if bytes == IO.iodata_to_binary([Wire.position(position), Wire.varint(0)]),
      do: client,
      else: corrected(client, position)
  end

  defp wait(fun, tries \\ 200) do
    if result = fun.() do
      result
    else
      assert tries > 0
      Process.sleep(5)
      wait(fun, tries - 1)
    end
  end
end
