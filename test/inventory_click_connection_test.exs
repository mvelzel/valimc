defmodule Valimc.InventoryClickConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  defp name, do: "Click" <> Integer.to_string(System.unique_integer([:positive]))

  defp click(client, action, slot, button) do
    Client.send_packet(client, :play, "container_click", [
      <<0, 0, slot::signed-16, button::signed-8>>,
      Wire.varint(ItemTypes.input_id(action)),
      <<0, 0>>
    ])

    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    {_, client} = Client.await(client, :play, "set_cursor_item")
    client
  end

  test "quick-craft commits owned items and an unsupported mode cancels before the next pickup" do
    {_, client} = Client.login(name())
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)

    stone = %{
      ItemStack.new("stone", 17)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<36::16>>,
      ItemStack.encode(stone, :untrusted)
    ])

    {_, client} = Client.await(client, :play, "container_set_slot")
    client = click(client, "pickup", 36, 0)
    client = click(client, "quick_craft", -999, 0)
    client = click(client, "quick_craft", 9, 1)
    client = click(client, "quick_craft", 10, 1)
    assert client.inventory.carried == stone
    assert Enum.at(client.inventory.items, 9) == nil
    client = click(client, "quick_craft", -999, 2)
    assert Enum.at(client.inventory.items, 9) == %{stone | count: 8}
    assert Enum.at(client.inventory.items, 10) == %{stone | count: 8}
    assert client.inventory.carried == %{stone | count: 1}
    client = click(client, "quick_craft", -999, 0)
    client = click(client, "quick_craft", -999, 12)
    assert client.inventory.carried == %{stone | count: 1}
    client = click(client, "pickup", 11, 0)
    assert client.inventory.carried == nil
    assert Enum.at(client.inventory.items, 11) == %{stone | count: 1}
  end

  test "collection prioritizes partial owned stacks, corrects invalid buttons and leaves peers alone" do
    {_, client} = Client.login(name())
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    {_, peer} = Client.login(name())
    on_exit(fn -> Client.close(peer) end)
    peer = Client.load_world(peer)

    shiny = %{
      ItemStack.new("stone")
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    client =
      Enum.reduce([{9, 64}, {10, 7}, {11, 9}, {36, 50}], client, fn {slot, count}, client ->
        Client.send_packet(client, :play, "set_creative_mode_slot", [
          <<slot::16>>,
          ItemStack.encode(%{shiny | count: count}, :untrusted)
        ])

        {_, client} = Client.await(client, :play, "container_set_slot")
        client
      end)

    client = click(client, "pickup", 36, 0)
    client = click(client, "pickup_all", 36, 0)
    assert client.inventory.carried == %{shiny | count: 64}
    assert Enum.at(client.inventory.items, 9) == %{shiny | count: 64}
    assert Enum.at(client.inventory.items, 10) == nil
    assert Enum.at(client.inventory.items, 11) == %{shiny | count: 2}
    old = client.inventory.items
    client = click(client, "pickup_all", 36, 2)
    assert client.inventory.items == old and client.inventory.carried == %{shiny | count: 64}
    Client.send_packet(peer, :play, "container_close", <<0>>)
    {body, peer} = Client.await(peer, :play, "container_set_content")
    peer = Client.auto_reply(peer, :play, "container_set_content", body)
    assert peer.inventory.carried == nil and Enum.all?(peer.inventory.items, &is_nil/1)
  end

  test "creative clone/fill use only owned items and revoked owner permission prevents duplication" do
    username = name()
    {_, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)

    eggs = %{
      ItemStack.new("egg", 3)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<36::16>>,
      ItemStack.encode(eggs, :untrusted)
    ])

    {_, client} = Client.await(client, :play, "container_set_slot")
    client = click(client, "clone", 36, 2)
    assert client.inventory.carried == %{eggs | count: 16}
    assert Enum.at(client.inventory.items, 36) == eggs
    client = click(client, "quick_craft", -999, 8)
    client = click(client, "quick_craft", 9, 9)
    client = click(client, "quick_craft", 10, 9)
    client = click(client, "quick_craft", -999, 10)
    assert client.inventory.carried == nil
    assert Enum.at(client.inventory.items, 9) == %{eggs | count: 16}
    assert Enum.at(client.inventory.items, 10) == %{eggs | count: 16}
    owner = Enum.find(Valimc.Players.all(), &(&1.name == username)).pid

    :sys.replace_state(owner, fn s ->
      %{s | inventory: %{s.inventory | infinite_materials: false}}
    end)

    client = click(client, "clone", 36, 2)
    assert client.inventory.carried == nil
    client = click(client, "pickup", 36, 0)
    client = click(client, "quick_craft", -999, 8)
    client = click(client, "quick_craft", 11, 9)
    client = click(client, "quick_craft", 12, 9)
    client = click(client, "quick_craft", -999, 10)
    assert client.inventory.carried == eggs

    assert Enum.at(client.inventory.items, 11) == nil and
             Enum.at(client.inventory.items, 12) == nil

    assert not :sys.get_state(owner).inventory.infinite_materials
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
    player = Enum.find(Valimc.Players.all(), &(&1.name == username))
    ref = Process.monitor(player.pid)
    Client.send_packet(client, :play, "container_click", <<0, 0, 9::16, 0, 0, 0, 0, 99>>)
    {body, _} = Client.await(client, :play, "disconnect")
    assert :binary.match(body, "Malformed inventory click") != :nomatch
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1000
    Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await(healthy, :play, "system_chat")
    assert Process.alive?(Process.whereis(Valimc.Listener))
  end
end
