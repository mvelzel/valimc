defmodule Valimc.Physics.FluidFlowTest do
  use ExUnit.Case, async: true

  alias Valimc.Physics.{
    BlockCollisions.Frame,
    BlockEntityContext,
    BlockScan,
    FluidBoundaries,
    FluidCurrents,
    FluidFlow
  }

  alias Valimc.Protocol.{Data, ItemTypes}
  @box {0.2, 64.7, 0.2, 0.8, 66.5, 0.8}

  test "contextual support and missing cells fail explicitly" do
    shulker = Data.item_block(ItemTypes.id("shulker_box"))
    f = frame(%{{0, 64, 0} => shulker})
    assert {:ok, true} == FluidBoundaries.sturdy?(f, {0, 64, 0}, 0)

    assert {:error, :incomplete_fluid_block_entity} ==
             FluidBoundaries.sturdy?(%{f | entities: %{}}, {0, 64, 0}, 0)

    assert {:error, :unresolved_fluid_support} ==
             FluidBoundaries.sturdy?(
               %{f | entities: %{{0, 64, 0} => BlockEntityContext.shulker(0.0, 0.5)}},
               {0, 64, 0},
               0
             )

    assert {:error, :incomplete_fluid_frame} == FluidFlow.sample(%{f | states: %{}}, {0, 64, 0})

    assert {:error, :unknown_block_state} ==
             FluidFlow.sample(frame(%{{0, 64, 0} => 35_723}), {0, 64, 0})

    assert {:error, :invalid_fluid_position} == FluidFlow.sample(f, {0.0, 64, 0})
    assert {:error, :invalid_fluid_current} == FluidCurrents.sample(f, @box, {65, 0, 0})
  end

  defp frame(edits) do
    {:ok, plan} = BlockScan.plan(@box)
    states = Map.merge(Map.new(plan, fn {p, _} -> {p, 0} end), edits)

    %Frame{
      states: states,
      entities: Map.new(states, fn {p, _} -> {p, BlockEntityContext.absent()} end),
      fences: %{}
    }
  end
end
