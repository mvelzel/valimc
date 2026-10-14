defmodule Valimc.Physics.ShulkerShape do
  @moduledoc false
  alias Valimc.Physics.Shape

  @directions %{
    "down" => {0, -1, 0},
    "up" => {0, 1, 0},
    "north" => {0, 0, -1},
    "south" => {0, 0, 1},
    "west" => {-1, 0, 0},
    "east" => {1, 0, 0}
  }

  def shape(direction, context, full) do
    old = float32(context.progress_old)
    current = float32(context.progress)
    # Native getProgress(1.0f) still performs float subtraction and addition.
    extension = float32(0.5 * float32(old + float32(current - old)))
    steps = Map.fetch!(@directions, direction) |> Tuple.to_list()

    axes =
      Enum.zip_with([{-0.5, 0.5, 0.5}, {0.0, 1.0, 0.0}, {-0.5, 0.5, 0.5}], steps, fn {lo, hi,
                                                                                      offset},
                                                                                     step ->
        delta = step * extension

        {if(delta < 0, do: lo + delta, else: lo) + offset,
         if(delta > 0, do: hi + delta, else: hi) + offset}
      end)

    # For this expanded unit box, native Shapes.create either snaps to its full
    # cube or keeps a single cell. Other shapes require their own grid rules.
    if Enum.all?(axes, fn {lo, hi} -> abs(lo) < 1.0e-7 and abs(hi - 1.0) < 1.0e-7 end) do
      full
    else
      [{x0, x1}, {y0, y1}, {z0, z1}] = axes

      %Shape{
        axes: List.to_tuple(axes),
        sizes: {1, 1, 1},
        bits: <<1>>,
        boxes: [{x0, y0, z0, x1, y1, z1}]
      }
    end
  end

  defp float32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end
end
