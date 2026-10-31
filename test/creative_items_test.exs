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
    player = Enum.find(Valimc.Player.PlayerList.all(), &(&1.name == username))
    assert Valimc.TestConn.state(player.pid).inventory.slots[37] == rich

    stack = %{
      ItemStack.new("stone", 17)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    {^stack, 2, client} = set_slot(client, 36, stack)
    position = {3, 64, 3}
    Valimc.TestBlocks.set(position, 0)
    use = [<<0>>, Wire.position({3, 63, 3}), <<1, 0::96, 0, 0, 11>>]
    Client.send_packet(client, :play, "use_item_on", use)
    {<<11>>, client} = Client.await(client, :play, "block_changed_ack")
    assert Valimc.TestBlocks.get(position) == Valimc.Protocol.Data.block("stone")
    {nil, 3, client} = set_slot(client, 36, nil)
    Valimc.TestBlocks.set(position, 0)
    egg = ItemStack.new("egg", 16)
    {^egg, 4, client} = set_slot(client, 36, egg)
    Client.send_packet(client, :play, "use_item_on", use)
    {<<11>>, client} = Client.await(client, :play, "block_changed_ack")
    assert Valimc.TestBlocks.get(position) == 0

    # A block item without modelled placement goes through the fenced owner
    # commit (VMC-077a): placed on air, never over an occupied block.
    pane = ItemStack.new("glass_pane", 1)
    pane_block = Valimc.Protocol.Data.item_block(ItemTypes.id("glass_pane"))
    {^pane, _, client} = set_slot(client, 36, pane)
    Client.send_packet(client, :play, "use_item_on", use)
    {<<11>>, client} = Client.await(client, :play, "block_changed_ack")
    assert Valimc.TestBlocks.get(position) == pane_block
    :ok = Valimc.TestBlocks.set(position, Valimc.Protocol.Data.block("stone"))
    Client.send_packet(client, :play, "use_item_on", use)
    {<<11>>, _} = Client.await(client, :play, "block_changed_ack")
    assert Valimc.TestBlocks.get(position) == Valimc.Protocol.Data.block("stone")
  end

  # `BlockItem.canPlace`: a placed state must survive and leave every body
  # free, the placing player's own included (VMC-077 client run, finding B).
  test "creative ladders attach as vanilla places them and never float or fill the player" do
    username = name()
    {_, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    player = Enum.find(Valimc.Player.PlayerList.all(), &(&1.name == username))

    use = fn client, position, face, sequence ->
      Client.send_packet(client, :play, "use_item_on", [
        <<0>>,
        Wire.position(position),
        <<face, 0::96, 0, 0, sequence>>
      ])

      {<<^sequence>>, client} = Client.await(client, :play, "block_changed_ack")
      client
    end

    ladder = fn facing -> Valimc.Data.Blocks.state("ladder", %{"facing" => facing}) end
    stone = Valimc.Protocol.Data.block("stone")

    for position <- [{3, 65, 2}, {5, 65, 2}], do: :ok = Valimc.TestBlocks.set(position, stone)

    for position <- [{3, 65, 3}, {3, 65, 4}, {5, 65, 3}],
        do: :ok = Valimc.TestBlocks.set(position, 0)

    :ok = Valimc.TestBlocks.set({3, 65, 3}, ladder.("south"))
    {_, _, client} = set_slot(client, 36, ItemStack.new("ladder", 16))

    # Used on a ladder's free front: refused, as `LadderBlock` refuses it.
    client = use.(client, {3, 65, 3}, 3, 21)
    assert Valimc.TestBlocks.get({3, 65, 4}) == 0

    # Used on a wall's south face: a ladder facing south against it.
    client = use.(client, {5, 65, 2}, 3, 22)
    assert Valimc.TestBlocks.get({5, 65, 3}) == ladder.("south")

    # Nothing behind the cell above the floor: refused, not left floating.
    :ok = Valimc.TestBlocks.set({7, 64, 3}, 0)
    client = use.(client, {7, 63, 3}, 1, 23)
    assert Valimc.TestBlocks.get({7, 64, 3}) == 0

    # A pane's post would stand in the placing player's own cell: refused.
    %{x: x, z: z} = Valimc.TestConn.state(player.pid).player
    feet = {floor(x), 64, floor(z)}
    {_, _, client} = set_slot(client, 36, ItemStack.new("glass_pane", 1))
    _client = use.(client, {floor(x), 63, floor(z)}, 1, 24)
    assert Valimc.TestBlocks.get(feet) == 0
  end
end
