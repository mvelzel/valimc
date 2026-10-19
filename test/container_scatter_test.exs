defmodule Valimc.Physics.ContainerScatterTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.ContainerScatter
  @zeros {0, {0.0, 0.0, 0.0, 0.0, 0.0, 0.0}}

  test "missing, extra or invalid draws and counts cannot make a partial spill" do
    for {count, offset, piles} <- [
          {1, {0, 0, 0}, []},
          {0, {0, 0, 0}, [@zeros]},
          {100, {0, 0, 0}, [@zeros]},
          {-1, {0, 0, 0}, []},
          {1, {1.0, 0, 0}, [@zeros]},
          {1, {0, 0, 0}, [{21, {0, 0, 0, 0, 0, 0}}]},
          {1, {0, 0, 0}, [{0, {0, 0, 0, 0, 0, -0.1}}]}
        ] do
      assert {:error, :invalid_container_scatter} =
               ContainerScatter.plan({0, 64, 0}, count, offset, piles)
    end
  end
end
