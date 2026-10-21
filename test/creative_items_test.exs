defmodule Valimc.CreativeItemsTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{ItemStack, ItemTypes, TooltipDisplay, Wire}

  defp name, do: "Item" <> Integer.to_string(System.unique_integer([:positive]))

  defp set_slot(client, slot, stack) do
    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<slot::signed-16>>,
      ItemStack.encode(stack, :untrusted)
    ])

    slot_reply(client, slot)
  end

  defp slot_reply(client, expected_slot) do
    {body, client} = Client.await(client, :play, "container_set_slot")
    {0, body} = Wire.take_varint(body)
    {state_id, <<slot::signed-16, bytes::binary>>} = Wire.take_varint(body)
    assert slot == expected_slot
    {:ok, stack} = ItemStack.decode(bytes)
    {stack, state_id, client}
  end

  test "hotbar corrections preserve stacks and components; non-block items do not place blocks" do
    username = name()
    {_, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)

    # Text, enchantment and tooltip components round-trip exactly (their codecs
    # are compared with vanilla by the text, enchantment and tooltip oracles).
    rich = %{
      ItemStack.new("stone", 7)
      | components: %{
          "minecraft:custom_name" =>
            {:compound, %{"text" => {:string, "ValiMC\0🚀"}, "color" => {:string, "gold"}}},
          "minecraft:lore" => [
            {:string, "First lore"},
            {:compound, %{"text" => {:string, "Second"}, "italic" => {:byte, 0}}}
          ],
          "minecraft:enchantments" => %{"minecraft:unbreaking" => 3},
          "minecraft:stored_enchantments" => %{"minecraft:sharpness" => 5},
          "minecraft:tooltip_display" => %TooltipDisplay{
            hide: true,
            hidden: MapSet.new(["minecraft:lore"])
          }
        }
    }

    {^rich, _, client} = set_slot(client, 37, rich)
    player = Enum.find(Valimc.Players.all(), &(&1.name == username))
    assert :sys.get_state(player.pid).inventory.slots[37] == rich

    stack = %{
      ItemStack.new("stone", 17)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    {^stack, 2, client} = set_slot(client, 36, stack)
    position = {3, 64, 3}
    Valimc.World.set_block(position, 0)
    use = [<<0>>, Wire.position({3, 63, 3}), <<1, 0::96, 0, 0, 11>>]
    Client.send_packet(client, :play, "use_item_on", use)
    {<<11>>, client} = Client.await(client, :play, "block_changed_ack")
    assert Valimc.World.get_block(position) == Valimc.Protocol.Data.block("stone")
    {nil, 3, client} = set_slot(client, 36, nil)
    Valimc.World.set_block(position, 0)
    egg = ItemStack.new("egg", 16)
    {^egg, 4, client} = set_slot(client, 36, egg)
    Client.send_packet(client, :play, "use_item_on", use)
    {<<11>>, _} = Client.await(client, :play, "block_changed_ack")
    assert Valimc.World.get_block(position) == 0
  end

  test "unsupported delimited components restore the prior authoritative slot and keep session alive" do
    username = name()
    {_, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    stone = ItemStack.new("stone", 23)
    {^stone, _, client} = set_slot(client, 36, stone)

    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<36::signed-16, 1>>,
      Wire.varint(ItemTypes.id("stone")),
      <<1, 0>>,
      Wire.varint(ItemTypes.component_id("attribute_modifiers")),
      <<2, 10, 0>>
    ])

    {^stone, 2, client} = slot_reply(client, 36)
    player = Enum.find(Valimc.Players.all(), &(&1.name == username))
    assert Valimc.Inventory.get(:sys.get_state(player.pid).inventory, 36) == stone
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await_stats(client)
  end

  test "malformed creative stacks disconnect their owner while peers keep responding" do
    username = name()
    {_, bad} = Client.login(username)
    on_exit(fn -> Client.close(bad) end)
    {_, healthy} = Client.login(name())
    on_exit(fn -> Client.close(healthy) end)
    player = Enum.find(Valimc.Players.all(), &(&1.name == username))
    ref = Process.monitor(player.pid)
    Client.send_packet(bad, :play, "set_creative_mode_slot", <<36::16, 0, 99>>)
    {body, _} = Client.await(bad, :play, "disconnect")
    assert :binary.match(body, "invalid creative item") != :nomatch
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await_stats(healthy)
    assert Process.alive?(Process.whereis(Valimc.Listener))
  end

  test "custom NBT depth exhaustion disconnects only the submitting session" do
    username = name()
    {_, bad} = Client.login(username)
    on_exit(fn -> Client.close(bad) end)
    {_, healthy} = Client.login(name())
    on_exit(fn -> Client.close(healthy) end)
    player = Enum.find(Valimc.Players.all(), &(&1.name == username))
    ref = Process.monitor(player.pid)
    # A syntactically complete chain exceeds the decoder's independent depth budget.
    nbt = <<10>> <> :binary.copy(<<10, 0, 1, ?x>>, 33) <> :binary.copy(<<0>>, 34)

    Client.send_packet(bad, :play, "set_creative_mode_slot", [
      <<36::signed-16, 1>>,
      Wire.varint(ItemTypes.id("stone")),
      <<1, 0>>,
      Wire.varint(ItemTypes.component_id("custom_data")),
      Wire.varint(byte_size(nbt)),
      nbt
    ])

    {body, _} = Client.await(bad, :play, "disconnect")
    assert :binary.match(body, "invalid creative item") != :nomatch
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await_stats(healthy)
    assert Process.alive?(Process.whereis(Valimc.Listener))
  end
end
