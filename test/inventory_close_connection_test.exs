defmodule Valimc.InventoryCloseConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  defp name, do: "Close" <> Integer.to_string(System.unique_integer([:positive]))

  defp snapshot(client) do
    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    {_, client} = Client.await(client, :play, "set_cursor_item")
    client
  end

  defp seed(client, slot, stack) do
    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<slot::16>>,
      ItemStack.encode(stack, :untrusted)
    ])

    {_, client} = Client.await(client, :play, "container_set_slot")
    client
  end

  defp pickup(client, slot) do
    Client.send_packet(client, :play, "container_click", [
      <<0, 0, slot::signed-16, 0>>,
      Wire.varint(ItemTypes.input_id("pickup")),
      <<0, 0>>
    ])

    snapshot(client)
  end

  test "close returns owned cursor, cleans grid and ignores reported container ID without touching peers" do
    {_, client} = Client.login(name())
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    {_, peer} = Client.login(name())
    on_exit(fn -> Client.close(peer) end)
    peer = Client.load_world(peer)

    stone = %{
      ItemStack.new("stone", 7)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    client = client |> seed(9, stone) |> seed(1, ItemStack.new("egg", 3)) |> pickup(9)
    assert client.inventory.carried == stone

    client =
      Enum.reduce([{-999, 0}, {9, 1}], client, fn {slot, button}, client ->
        Client.send_packet(client, :play, "container_click", [
          <<0, 0, slot::signed-16, button>>,
          Wire.varint(ItemTypes.input_id("quick_craft")),
          <<0, 0>>
        ])

        snapshot(client)
      end)

    Client.send_packet(client, :play, "container_close", Wire.varint(99))
    client = snapshot(client)
    assert client.inventory.carried == nil
    assert Enum.at(client.inventory.items, 36) == stone
    assert Enum.at(client.inventory.items, 37) == ItemStack.new("egg", 3)
    assert Enum.at(client.inventory.items, 1) == nil
    before_late_end = client.inventory.items

    Client.send_packet(client, :play, "container_click", [
      <<0, 0, -999::signed-16, 2>>,
      Wire.varint(ItemTypes.input_id("quick_craft")),
      <<0, 0>>
    ])

    client = snapshot(client)
    assert client.inventory.items == before_late_end and client.inventory.carried == nil
    Client.send_packet(peer, :play, "container_close", <<0>>)
    peer = snapshot(peer)
    assert Enum.all?(peer.inventory.items, &is_nil/1) and peer.inventory.carried == nil
  end

  test "overflow rejects the entire plan; freeing capacity permits a retry without duplication" do
    username = name()
    {_, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)

    client =
      Enum.reduce(
        Enum.to_list(36..44) ++ Enum.to_list(9..35),
        client,
        &seed(&2, &1, ItemStack.new("stone", 64))
      )

    client = seed(client, 36, ItemStack.new("stone", 63))
    client = seed(client, 45, ItemStack.new("stone", 10)) |> pickup(45)
    owner = Enum.find(Valimc.Players.all(), &(&1.name == username)).pid

    :sys.replace_state(owner, fn s ->
      put_in(s.inventory.drag, %{mode: 0, slots: MapSet.new([9])})
    end)

    old = client.inventory
    Client.send_packet(client, :play, "container_close", <<0>>)
    {body, client} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, "world drops") != :nomatch
    client = snapshot(client)
    assert client.inventory.items == old.items and client.inventory.carried == old.carried
    assert :sys.get_state(owner).inventory.drag == nil
    client = seed(client, 37, nil)
    Client.send_packet(client, :play, "container_close", <<0>>)
    client = snapshot(client)
    assert client.inventory.carried == nil
    assert Enum.at(client.inventory.items, 36).count == 64
    assert Enum.at(client.inventory.items, 37).count == 9
    assert Enum.at(client.inventory.items, 45) == nil
  end

  test "malformed close disconnects only its sender" do
    username = name()
    {_, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    {_, peer} = Client.login(name())
    on_exit(fn -> Client.close(peer) end)
    peer = Client.load_world(peer)
    pid = Enum.find(Valimc.Players.all(), &(&1.name == username)).pid
    ref = Process.monitor(pid)
    Client.send_packet(client, :play, "container_close", <<0, 1>>)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    Client.send_packet(peer, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await(peer, :play, "system_chat")
    assert Process.alive?(Process.whereis(Valimc.Listener))
  end
end
