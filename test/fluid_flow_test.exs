defmodule Valimc.Physics.FluidFlowTest do
  use ExUnit.Case, async: true
  alias Valimc.World.View
  alias Valimc.Physics.Kernel

  test "missing cells fail explicitly rather than reading as air" do
    assert {:error, {:missing_block, _}} = Kernel.flow(View.of(%{}), {0, 64, 0})

    assert {:error, {:missing_block, _}} =
             Kernel.current(View.of(%{}), {0.2, 64.7, 0.2, 0.8, 66.5, 0.8}, {0.0, 0.0, 0.0})
  end
end
