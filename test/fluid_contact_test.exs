defmodule Valimc.Physics.FluidContactTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockCollisions.Frame, BlockScan, FluidContact}
  @box {0.2, 64.0, 0.2, 0.8, 65.8, 0.8}

  test "same fluid above fills the surface, other fluid does not" do
    {:ok, water} = FluidContact.sample(frame(%{{0, 64, 0} => 89}), @box)
    assert water.water == 0.8888888955116272 and water.lava == 0.0

    assert {:ok, %{water: 1.8888888955116272, lava: 0.0}} ==
             FluidContact.sample(frame(%{{0, 64, 0} => 89, {0, 65, 0} => 89}), @box)

    assert {:ok, %{water: 0.8888888955116272, lava: 1.8888888955116272}} ==
             FluidContact.sample(frame(%{{0, 64, 0} => 89, {0, 65, 0} => 105}), @box)
  end

  test "contact excludes a millimetre at the body edge and uses original feet for depth" do
    surface = 64.0 + 0.8888888955116272
    box = {0.2, surface - 0.0005, 0.2, 0.8, surface + 1.8, 0.8}
    assert {:ok, %{water: 0.0, lava: 0.0}} == FluidContact.sample(frame(%{{0, 64, 0} => 89}), box)

    box = {0.2, surface - 0.001, 0.2, 0.8, surface + 1.8, 0.8}
    {:ok, result} = FluidContact.sample(frame(%{{0, 64, 0} => 89}), box)
    assert_in_delta result.water, 0.001, 1.0e-13

    box = {1.0 - 0.0005, 64.0, 0.2, 1.6, 65.8, 0.8}

    assert {:ok, %{water: 0.0, lava: 0.0}} ==
             FluidContact.sample(frame(%{{0, 64, 0} => 89}, box), box)
  end

  test "waterlogged states contribute independently of collision shape" do
    assert {:ok, %{water: 0.8888888955116272, lava: 0.0}} ==
             FluidContact.sample(frame(%{{0, 64, 0} => 15179}), @box)

    assert {:ok, %{water: 0.0, lava: 0.0}} ==
             FluidContact.sample(frame(%{{0, 64, 0} => 15180}), @box)
  end

  test "escape rejects even shallow liquid cells above their actual surface" do
    box = {0.2, 64.8, 0.2, 0.8, 66.6, 0.8}
    f = frame(%{{0, 64, 0} => 96}, box)
    assert {:ok, %{water: 0.0, lava: 0.0}} == FluidContact.sample(f, box)
    assert {:ok, true} == FluidContact.any_liquid?(f, box)
  end

  test "missing body or above observation cannot silently become dry" do
    f = frame(%{{0, 64, 0} => 89})

    assert {:error, :incomplete_fluid_frame} ==
             FluidContact.sample(%{f | states: Map.delete(f.states, {0, 65, 0})}, @box)

    assert {:error, :incomplete_fluid_frame} ==
             FluidContact.sample(%{f | states: Map.delete(f.states, {0, 64, 0})}, @box)

    assert {:error, :unknown_block_state} ==
             FluidContact.sample(frame(%{{0, 64, 0} => 35_723}), @box)
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
