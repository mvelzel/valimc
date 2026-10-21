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

  # VMC-025f1: placement into chunks; the full check is the
  # `worldgen_structure_placement` stage (StructurePlacementOracle, which also
  # gives these entities).
end
