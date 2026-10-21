defmodule Valimc.PhysicsBoundsTest do
  # Work and coordinate bounds of the collision kernels that client movement drives.
  # Their vanilla behaviour is compared by the physics oracle stages.
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockScan, Box, Kernel, PlayerPose, SneakEdges}
  alias Valimc.Living.FallDamage
  @sneak_box {-0.3, 64.0, -0.3, 0.3, 65.8, 0.3}

  defp body(point) do
    {:ok, %{box: {a, b, c, d, e, f}}} = PlayerPose.geometry(:standing, point)
    epsilon = 9.999999747378752e-6
    Box.new({a + epsilon, b + epsilon, c + epsilon, d - epsilon, e - epsilon, f - epsilon})
  end

  test "body sweeps and player queries fail before unbounded work" do
    p = {0.5, 64.0, 0.5}
    assert {:error, :body_sweep_limit} = Kernel.sweep(p, {65.5, 64.0, 0.5}, body(p))
    assert {:error, :body_sweep_limit} = Kernel.sweep(p, p, Box.new({0, 0, 0, 16, 16, 16}))
    assert Kernel.bounded?({0.2, 0.2, 0.2, 5.8, 5.8, 5.8})
    refute Kernel.bounded?({0.2, 0.2, 0.2, 9.8, 9.8, 9.8})
    refute Kernel.bounded?({0.0, 0.0, 0.0, 60_000_001.0, 1.0, 1.0})
    refute Kernel.bounded?({1.0, 0.0, 0.0, -1.0, 1.0, 1.0})
  end

  test "fall damage saturates at the largest int instead of overflowing" do
    assert {:ok, 2_147_483_647} =
             FallDamage.calculate(60_000_000.0, 4.0, %FallDamage{attribute_multiplier: 100.0})

    assert {:error, :invalid_fall_damage} = FallDamage.calculate(-1.0, 1.0, %FallDamage{})
  end

  test "block scans bound raw volume before candidate allocation, including corners" do
    assert {:ok, positions} = BlockScan.plan({0.2, 0.2, 0.2, 5.8, 5.8, 5.8})
    assert length(positions) == 504
    assert {:error, :block_scan_limit} = BlockScan.plan({0.2, 0.2, 0.2, 6.8, 5.8, 5.8})
    assert {:error, :block_scan_limit} = BlockScan.plan({-60_000_000, 0, 0, 60_000_000, 1, 1})

    for box <- [nil, {1, 0, 0, -1, 1, 1}, {0, 0, 0, 60_000_001, 1, 1}, {0, 0, 0, :bad, 1, 1}],
        do: assert(BlockScan.plan(box) == {:error, :invalid_box})
  end

  test "sneak edges: exclusions perform no reads; a missing supporting frame is never empty space" do
    missing = fn _ -> {:error, :incomplete_frame} end

    for facts <- [
          %SneakEdges{},
          %SneakEdges{shift: true, flying: true},
          %SneakEdges{shift: true, mover: :piston}
        ] do
      assert {:ok, %{queries: 0, requested: {0.4, -0.1, 0.2}}} =
               SneakEdges.step(@sneak_box, {0.4, -0.1, 0.2}, facts, missing)
    end

    assert {:ok, %{queries: 0}} =
             SneakEdges.step(@sneak_box, {0.4, 0.001, 0.2}, %SneakEdges{shift: true}, missing)

    assert {:error, :incomplete_frame} =
             SneakEdges.step(@sneak_box, {0.4, 0.0, 0.2}, %SneakEdges{shift: true}, missing)

    assert {:error, :invalid_sneak_edges} =
             SneakEdges.step(@sneak_box, {65.0, 0.0, 0.0}, %SneakEdges{}, missing)
  end
end
