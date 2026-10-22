defmodule Valimc.InventoryPersistenceTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Inventory, PlayerStore, Players}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.World.Entities
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client
  import ExUnit.CaptureLog

  setup do
    base = Path.join(System.tmp_dir!(), "valimc-inventory-#{System.unique_integer([:positive])}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)

    on_exit(fn ->
      Application.put_env(:valimc, :world_path, old)
      Valimc.TestScope.stop_neighbourhood({0, 0})
      Valimc.TestScope.stop_players(base)
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
    {_, client} = Client.await_stats(client)
    client
  end

  defp login(name) do
    {uuid, client} = Client.login(name)
    {uuid, Client.load_world(client)}
  end

  defp close(client, name, uuid) do
    ref = Process.monitor(player(name).pid)
    Client.close(client)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    departed(uuid)
  end

  test "owned storage survives reconnect/shutdown while cursor/grid drop once; drag and authority reset",
       %{base: base} do
    username = name()
    uuid = Valimc.Connection.offline_uuid(username)
    key = {60_000 + rem(System.unique_integer([:positive]), 3_333) * 3, 400}
    {rx, rz} = key
    pose = %{x: rx * 128 + 64.5, y: 64.0, z: rz * 128 + 64.5, yaw: 0.0, pitch: 0.0}
    {:ok, bytes} = PlayerState.encode(uuid, PlayerState.capture(pose, Inventory.new()))
    path = PlayerStore.path(base, uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    on_exit(fn -> Valimc.TestScope.stop_neighbourhood(key) end)

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
    original = Valimc.TestConn.state(player(username).pid).inventory
    assert original.drag != nil and original.carried == stone
    close(client, username, uuid)

    expected = %{original | slots: Map.drop(original.slots, [1]), carried: nil}
    {:ok, region} = Valimc.TestWorld.item_owner(key)
    records = Entities.records(Valimc.TestRegion.section(region).entities.store)

    assert Enum.map(records, & &1.stack) |> MapSet.new() ==
             MapSet.new([stone, ItemStack.new("egg", 3)])

    {^uuid, second} = login(username)
    state = Valimc.TestConn.state(player(username).pid)
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

    assert Entities.records(Valimc.TestRegion.section(region).entities.store) == records

    close(third, username, uuid)
    other = name()
    {other_uuid, client} = login(other)
    assert client.inventory.items == List.duplicate(nil, 46) and client.inventory.carried == nil
    close(client, other, other_uuid)
  end

  test "an accepted inventory frame before a later malformed frame survives final save" do
    username = name()
    {uuid, client} = login(username)
    pid = player(username).pid
    state = Valimc.TestConn.state(pid)
    ref = Process.monitor(pid)
    stone = ItemStack.new("stone", 19)

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
        Wire.frame(Data.id(:play, :serverbound, "container_click"), <<>>, client.threshold)
      ])

    send(pid, {:tcp, state.socket, batch})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    Client.close(client)
    departed(uuid)
    {^uuid, next} = login(username)
    assert Enum.at(next.inventory.items, 38) == stone and next.selected == 2
    close(next, username, uuid)
  end

  test "a player file from before M1 refuses the login and stays as it was", %{base: base} do
    username = name()
    uuid = Valimc.Connection.offline_uuid(username)

    payload =
      <<"VMCPOSE", 1, uuid::binary-size(16), -3.25::float-64, 64.0::float-64, 0.5::float-64,
        90.0::float-32, -25.0::float-32>>

    legacy = payload <> :crypto.hash(:sha256, payload)
    path = PlayerStore.path(base, uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, legacy)
    client = Client.connect()

    assert capture_log(fn ->
             Client.send_packet(client, :handshake, "intention", [
               Wire.varint(777),
               Wire.string("localhost"),
               <<25565::16, 2>>
             ])

             Client.send_packet(client, :login, "hello", [Wire.string(username), <<0::128>>])
             {id, body, _} = Client.read(client)
             assert id == Data.id(:login, :clientbound, "login_disconnect")
             assert :binary.match(body, "Player save unavailable") != :nomatch
           end) =~ "invalid_player_file"

    Client.close(client)
    assert File.read!(path) == legacy
  end
end
