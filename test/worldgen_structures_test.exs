defmodule Valimc.WorldgenStructuresTest do
  @moduledoc """
  Structure placement and starts (VMC-025e) against values vanilla's own
  classes give for seed 20261020 (`StructureOracle starts`); the full parity
  check is the `worldgen_structures` stage.
  """
  use ExUnit.Case, async: true
  alias Valimc.Native

  @seed 20_261_020
  @source "minecraft:overworld"

  setup_all do
    {:ok, state} = Valimc.Worldgen.new(@seed)
    %{state: state}
  end

  test "stronghold rings are where vanilla puts them", %{state: state} do
    {:ok, {possible, rings}} = Native.worldgen_structure_state(state, @source)
    assert "minecraft:villages" in possible
    refute "minecraft:nether_complexes" in possible
    {"minecraft:strongholds", positions} = List.keyfind(rings, "minecraft:strongholds", 0)
    assert length(positions) == 128
    assert Enum.take(positions, 5) == [{-119, -64}, {75, -47}, {6, 111}, {256, 108}, {33, 311}]
  end

  test "temples and buried treasure start as vanilla's", %{state: state} do
    {:ok, {starts, _skipped}} =
      Native.worldgen_structure_starts(state, @source, [{7712, -1152}, {-873, -15820}, {0, 0}])

    assert [
             {7712, -1152, "minecraft:jungle_pyramid", jungle},
             {-873, -15820, "minecraft:buried_treasure", treasure}
           ] = starts

    assert jungle =~ "BB:[I;123392,64,-18432,123403,73,-18418]"
    assert jungle =~ "O:2"

    assert treasure ==
             ~s({Children:[{BB:[I;-13959,90,-253111,-13959,90,-253111],GD:0,O:-1,id:"minecraft:btp"}],) <>
               ~s(ChunkX:-873,ChunkZ:-15820,id:"minecraft:buried_treasure",references:0})
  end

  test "villages and igloos start as vanilla's", %{state: state} do
    {:ok, {starts, _skipped}} =
      Native.worldgen_structure_starts(state, @source, [{14725, -12407}, {5450, 26826}])

    assert [
             {14725, -12407, "minecraft:village_plains", village},
             {5450, 26826, "minecraft:igloo", igloo}
           ] =
             starts

    assert length(String.split(village, ~s(id:"minecraft:jigsaw"))) == 118

    assert village =~
             ~s({Children:[{BB:[I;235586,63,-198512,235600,67,-198505],GD:0,O:-1,PosX:235600,PosY:63,PosZ:-198512,)

    assert igloo =~
             ~s({Children:[{BB:[I;87202,63,429218,87210,68,429224],GD:0,O:2,Rot:"CLOCKWISE_90",TPX:87200,TPY:63,TPZ:429214,)
  end

  test "strongholds, mansions and monuments start as vanilla's", %{state: state} do
    {:ok, {starts, _skipped}} =
      Native.worldgen_structure_starts(state, @source, [
        {-119, -64},
        {-24454, -14613},
        {28685, -19096}
      ])

    assert [
             {-119, -64, "minecraft:stronghold", stronghold},
             {-24454, -14613, "minecraft:mansion", mansion},
             {28685, -19096, "minecraft:monument", monument}
           ] = starts

    assert length(String.split(stronghold, ~s(id:"minecraft:sh))) == 217

    assert stronghold =~
             ~s({Children:[{BB:[I;-1902,14,-1022,-1898,24,-1018],EntryDoor:"OPENING",GD:0,O:2,Source:1b,)

    assert length(String.split(mansion, ~s(id:"minecraft:wmp"))) == 595

    assert mansion =~
             ~s(Rot:"COUNTERCLOCKWISE_90",TPX:-391257,TPY:67,TPZ:-233792,Template:"entrance")

    assert monument =~
             ~s({Children:[{BB:[I;458931,39,-305565,458988,61,-305508],GD:0,O:1,id:"minecraft:omb"}])
  end

  test "nether fortresses start as vanilla's" do
    {:ok, nether} = Valimc.Worldgen.new(@seed, "minecraft:nether")

    {:ok, {[{-16457, 29276, "minecraft:fortress", fortress}], _}} =
      Native.worldgen_structure_starts(nether, "minecraft:nether", [{-16457, 29276}])

    assert length(String.split(fortress, ~s(id:"minecraft:ne))) == 139

    assert fortress =~
             ~s({Children:[{BB:[I;-263310,62,468418,-263292,71,468436],GD:0,O:0,id:"minecraft:nebcr"})
  end

  test "placement chunks follow the sets' grids", %{state: state} do
    {:ok, {placements, _references}} =
      Native.worldgen_structure_window(state, @source, {-5, -15}, 17)

    placed = Map.new(placements)
    assert placed["minecraft:pillager_outposts"] == [{0, -10}]
    assert placed["minecraft:mineshafts"] == [{8, -8}]
    assert placed["minecraft:buried_treasures"] == [{9, -9}]
    assert placed["minecraft:jungle_temples"] == [{8, -13}]
    assert placed["minecraft:villages"] == []
  end

  # VMC-025f1: placement into chunks; the full check is the
  # `worldgen_structure_placement` stage (StructurePlacementOracle, which also
  # gives these entities).
  test "a swamp hut is placed with its witch and cat" do
    {:ok, state} = Valimc.Worldgen.new(-8_172_645_723)
    order = for dz <- -1..1, dx <- -1..1, do: {19117 + dx, -29081 + dz}

    {:ok, {chunks, [hut]}} =
      Native.worldgen_decorate_structures(state, @source, {19117, -29081}, order, [
        "minecraft:swamp_hut"
      ])

    assert Enum.flat_map(chunks, & &1.entities) == [
             "minecraft:witch,305874.5,68.0,-465290.5,0.0",
             "minecraft:cat,305874.5,68.0,-465290.5,0.0"
           ]

    assert hut =~ "Witch:1b"
    assert hut =~ "Cat:1b"
    refute hut =~ "HPos:-1"
  end
end
