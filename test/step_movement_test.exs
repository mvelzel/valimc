defmodule Valimc.StepMovementTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{Box, Shape, StepMovement, VoxelOps}
  @box {-0.3, 0.0, -0.3, 0.3, 1.8, 0.3}
  defp slab, do: VoxelOps.box({1, 0, -1, 2, 0.5, 1})

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
