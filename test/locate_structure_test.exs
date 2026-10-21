defmodule Valimc.LocateStructureTest do
  @moduledoc """
  `/locate structure`'s search (VMC-053o) against what vanilla's
  `findNearestMapStructure` finds for seed 20261020 from the origin
  (`LocateOracle`); the full check is the `locate` stage.
  """
  use ExUnit.Case, async: true
  alias Valimc.Native

  setup_all do
    {:ok, state} = Valimc.Worldgen.new(20_261_020)
    %{state: state}
  end

  defp locate(state, structures),
    do:
      Native.worldgen_structure_locate(state, "minecraft:overworld", structures, {0, 64, 0}, 100)

  test "random spread and ring structures", %{state: state} do
    assert locate(state, ["minecraft:village_plains"]) ==
             {:ok, {-496, 0, -336, "minecraft:village_plains"}}

    assert locate(state, ["minecraft:mansion"]) == {:ok, {-1952, 0, -864, "minecraft:mansion"}}

    assert locate(state, ["minecraft:stronghold"]) ==
             {:ok, {1200, 0, -752, "minecraft:stronghold"}}
  end

  test "a tag finds its nearest member; other dimensions' structures are not found",
       %{state: state} do
    village =
      ~w(minecraft:village_plains minecraft:village_desert minecraft:village_savanna minecraft:village_snowy minecraft:village_taiga)

    assert locate(state, village) == {:ok, {272, 0, 224, "minecraft:village_savanna"}}
    assert locate(state, ["minecraft:fortress"]) == {:ok, nil}
  end
end
