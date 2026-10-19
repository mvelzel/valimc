defmodule Valimc.StepMovementTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{Box, Shape, StepMovement, VoxelOps}
  @box {-0.3, 0.0, -0.3, 0.3, 1.8, 0.3}
  defp floor_shape, do: VoxelOps.box({-4, -1, -4, 4, 0, 4})
  defp slab, do: VoxelOps.box({1, 0, -1, 2, 0.5, 1})

  test "slabs step up only after ground or a clipped downward movement" do
    shapes = [floor_shape(), slab()]
    assert {:step, plan} = StepMovement.prepare(@box, shapes, {2, 0, 0}, 0.6, true)
    assert {:ok, {2.0, 0.5, +0.0}} = StepMovement.finish(plan, shapes)

    assert {:resolved, {0.7, +0.0, +0.0}} =
             StepMovement.prepare(@box, shapes, {2, 0, 0}, 0.6, false)

    assert {:step, plan} = StepMovement.prepare(@box, shapes, {2, -0.08, 0}, 0.6, false)
    assert {:ok, {2.0, 0.5, +0.0}} = StepMovement.finish(plan, shapes)

    assert {:resolved, {0.7, +0.0, +0.0}} =
             StepMovement.prepare(@box, shapes, {2, 0, 0}, 0.0, true)
  end

  test "falling steps use the lowered box and restore its displacement in the result" do
    shapes = [floor_shape(), slab()]
    falling = Box.move(@box, {0, 0.2, 0})
    assert {:step, plan} = StepMovement.prepare(falling, shapes, {2, -1, 0}, 0.6, false)
    assert elem(plan.start_box, 1) == 0.0
    assert elem(plan.query, 1) == 0.0
    assert {:ok, {2.0, y, +0.0}} = StepMovement.finish(plan, shapes)
    assert y == 0.3
    assert {:step, grounded} = StepMovement.prepare(@box, shapes, {2, 0, 0}, 0.6, true)
    assert elem(grounded.query, 1) == -9.999999747378752e-6
  end

  test "the first improving candidate wins even if a higher step travels further" do
    low = VoxelOps.box({1, 0, -1, 1.5, 0.25, 1})
    high = VoxelOps.box({1.5, 0, -1, 2, 0.5, 1})
    shapes = [floor_shape(), low, high]
    assert {:step, plan} = StepMovement.prepare(@box, shapes, {2, 0, 0}, 0.6, true)
    assert {:ok, {1.2, 0.25, +0.0}} = StepMovement.finish(plan, shapes)
    assert {:ok, {1.2, 0.25, +0.0}} = StepMovement.finish(plan, Enum.reverse(shapes))
  end

  test "a second observation can block the step with a low ceiling" do
    initial = [floor_shape(), slab()]
    assert {:step, plan} = StepMovement.prepare(@box, initial, {2, 0, 0}, 0.6, true)
    ceiling = VoxelOps.box({-1, 2, -1, 4, 3, 1})
    assert {:ok, result} = StepMovement.finish(plan, [ceiling | initial])
    assert result == plan.base
    assert {:ok, {2.0, 0.5, +0.0}} = StepMovement.finish(plan, initial)
  end

  test "candidate points include internal grid coordinates and round/deduplicate as float32" do
    grid =
      Shape.from_facts!(%{
        "axes" => [[1.0, 2.0], [0.0, 0.25, 0.5], [-1.0, 1.0]],
        "sizes" => [1, 2, 1],
        "bits" => "03",
        "boxes" => [[1.0, 0.0, -1.0, 2.0, 0.5, 1.0]]
      })

    assert {:ok, [0.25, 0.5]} = StepMovement.candidate_heights(@box, [grid, grid], 0.6, 0)
    assert {:ok, [+0.0, 0.5]} = StepMovement.candidate_heights(@box, [grid], 0.6, 0.25)
    close = VoxelOps.box({1, 0, -1, 2, 0.500000001, 1})
    assert {:ok, [0.5]} = StepMovement.candidate_heights(@box, [slab(), close], 0.6, 0)
  end

  test "zero squared length bypasses shape clipping including subnormal requests and signed zero" do
    for v <- [{-0.0, -0.0, -0.0}, {1.0e-200, -1.0e-200, 0.0}] do
      assert {:resolved, actual} = StepMovement.prepare(@box, [slab()], v, 0.6, true)
      assert :erlang.term_to_binary(actual) == :erlang.term_to_binary(v)
    end
  end

  test "all shape, candidate, displacement and plan bounds fail explicitly" do
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
end
