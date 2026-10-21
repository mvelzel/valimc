defmodule Valimc.Physics.FluidFlowTest do
  use ExUnit.Case, async: true
  alias Valimc.World.View
  alias Valimc.Physics.{BlockScan, FluidCurrents, Kernel}
  @box {0.2, 64.7, 0.2, 0.8, 66.5, 0.8}

  test "missing cells and invalid queries fail explicitly" do
    {:ok, plan} = BlockScan.plan(@box)
    f = View.of(Map.new(plan, fn {p, _} -> {p, 0} end))
    assert {:error, {:missing_block, _}} = Kernel.flow(View.of(%{}), {0, 64, 0})
    assert {:error, :invalid_fluid_current} == FluidCurrents.sample(f, @box, {65, 0, 0})
  end
end
