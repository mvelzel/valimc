defmodule Valimc.EnderChestTest do
  @moduledoc """
  Ender chests (VMC-032c3) in region owners and player storage: placement,
  the plain block entity, the lid and sounds as viewers come and go, the
  conductor that keeps it shut, removal closing views, and the player's
  ender slots as records whose click reaches one frame with the inventory.
  """
  use ExUnit.Case, async: true
  alias Valimc.Blocks.BlockEntityTypes, as: Types
  alias Valimc.Blocks.EnderChest
  alias Valimc.Data.Blocks, as: Registry
  alias Valimc.Menus.Inventory
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Player.Storage
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.Storage.Log
  alias Valimc.TestScope
  alias Valimc.World.{BlockBatch, ContainerViewers, Region}

  setup do
    nonce = System.unique_integer([:positive])
    key = {99_000 + rem(nonce, 3_333) * 3, 2530}
    base = Path.join(System.tmp_dir!(), "valimc-ender-#{nonce}")

    TestScope.isolate([key],
      world_path: base,
      region_ticks: :manual,
      region_commit_ms: 600_000,
      regionizer: false
    )

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key), do: TestScope.kill(pid)
      File.rm_rf(base)
    end)

    {:ok, owner} = Valimc.TestWorld.item_owner(key)
    {rx, rz} = key
    %{key: key, owner: owner, base: base, x: rx * 128, z: rz * 128}
  end

  defp ender(facing, waterlogged \\ false),
    do:
      Registry.state("ender_chest", %{
        "facing" => facing,
        "waterlogged" => Atom.to_string(waterlogged)
      })

  defp set(owner, edits) do
    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
  end

  defp grant(kind, {x, y, z}, extra \\ %{}) do
    Map.merge(
      %{
        kind: kind,
        mode: :survival,
        eye: {x + 0.5, y + 1.6, z + 2.5},
        expires: Valimc.TestRegion.grant_expires(),
        hand: :main,
        secondary: false,
        main: false,
        off: false
      },
      extra
    )
  end

  defp subscribe(owner, viewer, at, ref, extra \\ %{}),
    do:
      Region.menu(
        owner,
        viewer,
        at,
        grant(:subscribe, at, Map.merge(%{menu: :ender_chest, view_ref: ref}, extra))
      )

  defp viewer do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp body(frame) do
    {:ok, id, body, <<>>} =
      Wire.next_frame(frame, 2_097_152, Valimc.config(:compression_threshold))

    {id, body}
  end

  test "placement faces the player and waterlogs; the block entity holds nothing", ctx do
    item = Valimc.Protocol.Data.item("ender_chest")
    target = {ctx.x + 20, 64, ctx.z + 20}

    # `getHorizontalDirection().getOpposite()`: looking south it faces north.
    for {yaw, facing} <- [{0.0, "north"}, {180.0, "south"}, {90.0, "east"}, {-90.0, "west"}] do
      request = %{position: target, face: 1, cursor: {0.5, 1.0, 0.5}, yaw: yaw, pitch: 0.0}
      {:ok, %{values: values}} = Valimc.Blocks.Placement.target(item, 0, request)
      {:ok, writes} = Region.placement(ctx.owner, item, values, target)
      assert Map.new(writes)[target] == ender(facing), inspect({yaw, facing})
    end

    wet = {ctx.x + 22, 64, ctx.z + 20}
    set(ctx.owner, %{wet => Registry.default_state("water")})
    request = %{position: wet, face: 1, cursor: {0.5, 1.0, 0.5}, yaw: 0.0, pitch: 0.0}
    {:ok, %{values: values}} = Valimc.Blocks.Placement.target(item, 0, request)
    {:ok, writes} = Region.placement(ctx.owner, item, values, wet)
    assert Map.new(writes)[wet] == ender("north", true)

    request = %{position: target, face: 1, cursor: {0.5, 1.0, 0.5}, yaw: 0.0, pitch: 0.0}
    {:ok, %{values: values}} = Valimc.Blocks.Placement.target(item, 0, request)
    {:ok, writes} = Region.placement(ctx.owner, item, values, target)
    {:ok, observed} = Region.observe_blocks(ctx.owner, [target])
    {:ok, batch} = BlockBatch.prepare(Map.new(writes))

    {:ok, _} =
      Region.place_block(ctx.owner, observed.fence, batch, Valimc.TestRegion.grant_expires())

    assert Valimc.TestBlocks.get(target) == ender("north")
    assert Valimc.TestRegion.section(ctx.owner).containers.entries == %{}
    assert Types.plain?(ender("east", true)) and not Types.unsupported?(ender("east", true))
  end

  test "the first viewer opens the lid with a sound at the centre, the last closes it; a spectator is silent",
       ctx do
    at = {ctx.x + 30, 64, ctx.z + 20}
    {x, y, z} = at
    set(ctx.owner, %{at => ender("west")})
    Valimc.TestWorld.subscribe(MapSet.new([ctx.key]), MapSet.new())

    assert {:ender_chest, block, view} = Region.menu(ctx.owner, self(), at, grant(:open, at))
    assert block == ender("west") and view == EnderChest.view()

    [first, second, spectator] = for _ <- 1..3, do: viewer()
    assert {:ender_chest, _, _} = subscribe(ctx.owner, first, at, make_ref())

    assert_receive {:event, {:chest_lid, _, ^at, true, lid, sound}}
    {_, native} = EnderChest.lid_event(at, true)
    assert body(lid) |> elem(1) == IO.iodata_to_binary(native)
    # `block.ender_chest.open` (588), blocks, at the centre, volume 0.5.
    {_, sound} = body(sound)

    assert <<205, 4, 4, sx::signed-32, sy::signed-32, sz::signed-32, 0.5::float-32, _::binary>> =
             sound

    assert {sx, sy, sz} == {8 * x + 4, 8 * y + 4, 8 * z + 4}

    second_ref = make_ref()
    assert {:ender_chest, _, _} = subscribe(ctx.owner, second, at, second_ref)

    assert {:ender_chest, _, _} =
             subscribe(ctx.owner, spectator, at, make_ref(), %{mode: :spectator})

    refute_receive {:event, {:chest_lid, _, _, _, _, _}}, 20

    viewers = Valimc.TestRegion.section(ctx.owner).container_viewers
    assert ContainerViewers.open_count(viewers, at) == 2

    Process.exit(first, :kill)
    refute_receive {:event, {:chest_lid, _, _, _, _, _}}, 20
    Region.unsubscribe_container(ctx.owner, second, second_ref)
    assert_receive {:event, {:chest_lid, _, ^at, false, _, sound}}
    assert <<204, 4, 4, _::binary>> = sound |> body() |> elem(1)

    # A removed chest closes its views silently.
    ref = make_ref()
    assert {:ender_chest, _, _} = subscribe(ctx.owner, self(), at, ref)
    assert_receive {:event, {:chest_lid, _, ^at, true, _, _}}
    set(ctx.owner, %{at => 0})
    assert_receive {:event, {:container_closed, _, ^ref}}
    assert_receive {:event, {:chest_lid, _, ^at, false, _, nil}}
  end

  test "a redstone conductor on it keeps it shut, glass does not; a spectator cannot open it",
       ctx do
    at = {ctx.x + 40, 64, ctx.z + 20}
    {x, y, z} = at
    set(ctx.owner, %{at => ender("north"), {x, y + 1, z} => Registry.default_state("stone")})
    assert {:error, :blocked_chest} = Region.menu(ctx.owner, self(), at, grant(:open, at))

    set(ctx.owner, %{{x, y + 1, z} => Registry.default_state("glass")})
    assert {:ender_chest, _, _} = Region.menu(ctx.owner, self(), at, grant(:open, at))

    assert :pass =
             Region.menu(ctx.owner, self(), at, grant(:open, at, %{secondary: true, main: true}))

    # A spectator cannot open one: its block entity is no menu provider.
    assert {:error, :no_menu_provider} =
             Region.menu(ctx.owner, self(), at, grant(:open, at, %{mode: :spectator}))

    # Out of reach, it refuses; a check of a view that was never registered is stale.
    far = %{grant(:open, at) | eye: {x + 0.5, y + 1.6, z + 9.5}}
    assert {:error, _} = Region.menu(ctx.owner, self(), at, far)

    check = grant(:check, at, %{menu: :ender_chest, view_ref: make_ref(), revision: 1})
    assert {:error, :stale_container_view} = Region.menu(ctx.owner, self(), at, check)
  end

  describe "the player's ender slots" do
    setup ctx do
      uuid = :crypto.strong_rand_bytes(16)
      TestScope.isolate(uuid, world_path: ctx.base)
      %{uuid: uuid}
    end

    defp captured(player, inventory),
      do:
        PlayerState.capture(
          Map.merge(%{x: 1.5, y: 70.0, z: -3.5, yaw: 0.0, pitch: 0.0}, player),
          inventory
        )

    test "are records of their own that round-trip and refuse what a file may not hold", ctx do
      gem = ItemStack.new("emerald", 12)

      state =
        captured(%{ender_items: %{0 => gem, 26 => ItemStack.new("stone", 64)}}, %Inventory{})

      records = PlayerState.records(state)
      assert records[{:ender, 0}] == gem and map_size(Map.take(records, [{:ender, 26}])) == 1
      refute Map.has_key?(records, {:player, :ender_items})

      {:ok, bytes} = PlayerState.encode(ctx.uuid, state)
      assert {:ok, ^state} = PlayerState.decode(bytes, ctx.uuid)

      # A file from before ender slots holds none: the player has an empty chest.
      assert captured(%{}, %Inventory{}).ender_items == %{}

      for bad <- [%{27 => gem}, %{-1 => gem}, %{0 => nil}, :none] do
        assert {:error, :invalid_ender_items} =
                 PlayerState.encode(ctx.uuid, %{state | ender_items: bad})
      end
    end

    test "a click moves a stack between them and the inventory in one frame", ctx do
      {:ok, storage, nil} = Storage.read(ctx.base, ctx.uuid)
      player = %{ender_items: %{3 => ItemStack.new("diamond", 5)}}
      inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 8)}}
      {:ok, storage} = Storage.cut(storage, captured(player, inventory))
      storage = commit(storage, ctx.base)

      # Shift-click the diamonds (window slot 3) into the hotbar.
      {:ok, player, inventory, []} =
        Valimc.Player.EnderChest.click(player, inventory, %{
          action: :quick_move,
          slot: 3,
          button: 0
        })

      assert player.ender_items == %{}
      assert inventory.slots[44] == ItemStack.new("diamond", 5)
      after_click = captured(player, inventory)
      {:ok, storage} = Storage.cut(storage, after_click)
      assert [{_, 2, frame}] = storage.outbox

      assert Enum.sort(:erlang.binary_to_term(frame)) ==
               Enum.sort([{:del, {:ender, 3}}, {:put, {:slot, 44}, ItemStack.new("diamond", 5)}])

      _ = commit(storage, ctx.base)
      # The click's state id is not saved; the slots are.
      assert {:ok, _, loaded} = Storage.read(ctx.base, ctx.uuid)
      assert loaded.ender_items == %{} and loaded.inventory.slots == after_click.inventory.slots
    end
  end

  defp commit(storage, base) do
    {frames, storage} = Storage.take(storage)
    Log.commit_group(base, {:region, :overworld, {0, 0}}, frames, self())
    acks = for {owner, seq, _} <- frames, do: {owner, seq}
    assert_receive {:storage_durable, ^acks}, 5000
    Enum.reduce(acks, storage, fn {_, seq}, acc -> elem(Storage.durable(acc, seq), 0) end)
  end
end

defmodule Valimc.EnderChestConnectionTest do
  @moduledoc """
  Ender chests through real connections (VMC-032c3): any ender chest shows
  the player's own 27 slots; clicks change them with the inventory; another
  player sees their own; the slots come back after a relog; removing the
  chest closes the menu.
  """
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Menus.Inventory
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.{TestConn, TestPlayer}

  @chest Valimc.Data.Blocks.state("ender_chest", %{"facing" => "north", "waterlogged" => "false"})

  setup do
    ctx = TestPlayer.scope("Ender", {101_000, 2560})
    {bx, _, bz} = {floor(ctx.pose.x), 64, floor(ctx.pose.z)}
    Map.merge(ctx, %{a: {bx, 64, bz + 3}, b: {bx, 64, bz - 3}})
  end

  defp save(ctx, ender_items, inventory) do
    TestPlayer.save(ctx, Map.put(ctx.pose, :ender_items, ender_items), inventory)
  end

  defp content(client, predicate \\ fn _ -> true end) do
    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    {_, client} = Client.await(client, :play, "set_cursor_item")
    if predicate.(client.inventory), do: client, else: content(client, predicate)
  end

  defp open(client, pid, position) do
    Client.send_packet(client, :play, "use_item_on", [
      Wire.varint(0),
      Wire.position(position),
      <<1, 0.5::float-32, 1.0::float-32, 0.5::float-32, 0, 0, 1>>
    ])

    {_, client} = Client.await(client, :play, "block_changed_ack")
    assert %{kind: :ender_chest} = TestConn.state(pid).table_menu
    {body, client} = Client.await(client, :play, "open_screen")
    {id, body} = Wire.take_varint(body)
    # `generic_9x3`, titled `container.enderchest`.
    assert {2, title} = Wire.take_varint(body)
    {_, expected} = Valimc.Menus.Packets.open_storage(id, :ender_chest)
    assert IO.iodata_to_binary(expected) =~ title
    client = content(client)
    assert client.inventory.container == id and length(client.inventory.items) == 63
    client
  end

  defp click(client, slot, button, action, expected) do
    Client.send_packet(client, :play, "container_click", [
      Wire.varint(client.inventory.container),
      <<0, slot::signed-16, button::signed-8>>,
      Wire.varint(ItemTypes.input_id(action)),
      <<0, 0>>
    ])

    content(client, expected)
  end

  defp close(client) do
    Client.send_packet(client, :play, "container_close", Wire.varint(client.inventory.container))
    content(client, &(&1.container == 0))
  end

  test "two chests show one player's slots; another player sees their own; a relog keeps them; removal closes the menu",
       ctx do
    diamonds = ItemStack.new("diamond", 5)
    stone = ItemStack.new("stone", 8)
    save(ctx, %{0 => diamonds}, %Inventory{slots: %{36 => stone}})
    :ok = Valimc.TestBlocks.set(ctx.a, @chest)
    :ok = Valimc.TestBlocks.set(ctx.b, @chest)

    {client, pid} = TestPlayer.login(ctx)
    client = open(client, pid, ctx.a)
    assert hd(client.inventory.items) == diamonds and Enum.at(client.inventory.items, 54) == stone

    # Shift-click the diamonds into the inventory; put the stone in slot 5.
    client = click(client, 0, 0, "quick_move", &(hd(&1.items) == nil))
    client = click(client, 54, 0, "pickup", &(&1.carried == stone))
    client = click(client, 5, 0, "pickup", &(&1.carried == nil and Enum.at(&1.items, 5) == stone))
    client = close(client)
    assert TestConn.state(pid).player.ender_items == %{5 => stone}

    # The other chest shows the same slots.
    client = open(client, pid, ctx.b)
    assert Enum.at(client.inventory.items, 5) == stone and hd(client.inventory.items) == nil
    assert Enum.count(client.inventory.items, &(&1 == diamonds)) == 1

    # Another player at the first chest sees only their own.
    name = "EnderB#{rem(System.unique_integer([:positive]), 1_000_000_000)}"
    other = %{ctx | name: name, uuid: Valimc.Data.UUID.offline(name)}
    other = %{other | path: Valimc.Player.Storage.path(ctx.base, other.uuid)}
    save(other, %{26 => ItemStack.new("emerald", 2)}, %Inventory{})
    {other_client, other_pid} = TestPlayer.login(other)
    other_client = open(other_client, other_pid, ctx.a)
    assert Enum.at(other_client.inventory.items, 26) == ItemStack.new("emerald", 2)
    assert Enum.at(other_client.inventory.items, 5) == nil

    # Removing the chest closes the first player's menu.
    assert :ok = Valimc.TestBlocks.remove(ctx.b)
    Valimc.TestWait.until(fn -> TestConn.state(pid).table_menu == nil end)

    saved = TestPlayer.saved(ctx, pid, &(&1.ender_items == %{5 => stone}))
    assert Map.values(saved.inventory.slots) == [diamonds]

    Client.close(client)
    Valimc.TestWait.until(fn -> Registry.lookup(Valimc.PlayerRegistry, ctx.uuid) == [] end)
    {:ok, snapshot} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    assert snapshot.ender_items == %{5 => stone}

    {client, pid} = TestPlayer.login(ctx)
    client = open(client, pid, ctx.a)
    assert Enum.at(client.inventory.items, 5) == stone
    _ = other_client
    _ = client
  end

  test "the slots ride the player's move to another group and save from there", ctx do
    # The test, not the regionizer, decides which group holds which section.
    Valimc.TestScope.isolate(Valimc.TestScope.neighborhood(ctx.key, 1), regionizer: false)
    gem = ItemStack.new("emerald", 4)
    save(ctx, %{1 => gem}, %Inventory{})
    :ok = Valimc.TestBlocks.set(ctx.a, @chest)
    {client, pid} = TestPlayer.login(ctx)
    source = :sys.get_state(pid).owner
    {rx, rz} = ctx.key
    {:ok, {target, _}} = Valimc.TestWorld.owner({rx + 1, rz})
    assert target != source
    {:ok, [_]} = Valimc.World.Region.hand_over(source, target)
    Valimc.TestWait.until(fn -> :sys.get_state(pid).owner == target end)

    client = open(client, pid, ctx.a)
    assert Enum.at(client.inventory.items, 1) == gem
    client = click(client, 1, 0, "pickup", &(&1.carried == gem))
    _client = click(client, 2, 0, "pickup", &(Enum.at(&1.items, 2) == gem))

    saved = TestPlayer.saved(ctx, pid, &(&1.ender_items == %{2 => gem}))
    assert saved.inventory.carried == nil
  end
end
