defmodule Valimc.SpawnSearchTest do
  use ExUnit.Case, async: true
  alias Valimc.Data.Blocks
  alias Valimc.World.{Border, PlayerSpawn}
  alias Valimc.Worldgen.SpawnSearch

  # A column from the world's bottom: `layers` as `{block, count}` runs, then air.
  defp column(layers) do
    states = Enum.flat_map(layers, fn {name, count} -> List.duplicate(state(name), count) end)
    List.to_tuple(states ++ List.duplicate(state("air"), 384 - length(states)))
  end

  defp state(name), do: Blocks.default_state(name)

  test "a safe column stands on the top full face; liquids and open water are not safe" do
    # Bedrock and stone up to y = 63, grass at 64: spawn at 65.
    assert SpawnSearch.respawn_y(column([{"bedrock", 1}, {"stone", 127}, {"grass_block", 1}])) ==
             65

    # Water over the ocean floor.
    refute SpawnSearch.respawn_y(column([{"stone", 120}, {"water", 8}]))
    # Leaves count: a tree top is a spawn.
    assert SpawnSearch.respawn_y(column([{"stone", 128}, {"oak_log", 4}, {"oak_leaves", 1}])) ==
             69

    # A carpet (no full top face) on stone: the stone below.
    assert SpawnSearch.respawn_y(column([{"stone", 128}, {"white_carpet", 1}])) == 64
    # Nothing at all.
    refute SpawnSearch.respawn_y(column([]))
  end

  test "a standing player needs two free blocks without fluid and no tall shape below" do
    open = column([{"stone", 128}])
    assert PlayerSpawn.clear?(open, 0, 64, 0)
    refute PlayerSpawn.clear?(open, 0, 63, 0)
    refute PlayerSpawn.clear?(column([{"stone", 128}, {"air", 1}, {"stone", 1}]), 0, 64, 0)
    refute PlayerSpawn.clear?(column([{"stone", 128}, {"water", 1}]), 0, 64, 0)
    refute PlayerSpawn.clear?(column([{"stone", 127}, {"oak_fence", 1}]), 0, 64, 0)
    assert PlayerSpawn.clear?(column([{"stone", 127}, {"water", 1}]), 0, 64, 0)
  end

  test "the spawn radius shrinks near the border and is at least 1 next to it" do
    assert PlayerSpawn.radius(Border.new(), 0, 0) == 0

    border = Border.set_size(Border.new(), 16.0)
    # The rule is 0 in tests; the border distance still forces 1 at the edge.
    assert PlayerSpawn.radius(border, 7, 0) == 1
    assert PlayerSpawn.radius(border, 0, 0) == 0
  end
end
