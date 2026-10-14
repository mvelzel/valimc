defmodule Valimc.EnchantmentConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{Enchantments, ItemStack, ItemTypes, Wire}

  defp name, do: "Ench" <> Integer.to_string(System.unique_integer([:positive]))

  test "normal creative packets retain active/stored maps and overwritten duplicate levels" do
    username = name()
    {_, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)

    item = %{
      ItemStack.new("stone", 7)
      | components: %{
          "minecraft:enchantments" => %{"minecraft:unbreaking" => 3},
          "minecraft:stored_enchantments" => %{"minecraft:sharpness" => 5}
        }
    }

    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<36::signed-16>>,
      ItemStack.encode(item, :untrusted)
    ])

    {body, client} = Client.await(client, :play, "container_set_slot")
    {0, body} = Wire.take_varint(body)
    {_, <<36::signed-16, body::binary>>} = Wire.take_varint(body)
    assert {:ok, ^item} = ItemStack.decode(body)
    id = Enchantments.id("minecraft:unbreaking")
    value = IO.iodata_to_binary([<<2, id>>, Wire.varint(-1), <<id, 3>>])

    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<36::signed-16, 7>>,
      Wire.varint(item.item_id),
      <<1, 0>>,
      Wire.varint(ItemTypes.component_id("enchantments")),
      Wire.varint(byte_size(value)),
      value
    ])

    {body, client} = Client.await(client, :play, "container_set_slot")
    {0, body} = Wire.take_varint(body)
    {_, <<36::signed-16, body::binary>>} = Wire.take_varint(body)
    expected = %{item | components: Map.delete(item.components, "minecraft:stored_enchantments")}
    assert {:ok, ^expected} = ItemStack.decode(body)
    player = Enum.find(Valimc.Players.all(), &(&1.name == username))
    assert :sys.get_state(player.pid).inventory.slots[36] == expected
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await(client, :play, "system_chat")
  end

  test "invalid IDs/levels and excessive entry work disconnect only their submitting owners" do
    {_, healthy} = Client.login(name())
    on_exit(fn -> Client.close(healthy) end)
    id = Enchantments.id("minecraft:unbreaking")

    for raw <- [
          IO.iodata_to_binary([<<2, id, 3, 43, 1>>]),
          IO.iodata_to_binary([<<1, id>>, Wire.varint(-1)]),
          Wire.varint(1025)
        ] do
      username = name()
      {_, bad} = Client.login(username)
      on_exit(fn -> Client.close(bad) end)
      bad = Client.load_world(bad)
      player = Enum.find(Valimc.Players.all(), &(&1.name == username))
      ref = Process.monitor(player.pid)

      Client.send_packet(bad, :play, "set_creative_mode_slot", [
        <<36::signed-16, 1>>,
        Wire.varint(ItemTypes.id("stone")),
        <<1, 0>>,
        Wire.varint(ItemTypes.component_id("enchantments")),
        Wire.varint(byte_size(raw)),
        raw
      ])

      {body, _} = Client.await(bad, :play, "disconnect")
      assert :binary.match(body, "invalid creative item") != :nomatch
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 1000
      Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
      {_, _} = Client.await(healthy, :play, "system_chat")
      assert Process.alive?(Process.whereis(Valimc.Listener))
    end
  end
end
