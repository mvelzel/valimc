defmodule Valimc.MiningToolsTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{Mining, MiningTools}
  alias Valimc.Protocol.{Data, ItemStack}

  test "wrong harvest tier keeps fast tool speed while independently denying drops" do
    obsidian = Data.item_block(Data.item("obsidian"))
    iron = ItemStack.new("iron_pickaxe")
    diamond = ItemStack.new("diamond_pickaxe")
    assert Mining.requires_tool?(obsidian)
    assert MiningTools.speed(iron, obsidian) == 6.0
    refute MiningTools.correct_tool?(iron, obsidian)
    assert MiningTools.speed(diamond, obsidian) == 8.0
    assert MiningTools.correct_tool?(diamond, obsidian)
    refute MiningTools.correct_tool?(nil, Data.block("dirt"))
    refute Mining.requires_tool?(Data.block("dirt"))
  end

  test "sword and removed-tool behavior include native instant bamboo and creative permission" do
    sword = ItemStack.new("diamond_sword")
    assert MiningTools.speed(sword, Data.item_block(Data.item("cobweb"))) == 15.0
    assert MiningTools.correct_tool?(sword, Data.item_block(Data.item("cobweb")))
    assert MiningTools.speed(sword, Data.item_block(Data.item("bamboo"))) == 3.4028234663852886e38
    assert MiningTools.can_destroy?(sword, false)
    refute MiningTools.can_destroy?(sword, true)
    assert MiningTools.damage_per_block(sword) == 2
    removed = %{sword | removed: MapSet.new(["minecraft:tool"])}
    assert MiningTools.speed(removed, Data.item_block(Data.item("cobweb"))) == 1.0
    refute MiningTools.correct_tool?(removed, Data.item_block(Data.item("cobweb")))
    assert MiningTools.can_destroy?(removed, true)
    assert MiningTools.damage_per_block(removed) == 0
    refute MiningTools.can_destroy?(ItemStack.new("debug_stick"), false)
    refute MiningTools.can_destroy?(ItemStack.new("debug_stick"), true)
  end
end
