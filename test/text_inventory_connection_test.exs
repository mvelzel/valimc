defmodule Valimc.TextInventoryConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{ItemStack, ItemTypes, NBT, TextComponent, Wire}

  test "normal creative packets accept named/lore stacks and restore unsupported text without publication" do
    username = "Text" <> Integer.to_string(System.unique_integer([:positive]))
    {_, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)

    stack = %{
      ItemStack.new("stone", 7)
      | components: %{
          "minecraft:custom_name" =>
            {:compound, %{"text" => {:string, "ValiMC\0🚀"}, "color" => {:string, "gold"}}},
          "minecraft:lore" => [
            {:string, "First lore"},
            {:compound, %{"text" => {:string, "Second"}, "italic" => {:byte, 0}}}
          ]
        }
    }

    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<36::signed-16>>,
      ItemStack.encode(stack, :untrusted)
    ])

    {body, client} = Client.await(client, :play, "container_set_slot")
    {0, body} = Wire.take_varint(body)
    {_, <<36::signed-16, bytes::binary>>} = Wire.take_varint(body)
    assert {:ok, ^stack} = ItemStack.decode(bytes)
    player = Enum.find(Valimc.Players.all(), &(&1.name == username))
    assert :sys.get_state(player.pid).inventory.slots[36] == stack

    for tag <- [
          {:compound, %{"selector" => {:string, "@p"}}},
          {:compound,
           %{
             "text" => {:string, "Clickable"},
             "hover_event" =>
               {:compound, %{"action" => {:string, "show_text"}, "value" => {:string, "No"}}}
           }}
        ] do
      payload = NBT.encode(tag) |> IO.iodata_to_binary()
      lore = TextComponent.encode_lore([{:string, "Replacement"}]) |> IO.iodata_to_binary()

      Client.send_packet(client, :play, "set_creative_mode_slot", [
        <<36::signed-16>>,
        <<1>>,
        Wire.varint(stack.item_id),
        <<2, 0>>,
        Wire.varint(ItemTypes.component_id("custom_name")),
        Wire.varint(byte_size(payload)),
        payload,
        Wire.varint(ItemTypes.component_id("lore")),
        Wire.varint(byte_size(lore)),
        lore
      ])

      {chat, client} = Client.await(client, :play, "system_chat")
      assert :binary.match(chat, "slot restored") != :nomatch
      {body, client} = Client.await(client, :play, "container_set_slot")
      {0, body} = Wire.take_varint(body)
      {_, <<36::signed-16, bytes::binary>>} = Wire.take_varint(body)
      assert {:ok, ^stack} = ItemStack.decode(bytes)
      assert :sys.get_state(player.pid).inventory.slots[36] == stack
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {chat, _} = Client.await(client, :play, "system_chat")
      assert :binary.match(chat, "schedulers") != :nomatch
    end
  end
end
