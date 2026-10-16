defmodule Valimc.FlatClimateTest do
  use ExUnit.Case, async: true
  alias Valimc.World.FlatClimate

  test "flat plains rain near terrain changes to snow at high altitude" do
    for x <- [-29_999_999, -1, 0, 29_999_999], z <- [-29_999_999, 0, 29_999_999] do
      assert FlatClimate.precipitation({x, -64, z}) == {:ok, :rain}
      assert FlatClimate.precipitation({x, 320, z}) == {:ok, :rain}
      assert FlatClimate.precipitation({x, 1024, z}) == {:ok, :snow}
    end
  end

  test "climate observations require bounded block coordinates" do
    for point <- [{30_000_000, 64, 0}, {0, 1_000_001, 0}, {0, 64, -30_000_000}, {0.5, 64, 0}, nil] do
      assert FlatClimate.precipitation(point) == {:error, :invalid_climate_position}
    end
  end
end
