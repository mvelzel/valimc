defmodule Valimc.InventoryPersistenceTest do
  use ExUnit.Case, async: false
  alias Valimc.{Inventory, PlayerSnapshot, PlayerStore, Players, World}
  alias Valimc.World.Items
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client
  import ExUnit.CaptureLog

  setup do
    base = Path.join(System.tmp_dir!(), "valimc-inventory-#{System.unique_integer([:positive])}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)

    on_exit(fn ->
      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    %{base: base}
  end

  defp name, do: "Save" <> Integer.to_string(System.unique_integer([:positive]))

  defp player(name),
    do:
      Enum.find_value(:ets.tab2list(Players), fn {_, player} ->
        if player.name == name, do: player
      end)

  defp departed(uuid, retries \\ 100) do
    if Registry.lookup(Valimc.PlayerStoreRegistry, uuid) != [] do
      assert retries > 0
      Process.sleep(10)
      departed(uuid, retries - 1)
    end
  end

  defp seed(client, slot, stack) do
    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<slot::signed-16>>,
      ItemStack.encode(stack, :untrusted)
    ])

    {_, client} = Client.await(client, :play, "container_set_slot")
    client
  end

  defp click(client, type, slot, button) do
    Client.send_packet(client, :play, "container_click", [
      <<0, 0, slot::signed-16, button>>,
      Wire.varint(ItemTypes.input_id(type)),
      <<0, 0>>
    ])

    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    {_, client} = Client.await(client, :play, "set_cursor_item")
    client
  end

  defp barrier(client) do
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, client} = Client.await(client, :play, "system_chat")
    client
  end

  defp login(name) do
    {uuid, client} = Client.login(name)
    {uuid, Client.load_world(client)}
  end

  defp close(client, name, uuid) do
    ref = Process.monitor(player(name).pid)
    Client.close(client)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1000
    departed(uuid)
  end

  test "owned storage survives reconnect/shutdown while cursor/grid drop once; drag and authority reset",
       %{base: base} do
    username = name()
    uuid = Valimc.Connection.offline_uuid(username)
    key = {60_000 + rem(System.unique_integer([:positive]), 10_000), 400}
    {rx, rz} = key
    pose = %{x: rx * 128 + 64.5, y: 64.0, z: rz * 128 + 64.5, yaw: 0.0, pitch: 0.0}
    {:ok, bytes} = PlayerSnapshot.encode(uuid, PlayerSnapshot.capture(pose, Inventory.new()))
    path = PlayerStore.path(base, uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    end)

    {uuid, client} = login(username)

    stone = %{
      ItemStack.new("stone", 7)
      | components: %{
          "minecraft:enchantment_glint_override" => true,
          "minecraft:custom_data" => {:compound, %{"save" => {:string, "exact"}}}
        },
        removed: MapSet.new(["minecraft:rarity"])
    }

    client =
      client
      |> seed(9, stone)
      |> seed(1, ItemStack.new("egg", 3))
      |> seed(5, ItemStack.new("diamond_helmet"))
      |> seed(38, ItemStack.new("stone", 23))
      |> seed(45, ItemStack.new("shield"))
      |> click("pickup", 9, 0)
      |> click("quick_craft", -999, 0)
      |> click("quick_craft", 10, 1)

    Client.send_packet(client, :play, "set_carried_item", <<2::signed-16>>)
    client = barrier(client)
    original = :sys.get_state(player(username).pid).inventory
    assert original.drag != nil and original.carried == stone
    close(client, username, uuid)

    expected = %{original | slots: Map.drop(original.slots, [1]), carried: nil}
    {:ok, {region, _}} = World.item_owner(key)
    records = Items.records(:sys.get_state(region).resource.items)

    assert Enum.map(records, & &1.stack) |> MapSet.new() ==
             MapSet.new([stone, ItemStack.new("egg", 3)])

    {:ok, saved} = PlayerSnapshot.decode(File.read!(path), uuid)
    assert saved.transfer_sequence == 1 and saved.outbox == nil

    {^uuid, second} = login(username)
    state = :sys.get_state(player(username).pid)
    assert state.inventory.slots == expected.slots and state.inventory.carried == nil
    assert state.inventory.selected == 2 and second.selected == 2
    assert second.inventory.carried == nil
    assert second.inventory.items == Inventory.contents(expected)
    assert state.inventory.drag == nil and state.inventory.state_id == 0
    assert state.inventory.infinite_materials
    pid = player(username).pid
    assert :ok = DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, pid)
    Client.close(second)
    departed(uuid)
    {^uuid, third} = login(username)

    assert third.inventory.items == Inventory.contents(expected) and
             third.inventory.carried == nil

    assert Items.records(:sys.get_state(region).resource.items) == records

    close(third, username, uuid)
    other = name()
    {other_uuid, client} = login(other)
    assert client.inventory.items == List.duplicate(nil, 46) and client.inventory.carried == nil
    close(client, other, other_uuid)
  end

  test "a stalled checkpoint captures one immutable inventory; later edits survive final close",
       %{base: base} do
    username = name()
    {uuid, client} = login(username)
    stone = ItemStack.new("stone", 7)
    egg = ItemStack.new("egg", 3)
    client = seed(client, 9, stone)
    [{writer, _}] = Registry.lookup(Valimc.PlayerStoreRegistry, uuid)
    pid = player(username).pid
    :sys.suspend(writer)

    try do
      send(pid, :save_player)
      assert is_reference(:sys.get_state(pid).save_ref)
      _client = seed(client, 9, egg)
      for _ <- 1..3, do: send(pid, :save_player)
      assert :sys.get_state(pid).inventory.slots[9] == egg
      assert {:message_queue_len, 1} = Process.info(writer, :message_queue_len)
    after
      :sys.resume(writer)
    end

    # Writer barrier: the earlier cast has committed before this rejected foreign load.
    assert {:error, :not_owner} = GenServer.call(writer, :load)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(PlayerStore.path(base, uuid)), uuid)
    assert saved.inventory.slots[9] == stone
    close(client, username, uuid)
    {^uuid, next} = login(username)
    assert Enum.at(next.inventory.items, 9) == egg
    close(next, username, uuid)
  end

  test "an accepted inventory frame before a later malformed frame survives final save" do
    for bad <- [:malformed_frame, :malformed_payload] do
      username = name()
      {uuid, client} = login(username)
      pid = player(username).pid
      state = :sys.get_state(pid)
      ref = Process.monitor(pid)
      stone = ItemStack.new("stone", 19)

      broken =
        if bad == :malformed_frame,
          do: <<128, 128, 128, 128, 128, 128>>,
          else:
            Wire.frame(Data.id(:play, :serverbound, "container_click"), <<>>, client.threshold)

      batch =
        IO.iodata_to_binary([
          Wire.frame(
            Data.id(:play, :serverbound, "set_creative_mode_slot"),
            [<<38::signed-16>>, ItemStack.encode(stone, :untrusted)],
            client.threshold
          ),
          Wire.frame(
            Data.id(:play, :serverbound, "set_carried_item"),
            <<2::signed-16>>,
            client.threshold
          ),
          broken
        ])

      send(pid, {:tcp, state.socket, batch})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      Client.close(client)
      departed(uuid)
      {^uuid, next} = login(username)
      assert Enum.at(next.inventory.items, 38) == stone and next.selected == 2
      close(next, username, uuid)
    end
  end

  test "legacy login is read-only until a valid save and rejected configuration does not migrate",
       %{base: base} do
    username = name()
    uuid = Valimc.Connection.offline_uuid(username)

    payload =
      <<"VMCPOSE", 1, uuid::binary-size(16), -3.25::float-64, 64.0::float-64, 0.5::float-64,
        90.0::float-32, -25.0::float-32>>

    legacy = payload <> :crypto.hash(:sha256, payload)
    path = PlayerStore.path(base, uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, legacy)
    {^uuid, client} = Client.configure(username)
    assert File.read!(path) == legacy
    pid = player(username).pid
    ref = Process.monitor(pid)
    Client.send_packet(client, :configuration, "finish_configuration", <<1>>)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    Client.close(client)
    departed(uuid)
    assert File.read!(path) == legacy
    {^uuid, client} = login(username)
    assert client.pose.x == -3.25 and client.pose.yaw == 90.0
    assert client.inventory.items == List.duplicate(nil, 46)
    close(client, username, uuid)

    assert <<"VMCPOSE", 19, _::binary-size(52), 18, 0::32, 17, 0, 12, 0::signed-32, _::binary>> =
             bytes = File.read!(path)

    assert {:ok, saved} = PlayerSnapshot.decode(bytes, uuid)
    assert saved.air_supply == 300 and saved.health.value == 20.0
    assert saved.fire_ticks == 0
    assert saved.effects == %{}
    assert saved.absorption == 0.0
    assert saved.food == %Valimc.PlayerFood{}
  end

  test "foreign writers and invalid snapshots cannot overwrite a valid saved inventory", %{
    base: base
  } do
    uuid = :crypto.strong_rand_bytes(16)
    {:ok, writer, nil, writer_fence} = PlayerStore.open(uuid)
    pose = %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}
    inv = %Inventory{slots: %{9 => ItemStack.new("stone", 7)}}
    snapshot = PlayerSnapshot.capture(pose, inv)
    ref = make_ref()
    PlayerStore.checkpoint(writer, writer_fence, snapshot, ref)
    assert_receive {:player_saved, ^ref, :ok}
    saved = File.read!(PlayerStore.path(base, uuid))

    task =
      Task.async(fn ->
        PlayerStore.checkpoint(
          writer,
          writer_fence,
          PlayerSnapshot.capture(pose, Inventory.new()),
          make_ref()
        )

        GenServer.call(writer, :load)
      end)

    assert {:error, :not_owner} = Task.await(task)
    assert File.read!(PlayerStore.path(base, uuid)) == saved and Process.alive?(writer)

    assert capture_log(fn ->
             ref = make_ref()

             PlayerStore.checkpoint(
               writer,
               writer_fence,
               PlayerSnapshot.capture(pose, %{inv | selected: 9}),
               ref
             )

             assert_receive {:player_saved, ^ref, {:error, :invalid_inventory}}
           end) =~ "Player state save failed"

    assert File.read!(PlayerStore.path(base, uuid)) == saved
    assert :ok = PlayerStore.close(writer, writer_fence, snapshot)
  end
end
