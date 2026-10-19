defmodule Valimc.FlatClimateTest do
  use ExUnit.Case, async: true
  alias Valimc.World.FlatClimate

  test "climate observations require bounded block coordinates" do
    for point <- [{30_000_000, 64, 0}, {0, 1_000_001, 0}, {0, 64, -30_000_000}, {0.5, 64, 0}, nil] do
      assert FlatClimate.precipitation(point) == {:error, :invalid_climate_position}
    end
  end
end
