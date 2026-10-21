defmodule Valimc.Physics.FluidContactTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockCollisions.Frame, BlockScan, FluidContact}
  @box {0.2, 64.0, 0.2, 0.8, 65.8, 0.8}

  test "missing body or above observation cannot silently become dry" do
    f = frame(%{{0, 64, 0} => 89})

    assert {:error, :incomplete_fluid_frame} ==
             FluidContact.sample(%{f | states: Map.delete(f.states, {0, 65, 0})}, @box)

    assert {:error, :incomplete_fluid_frame} ==
             FluidContact.sample(%{f | states: Map.delete(f.states, {0, 64, 0})}, @box)
  end

  test "invalid or excessive body scans fail before enumerating or consulting a frame" do
    assert {:error, :fluid_scan_limit} == FluidContact.positions({0, 0, 0, 1000, 1000, 1000})
    assert {:error, :invalid_fluid_box} == FluidContact.positions({0, 0, 0, 0.001, 2, 1})
    assert {:error, :invalid_fluid_box} == FluidContact.positions({1, 0, 0, 0, 2, 1})
    assert {:error, :invalid_fluid_box} == FluidContact.positions(nil)
    assert {:error, :invalid_fluid_frame} == FluidContact.sample(%{}, @box)
  end

  defp frame(edits, box \\ @box) do
    {:ok, plan} = BlockScan.plan(box)

    %Frame{
      states: Map.merge(Map.new(plan, fn {p, _} -> {p, 0} end), edits),
      fences: %{},
      entities: %{}
    }
  end
end
