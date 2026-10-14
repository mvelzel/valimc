defmodule Valimc.CreativeItemsTest do
  use ExUnit.Case, async: false
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}

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
    {_, client} = Client.login(name())
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)

    stack = %{
      ItemStack.new("stone", 17)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    {^stack, 1, client} = set_slot(client, 36, stack)
    position = {3, 64, 3}
    Valimc.World.set_block(position, 0)
    use = [<<0>>, Wire.position({3, 63, 3}), <<1, 0::96, 0, 0, 11>>]
    Client.send_packet(client, :play, "use_item_on", use)
    {<<11>>, client} = Client.await(client, :play, "block_changed_ack")
    assert Valimc.World.get_block(position) == Valimc.Protocol.Data.block("stone")
    {nil, 2, client} = set_slot(client, 36, nil)
    Valimc.World.set_block(position, 0)
    egg = ItemStack.new("egg", 16)
    {^egg, 3, client} = set_slot(client, 36, egg)
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
    {_, _} = Client.await(client, :play, "system_chat")
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
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1000
    Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await(healthy, :play, "system_chat")
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
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1000
    Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await(healthy, :play, "system_chat")
    assert Process.alive?(Process.whereis(Valimc.Listener))
  end
end
