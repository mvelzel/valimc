defmodule Valimc.ToolDurabilityTest do
  use ExUnit.Case, async: true
  alias Valimc.ToolDurability
  alias Valimc.Protocol.{Data, ItemStack}

  test "zero-hardness callbacks and removed or immune components retain native wear gates" do
    stone = Data.block("stone")
    grass = Data.item_block(Data.item("short_grass"))
    pick = ItemStack.new("iron_pickaxe")
    shears = ItemStack.new("shears")
    assert {^pick, nil} = ToolDurability.mine(pick, grass, false)

    assert {%{components: %{"minecraft:damage" => 1}}, nil} =
             ToolDurability.mine(shears, grass, false)

    assert {%{components: %{"minecraft:damage" => 1}}, nil} =
             ToolDurability.mine(pick, stone, false)

    no_tool = %{pick | removed: MapSet.new(["minecraft:tool"])}
    assert {^no_tool, nil} = ToolDurability.mine(no_tool, stone, false)
    no_damage = %{pick | removed: MapSet.new(["minecraft:damage"])}
    assert {^no_damage, nil} = ToolDurability.mine(no_damage, stone, false)
    immune = %{pick | components: %{"minecraft:unbreakable" => :unit}}
    assert {^immune, nil} = ToolDurability.mine(immune, stone, false, fn -> flunk("RNG") end)
  end

  test "Unbreaking samples each cost point once and final wear retains the break payload" do
    sword = %{
      ItemStack.new("diamond_sword")
      | components: %{
          "minecraft:enchantments" => %{"minecraft:unbreaking" => 1},
          "minecraft:damage" => 1560
        }
    }

    stone = Data.block("stone")
    assert {^sword, nil} = ToolDurability.mine(sword, stone, false, fn -> 0.4999999701976776 end)

    assert {nil, %{components: %{"minecraft:damage" => 1561}}} =
             ToolDurability.mine(sword, stone, false, fn -> 0.5 end)

    assert {^sword, nil} = ToolDurability.mine(sword, stone, true, fn -> flunk("Immune RNG") end)

    stored = %{
      sword
      | components: %{"minecraft:stored_enchantments" => %{"minecraft:unbreaking" => 255}}
    }

    assert {%{components: %{"minecraft:damage" => 2}}, nil} =
             ToolDurability.mine(stored, stone, false, fn -> flunk("Stored RNG") end)

    huge = %{
      ItemStack.new("diamond_sword")
      | components: %{
          "minecraft:max_damage" => 2_147_483_647,
          "minecraft:damage" => 2_147_483_646
        }
    }

    assert {%{components: %{"minecraft:damage" => 0}}, nil} =
             ToolDurability.mine(huge, stone, false)
  end
end
