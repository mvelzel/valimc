defmodule Valimc.PhysicsBoundsTest do
  # Work and coordinate bounds of the collision kernels that client movement drives.
  # Their vanilla behaviour is compared by the physics oracle stages.
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockOffset, BlockScan, BlockShapes, BodySweep, Box, Collision}
  alias Valimc.Physics.{FallDamage, FluidControls, MovementValidation, PlayerPose, Shape}
  alias Valimc.Physics.{SneakEdges, StepMovement, VoxelOps}
  @box {-0.3, 0.0, -0.3, 0.3, 1.8, 0.3}
  @sneak_box {-0.3, 64.0, -0.3, 0.3, 65.8, 0.3}

  defp stone do
    {:ok, shape} = BlockShapes.fetch(1)
    shape
  end

  defp slab, do: VoxelOps.box({1, 0, -1, 2, 0.5, 1})

  defp body(point) do
    {:ok, %{box: {a, b, c, d, e, f}}} = PlayerPose.geometry(:standing, point)
    epsilon = 9.999999747378752e-6
    Box.new({a + epsilon, b + epsilon, c + epsilon, d - epsilon, e - epsilon, f - epsilon})
  end

  test "collision work is bounded even for empty or zero movement queries" do
    for {box, shapes, request} <- [
          {@box, List.duplicate(%Shape{}, 129), {0, 0, 0}},
          {@box, [], {65, 0, 0}},
          {@box, [], {:invalid, 0, 0}},
          {@box, [], {0, 0}},
          {{1, 0, 0, -1, 1, 1}, [], {0, 0, 0}},
          {{0, 0, 0, 60_000_001, 1, 1}, [], {0, 0, 0}}
        ],
        do: assert_raise(ArgumentError, fn -> Collision.move(box, shapes, request) end)

    assert Collision.move(@box, List.duplicate(%Shape{}, 128), {1, 0, 0}) == {1.0, 0.0, 0.0}
  end

  test "body sweeps fail before an unbounded traversal" do
    p = {0.5, 64.0, 0.5}
    assert {:error, :body_sweep_limit} = BodySweep.plan(p, {65.5, 64.0, 0.5}, body(p))
    assert {:error, :body_sweep_limit} = BodySweep.plan(p, p, Box.new({0, 0, 0, 16, 16, 16}))
    assert {:error, :invalid_body_sweep} = BodySweep.plan(p, p, body(p), 513)
    assert {:error, :invalid_body_sweep} = BodySweep.plan(:bad, p, body(p))
    from = {0.0, 64.0, 0.0}
    to = {1.0, 64.0, -1.0e-320}
    assert {:error, :body_sweep_limit} = BodySweep.plan(from, to, body(to))
    edge = {-60_000_000.0, 64.0, 0.0, -59_999_999.0, 65.0, 1.0}
    assert {:error, :body_sweep_limit} = BodySweep.plan(from, {1.0, 64.0, 0.0}, edge)
  end

  test "movement validation keeps existing overlap, rejects new overlap and bounds its facts" do
    old = {-0.3, 0.0, -0.3, 0.3, 1.8, 0.3}
    existing = VoxelOps.world_box({0.1, 0, -0.2, 0.2, 1, 0.2})
    new = VoxelOps.world_box({0.75, 0, -0.2, 1.0, 2, 0.2})
    assert MovementValidation.new_collision?(old, [existing]) == {:ok, false}
    assert MovementValidation.new_collision?(old, [existing, new]) == {:ok, true}

    for {box, shapes} <- [{old, List.duplicate(new, 129)}, {old, [:unknown]}, {nil, []}] do
      assert MovementValidation.new_collision?(box, shapes) ==
               {:error, :invalid_movement_observation}
    end
  end

  test "malformed or oversized voxel grids reject before merged cell iteration" do
    shape = VoxelOps.box({0, 0, 0, 1, 1, 1})

    for bad <- [
          nil,
          %{shape | sizes: {33, 1, 1}},
          %{shape | bits: <<>>},
          %{shape | axes: {{0.0, 60_000_001.0}, {0.0, 1.0}, {0.0, 1.0}}},
          %{shape | boxes: List.duplicate({0, 0, 0, 1, 1, 1}, 65)}
        ] do
      assert_raise ArgumentError, fn -> VoxelOps.intersects?(bad, shape) end
    end

    assert_raise ArgumentError, fn -> VoxelOps.world_box({0, 0, 0, 60_000_001, 1, 1}) end
  end

  test "fall damage saturates at the largest int instead of overflowing" do
    assert {:ok, 2_147_483_647} =
             FallDamage.calculate(60_000_000.0, 4.0, %FallDamage{attribute_multiplier: 100.0})

    assert {:error, :invalid_fall_damage} = FallDamage.calculate(-1.0, 1.0, %FallDamage{})
  end

  test "block offsets reject invalid coordinates even for cached or unknown states" do
    for position <- [
          nil,
          {0, 0},
          {0.0, 64, 0},
          {0, "64", 0},
          {30_000_001, 64, 0},
          {0, -1_000_001, 0},
          {0, 64, -30_000_001}
        ],
        id <- [0, 18636, 35_723] do
      refute BlockOffset.valid_position?(position)
      assert BlockShapes.fetch(id, position) == {:error, :invalid_position}
    end

    for limit <- [-0.1, 0.251, "0.25", nil],
        do: assert_raise(ArgumentError, fn -> BlockOffset.horizontal({0, 64, 0}, limit) end)
  end

  test "block scans bound raw volume before candidate allocation, including corners" do
    assert {:ok, positions} = BlockScan.plan({0.2, 0.2, 0.2, 5.8, 5.8, 5.8})
    assert length(positions) == 504
    assert {:error, :block_scan_limit} = BlockScan.plan({0.2, 0.2, 0.2, 6.8, 5.8, 5.8})
    assert {:error, :block_scan_limit} = BlockScan.plan({-60_000_000, 0, 0, 60_000_000, 1, 1})

    for box <- [nil, {1, 0, 0, -1, 1, 1}, {0, 0, 0, 60_000_001, 1, 1}, {0, 0, 0, :bad, 1, 1}],
        do: assert(BlockScan.plan(box) == {:error, :invalid_box})
  end

  test "combined simulation frames have a distinct bounded block-scan envelope" do
    box = {0.2, 0.2, 0.2, 6.8, 5.8, 5.8}
    assert {:error, :block_scan_limit} == BlockScan.plan(box)
    assert {:ok, positions} = BlockScan.plan(box, 1024)
    assert length(positions) < 1024
    assert {:error, :block_scan_limit} == BlockScan.plan({0.2, 0.2, 0.2, 10.8, 10.8, 10.8}, 1024)
    assert {:error, :block_scan_limit} == BlockScan.plan(box, 2048)
  end

  test "invalid shape facts and unbounded clip jobs reject before geometry is used" do
    good = %{
      "axes" => [[0.0, 1.0], [0.0, 1.0], [0.0, 1.0]],
      "sizes" => [1, 1, 1],
      "bits" => "01",
      "boxes" => [[0.0, 0.0, 0.0, 1.0, 1.0, 1.0]],
      "full_block" => true
    }

    assert Shape.from_facts!(good) == stone()

    for bad <- [
          Map.put(good, "sizes", [33, 1, 1]),
          Map.put(good, "bits", "ff"),
          Map.put(good, "bits", ""),
          Map.put(good, "bits", "00"),
          Map.put(good, "axes", [[1.0, 0.0], [0.0, 1.0], [0.0, 1.0]]),
          Map.put(good, "boxes", List.duplicate(good["boxes"] |> hd(), 65))
        ] do
      assert_raise ArgumentError, fn -> Shape.from_facts!(bad) end
    end

    box = Box.new({0, 0, 0, 1, 1, 1})

    assert_raise ArgumentError, fn ->
      Collision.clip(:x, box, List.duplicate(stone(), 129), 1.0)
    end

    assert_raise ArgumentError, fn -> Collision.clip(:x, box, [], 65.0) end
    assert_raise ArgumentError, fn -> Shape.move(stone(), {30_000_001, 0, 0}) end

    assert_raise ArgumentError, fn ->
      "[\"nan\",0,0,1,1,1]" |> JSON.decode!() |> List.to_tuple() |> Box.new()
    end
  end

  test "invalid fluid depths and overflowing impulses cannot reach geometry owners" do
    assert {:error, :invalid_fluid_controls} ==
             FluidControls.step({0, 0, 0}, %FluidControls{water: -1})

    assert {:error, :invalid_fluid_controls} == FluidControls.step({65, 0, 0}, %FluidControls{})

    assert {:error, :fluid_input_limit} ==
             FluidControls.step({0, 64, 0}, %FluidControls{water: 1, jump: true})
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

  test "step movement: shape, candidate, displacement and plan bounds fail explicitly" do
    for {box, shapes, v, step, grounded} <- [
          {nil, [], {0, 0, 0}, 0.6, true},
          {@box, [], {65, 0, 0}, 0.6, true},
          {@box, [], {0, 0}, 0.6, true},
          {@box, [], {0, 0, 0}, -0.1, true},
          {@box, [], {0, 0, 0}, 65, true},
          {@box, [], {0, 0, 0}, 0.6, :yes},
          {@box, [%Shape{} | :bad], {0, 0, 0}, 0.6, true},
          {@box, [:bad], {0, 0, 0}, 0.6, true}
        ],
        do:
          assert(
            {:error, :invalid_step_query} == StepMovement.prepare(box, shapes, v, step, grounded)
          )

    assert {:error, :step_shape_limit} =
             StepMovement.prepare(@box, List.duplicate(%Shape{}, 129), {0, 0, 0}, 0.6, true)

    assert {:error, :invalid_step_plan} = StepMovement.finish(%StepMovement{}, [])
    assert {:error, :invalid_step_plan} = StepMovement.finish(nil, [])

    for shape <- [
          %Shape{bits: :binary.copy(<<0>>, 4097)},
          %Shape{axes: {Tuple.duplicate(0.0, 34), {0.0}, {0.0}}},
          %Shape{boxes: List.duplicate({0, 0, 0, 1, 1, 1}, 65)},
          %Shape{boxes: [{0, 0, 0, 1, 1, 1} | :invalid]}
        ],
        do:
          assert(
            {:error, :invalid_step_query} ==
              StepMovement.prepare(@box, [shape], {0, 0, 0}, 0.6, true)
          )

    {:step, plan} = StepMovement.prepare(@box, [slab()], {2, 0, 0}, 0.6, true)

    assert {:error, :invalid_step_plan} =
             StepMovement.finish(%{plan | start_box: Box.move(@box, {0, -65, 0})}, [])

    shapes = for i <- 1..128, do: VoxelOps.box({1, 0, -1, 2, i / 256, 1})
    assert {:ok, heights} = StepMovement.candidate_heights(@box, shapes, 1, 0)
    assert length(heights) == 128

    extra =
      Shape.from_facts!(%{
        "axes" => [[1.0, 2.0], [0.0, 0.001, 0.002], [-1.0, 1.0]],
        "sizes" => [1, 2, 1],
        "bits" => "03",
        "boxes" => [[1.0, 0.0, -1.0, 2.0, 0.002, 1.0]]
      })

    assert {:error, :step_height_limit} =
             StepMovement.candidate_heights(@box, [extra | tl(shapes)], 1, 0)
  end

  test "voxel unions: invalid geometry and oversized jobs fail without a partial union" do
    full = VoxelOps.box({0.0, 0.0, 0.0, 1.0, 1.0, 1.0})
    assert_raise ArgumentError, fn -> VoxelOps.box("invalid") end
    assert_raise ArgumentError, fn -> VoxelOps.box({1.0, 0.0, 0.0, 0.0, 1.0, 1.0}) end
    assert_raise ArgumentError, fn -> VoxelOps.box({0.0, 0.0, 0.0, 17.0, 1.0, 1.0}) end
    assert_raise ArgumentError, fn -> VoxelOps.union(full, %Shape{bits: <<0>>}) end

    for oversized <- [
          %{full | axes: {:erlang.make_tuple(100_000, 0.0), {0.0, 1.0}, {0.0, 1.0}}},
          %{full | boxes: [:erlang.make_tuple(100_000, 0.0)]},
          %{full | bits: :binary.copy(<<1>>, 100_000)},
          %{full | boxes: List.duplicate(hd(full.boxes), 100_000)}
        ],
        do: assert_raise(ArgumentError, fn -> VoxelOps.optimize(oversized) end)

    dense = %Shape{
      axes: {List.to_tuple(Enum.map(0..32, &(&1 / 32))), {0.0, 1.0}, {0.0, 1.0}},
      sizes: {32, 1, 1},
      bits: <<255, 255, 255, 255>>,
      boxes: full.boxes
    }

    assert_raise ArgumentError, fn ->
      VoxelOps.union(dense, Shape.move(dense, {0.001, 0.0, 0.0}))
    end

    assert dense.bits == <<255, 255, 255, 255>>
  end

  test "fragmented voxel grids stop at the box work bound without an approximation" do
    axes = List.to_tuple(Enum.map(0..15, &(&1 / 15)))

    bits =
      for byte <- 0..421, into: <<>> do
        value =
          Enum.reduce(0..7, 0, fn bit, acc ->
            index = byte * 8 + bit
            x = div(index, 225)
            y = rem(div(index, 15), 15)
            z = rem(index, 15)

            if index < 3375 and rem(x + y + z, 2) == 0,
              do: Bitwise.bor(acc, Bitwise.bsl(1, bit)),
              else: acc
          end)

        <<value>>
      end

    fragmented = %Shape{
      axes: {axes, axes, axes},
      sizes: {15, 15, 15},
      bits: bits,
      boxes: [{0.0, 0.0, 0.0, 1.0, 1.0, 1.0}]
    }

    assert_raise ArgumentError, fn -> VoxelOps.optimize(fragmented) end
  end
end
