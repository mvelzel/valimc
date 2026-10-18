defmodule Valimc.Physics.ContainerScatterTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.ContainerScatter
  @zeros {0, {0.0, 0.0, 0.0, 0.0, 0.0, 0.0}}

  test "worst-case stack splits are bounded and share the native negative-floor origin" do
    assert {:ok, records} =
             ContainerScatter.plan(
               {-1.2, -64, -15.8},
               99,
               {0.0, 0.0, 0.0},
               List.duplicate(@zeros, 10)
             )

    assert length(records) == 10 and Enum.map(records, & &1.count) == List.duplicate(10, 9) ++ [9]

    assert Enum.all?(
             records,
             &(&1.position == {-1.875, -64.0, -15.875} and
                 &1.velocity == {0.0, 0.2, 0.0} and &1.pickup_delay == 0)
           )

    assert {:ok, []} = ContainerScatter.plan({0, 64, 0}, 0, {0, 0, 0}, [])
  end

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
