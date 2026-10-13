defmodule Valimc.InventoryClickConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  defp name, do: "Click" <> Integer.to_string(System.unique_integer([:positive]))

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
