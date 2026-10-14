defmodule Valimc.EffectiveIdentityConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.{Inventory, Players}
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client

  defp seed(client, slot, stack) do
    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<slot::signed-16>>,
      ItemStack.encode(stack, :untrusted)
    ])

    {_, client} = Client.await(client, :play, "container_set_slot")
    client
  end

  defp click(client, slot) do
    Client.send_packet(client, :play, "container_click", [
      <<0, 0, slot::signed-16, 0>>,
      Wire.varint(ItemTypes.input_id("pickup")),
      <<0, 0>>
    ])

    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    {_, client} = Client.await(client, :play, "set_cursor_item")
    client
  end

  defp close_menu(client) do
    Client.send_packet(client, :play, "container_close", <<0>>)
    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    {_, client} = Client.await(client, :play, "set_cursor_item")
    client
  end

  test "raw redundant creative patches merge on actual protocol close and repeated close is empty" do
    name = "Effective" <> Integer.to_string(System.unique_integer([:positive]))
    {_, client} = Client.login(name)
    client = Client.load_world(client)

    redundant = %{
      ItemStack.new("stone", 10)
      | components: %{
          "minecraft:max_stack_size" => 64,
          "minecraft:repair_cost" => 0,
          "minecraft:rarity" => 0,
          "minecraft:item_model" => "minecraft:stone"
        },
        removed: MapSet.new(["minecraft:custom_name"])
    }

    client = client |> seed(38, ItemStack.new("stone", 63)) |> seed(9, redundant)
    Client.send_packet(client, :play, "set_carried_item", <<2::signed-16>>)
    client = click(client, 9)
    assert client.inventory.carried == redundant
    client = close_menu(client)
    assert Enum.at(client.inventory.items, 38).count == 64
    assert Enum.at(client.inventory.items, 36).count == 9 and client.inventory.carried == nil
    assert ItemStack.same_item?(Enum.at(client.inventory.items, 36), ItemStack.new("stone", 9))
    p = Enum.find(Players.all(), &(&1.name == name))
    inventory = :sys.get_state(p.pid).inventory
    client = close_menu(client)
    assert client.inventory.items == Inventory.contents(inventory)
    assert :sys.get_state(p.pid).recovery == nil
    Client.close(client)
  end

  test "effective differences in caps, component presence and glint remain separate on protocol close" do
    for changes <- [
          %{components: %{"minecraft:max_stack_size" => 32}},
          %{removed: MapSet.new(["minecraft:repair_cost"])},
          %{components: %{"minecraft:enchantment_glint_override" => true}}
        ] do
      name = "Distinct" <> Integer.to_string(System.unique_integer([:positive]))
      {_, client} = Client.login(name)
      client = Client.load_world(client)
      stack = struct(ItemStack.new("stone", 10), changes)
      client = client |> seed(38, ItemStack.new("stone", 63)) |> seed(9, stack)
      Client.send_packet(client, :play, "set_carried_item", <<2::signed-16>>)
      client = client |> click(9) |> close_menu()
      assert Enum.at(client.inventory.items, 38) == ItemStack.new("stone", 63)
      assert Enum.at(client.inventory.items, 36) == stack and client.inventory.carried == nil
      Client.close(client)
    end
  end
end
