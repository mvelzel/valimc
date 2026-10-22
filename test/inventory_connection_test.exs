defmodule Valimc.InventoryConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}

  defp name, do: "Inv" <> Integer.to_string(System.unique_integer([:positive]))

  defp slot(client, slot, stack) do
    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<slot::signed-16>>,
      ItemStack.encode(stack, :untrusted)
    ])

    {body, client} = Client.await(client, :play, "container_set_slot")
    {0, body} = Wire.take_varint(body)
    {id, <<^slot::signed-16, body::binary>>} = Wire.take_varint(body)
    assert {:ok, ^stack} = ItemStack.decode(body)
    {id, client}
  end

  defp seed(client, slot, stack) do
    {_, client} = slot(client, slot, stack)
    client
  end

  defp snapshot(client) do
    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    {_, client} = Client.await(client, :play, "set_cursor_item")
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

  test "startup, full player slots, unsupported clicks and out-of-range edits resynchronize" do
    username = name()
    {_, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    assert client.inventory.items == List.duplicate(nil, 46)
    assert client.inventory.container == 0
    assert client.inventory.carried == nil
    assert client.selected == 0
    stone = ItemStack.new("stone", 17)
    {1, client} = slot(client, 9, stone)
    {2, client} = slot(client, 45, stone)
    # No client prediction, even a forged one, is accepted before click semantics land.
    Client.send_packet(client, :play, "container_click", [
      <<0, 0, 9::signed-16, 0>>,
      Wire.varint(ItemTypes.input_id("quick_craft")),
      <<0, 0>>
    ])

    client = snapshot(client)
    assert client.inventory.state_id == 3 and client.inventory.carried == nil
    assert Enum.at(client.inventory.items, 9) == stone
    assert Enum.at(client.inventory.items, 45) == stone

    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<0::signed-16>>,
      ItemStack.encode(stone, :untrusted)
    ])

    client = snapshot(client)
    assert client.inventory.state_id == 4
    assert Enum.at(client.inventory.items, 0) == nil
    player = Enum.find(Valimc.Player.PlayerList.all(), &(&1.name == username))
    assert map_size(Valimc.TestConn.state(player.pid).inventory.slots) == 2
  end

  test "stale clicks use owned stacks; forged predictions cannot create items; malformed clicks stay isolated" do
    username = name()
    {_, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    {_, healthy} = Client.login(name())
    on_exit(fn -> Client.close(healthy) end)
    eggs = ItemStack.new("egg", 9)

    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<9::16>>,
      ItemStack.encode(eggs, :untrusted)
    ])

    {_, client} = Client.await(client, :play, "container_set_slot")
    # Predict unrelated stone with a nonempty hash map and an invented diamond cursor.
    forged = [
      <<0, 0, 9::16, 1>>,
      Wire.varint(ItemTypes.input_id("pickup")),
      <<1, 9::16, 1>>,
      Wire.varint(ItemTypes.id("stone")),
      <<17, 1>>,
      Wire.varint(ItemTypes.component_id("enchantment_glint_override")),
      <<0x12345678::32, 0>>,
      <<1>>,
      Wire.varint(ItemTypes.id("diamond")),
      <<99, 0, 1>>,
      Wire.varint(ItemTypes.component_id("item_name"))
    ]

    Client.send_packet(client, :play, "container_click", forged)
    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    assert client.inventory.carried.item_id == eggs.item_id
    assert client.inventory.carried.count == 5
    assert Enum.at(client.inventory.items, 9).count == 4
    {cursor, client} = Client.await(client, :play, "set_cursor_item")
    assert ItemStack.decode(cursor) == {:ok, %{eggs | count: 5}}
    player = Enum.find(Valimc.Player.PlayerList.all(), &(&1.name == username))
    ref = Process.monitor(player.pid)
    Client.send_packet(client, :play, "container_click", <<0, 0, 9::16, 0, 0, 0, 0, 99>>)
    {body, _} = Client.await(client, :play, "disconnect")
    assert :binary.match(body, "Malformed inventory click") != :nomatch
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await_stats(healthy)
    assert Process.alive?(Process.whereis(Valimc.Net.Listener))
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
end
