defmodule Valimc.InventoryConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.Inventory
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

  defp snapshot(client) do
    {body, client} = Client.await(client, :play, "container_set_content")
    Client.auto_reply(client, :play, "container_set_content", body)
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
    assert client.inventory.state_id == 3
    assert Enum.at(client.inventory.items, 9) == stone
    assert Enum.at(client.inventory.items, 45) == stone
    {body, client} = Client.await(client, :play, "set_cursor_item")
    assert ItemStack.decode(body) == {:ok, nil}

    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<0::signed-16>>,
      ItemStack.encode(stone, :untrusted)
    ])

    client = snapshot(client)
    assert client.inventory.state_id == 4
    assert Enum.at(client.inventory.items, 0) == nil
    player = Enum.find(Valimc.Players.all(), &(&1.name == username))
    assert map_size(:sys.get_state(player.pid).inventory.slots) == 2
  end

  test "26.3 abort and direction actions preserve blocks; completed creative breaking removes them" do
    {_, client} = Client.login(name())
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    position = {2, 64, 2}
    stone = Valimc.Protocol.Data.block("stone")
    Valimc.World.set_block(position, stone)

    client =
      Enum.reduce(["change_destroy_direction", "abort_destroy_block"], client, fn action,
                                                                                  client ->
        Client.send_packet(client, :play, "player_action", [
          Wire.varint(ItemTypes.action_id(action)),
          Wire.position(position),
          <<1, 92>>
        ])

        {<<92>>, client} = Client.await(client, :play, "block_changed_ack")
        assert Valimc.World.get_block(position) == stone
        client
      end)

    Client.send_packet(client, :play, "player_action", [
      Wire.varint(ItemTypes.action_id("stop_destroy_block")),
      Wire.position(position),
      <<1, 93>>
    ])

    {<<93>>, _} = Client.await(client, :play, "block_changed_ack")
    assert Valimc.World.get_block(position) == 0
  end

  test "hotbar selection, offhand placement and hand swap use only their owner's slots" do
    username = name()
    {_, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    {_, peer} = Client.login(name())
    on_exit(fn -> Client.close(peer) end)
    peer = Client.load_world(peer)
    assert peer.inventory.items == List.duplicate(nil, 46)
    main = ItemStack.new("stone", 4)
    off = ItemStack.new("oak_planks", 8)
    {_, client} = slot(client, 44, main)
    {_, client} = slot(client, 45, off)
    Client.send_packet(client, :play, "set_carried_item", <<8::signed-16>>)
    {<<8>>, client} = Client.await(client, :play, "set_held_slot")
    position = {4, 64, 0}
    Valimc.World.set_block(position, 0)

    Client.send_packet(client, :play, "use_item_on", [
      <<1>>,
      Wire.position({4, 63, 0}),
      <<1, 0::96, 0, 0, 71>>
    ])

    {<<71>>, client} = Client.await(client, :play, "block_changed_ack")
    assert Valimc.World.get_block(position) == Valimc.Protocol.Data.block("oak_planks")

    Client.send_packet(client, :play, "player_action", [
      Wire.varint(ItemTypes.action_id("swap_item_with_offhand")),
      Wire.position({0, 0, 0}),
      <<0, 0>>
    ])

    Enum.reduce([{44, off}, {45, main}], client, fn {expected_slot, stack}, client ->
      {body, client} = Client.await(client, :play, "container_set_slot")
      {0, body} = Wire.take_varint(body)
      {_, <<^expected_slot::signed-16, bytes::binary>>} = Wire.take_varint(body)
      assert ItemStack.decode(bytes) == {:ok, stack}
      client
    end)

    player = Enum.find(Valimc.Players.all(), &(&1.name == username))
    inventory = :sys.get_state(player.pid).inventory
    assert Inventory.held(inventory, :main) == off
    assert Inventory.held(inventory, :off) == main
  end
end
