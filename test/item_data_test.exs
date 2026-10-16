defmodule Valimc.Protocol.ItemDataTest do
  use ExUnit.Case, async: true
  alias Valimc.PlayerDeathMessage
  alias Valimc.Protocol.{ItemData, ItemStack, NBT, Packets, ServerText, TextComponent}

  test "composed hover exceeds input budgets without widening client text admission" do
    stack = %{
      ItemStack.new("potion")
      | components: %{
          "minecraft:custom_name" => {:string, String.duplicate("N", 30_000)},
          "minecraft:custom_data" =>
            {:compound, %{"payload" => {:string, String.duplicate("D", 25_000)}}}
        }
    }

    assert IO.iodata_length(ItemStack.encode(stack)) < 65_536

    assert %ServerText{tag: tag} =
             message = PlayerDeathMessage.component("Player", {:self_magic, stack})

    assert IO.iodata_length(ServerText.encode(message)) > 65_536
    assert {_, _} = Packets.death(1, message)
    refute TextComponent.valid?(tag)
    assert catch_throw(NBT.encode(tag)) == {:nbt_error, :nbt_byte_limit}

    oversized = %ServerText{
      tag: {:compound, %{"data" => {:byte_array, :binary.copy(<<0>>, 262_144)}}}
    }

    assert catch_throw(ServerText.encode(oversized)) == {:nbt_error, :nbt_byte_limit}
    deep = Enum.reduce(1..65, {:compound, %{}}, fn _, child -> {:compound, %{"x" => child}} end)

    assert catch_throw(ServerText.encode(%ServerText{tag: deep})) ==
             {:nbt_error, :nbt_depth_limit}

    nodes = {:list, {:byte, List.duplicate(0, 8192)}}

    assert catch_throw(ServerText.encode(%ServerText{tag: nodes})) ==
             {:nbt_error, :nbt_node_limit}
  end

  test "only custom name selects an item message, including explicit removal and item-name-only negatives" do
    plain = PlayerDeathMessage.component("Player", :self_magic)
    assert PlayerDeathMessage.component("Player", {:self_magic, nil}) == plain

    for stack <- [
          ItemStack.new("potion"),
          %{ItemStack.new("potion") | components: %{"minecraft:item_name" => {:string, "Type"}}},
          %{ItemStack.new("potion") | removed: MapSet.new(["minecraft:custom_name"])}
        ] do
      assert ItemData.named_display(stack) == nil
      assert PlayerDeathMessage.component("Player", {:self_magic, stack}) == plain
    end
  end

  test "deep admitted custom data fits the added server wrappers; input depth stays bounded" do
    data = Enum.reduce(1..32, {:compound, %{}}, fn _, child -> {:compound, %{"x" => child}} end)

    stack = %{
      ItemStack.new("potion")
      | components: %{
          "minecraft:custom_name" => {:string, "Deep"},
          "minecraft:custom_data" => data
        }
    }

    assert {:ok, ^stack} =
             stack |> ItemStack.encode() |> IO.iodata_to_binary() |> ItemStack.decode()

    message = PlayerDeathMessage.component("Player", {:self_magic, stack})
    assert IO.iodata_length(ServerText.encode(message)) > 0

    assert {:error, :nbt_depth_limit} =
             message |> ServerText.encode() |> IO.iodata_to_binary() |> NBT.decode()
  end
end
