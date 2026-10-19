defmodule Valimc.TooltipConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{ItemStack, ItemTypes, TooltipDisplay, Wire}
  defp name, do: "Tip" <> Integer.to_string(System.unique_integer([:positive]))

  test "normal creative writes retain hidden item data and complete tooltip controls" do
    username = name()
    {_, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)

    stack = %{
      ItemStack.new("stone", 7)
      | components: %{
          "minecraft:custom_name" => {:string, "Hidden name"},
          "minecraft:lore" => [{:string, "Retained lore"}],
          "minecraft:enchantments" => %{"minecraft:unbreaking" => 3},
          "minecraft:tooltip_display" => %TooltipDisplay{
            hide: true,
            hidden: MapSet.new(["minecraft:lore"])
          }
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
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await(client, :play, "system_chat")
  end

  test "malformed/unknown tooltip set input rejects only its owner while a peer responds" do
    {_, healthy} = Client.login(name())
    on_exit(fn -> Client.close(healthy) end)

    for raw <- [<<0, 1, 122>>, <<0, 1>>, <<>>, IO.iodata_to_binary([<<0>>, Wire.varint(1025)])] do
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
        Wire.varint(ItemTypes.component_id("tooltip_display")),
        Wire.varint(byte_size(raw)),
        raw
      ])

      {body, _} = Client.await(bad, :play, "disconnect")
      assert :binary.match(body, "invalid creative item") != :nomatch
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 1000
      Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
      {_, _} = Client.await(healthy, :play, "system_chat")
    end
  end
end
