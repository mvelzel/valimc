defmodule Valimc.Physics.PistonSnapshot do
  @moduledoc "Immutable piston observations; block state and ownership fences belong to the caller."
  @directions [:down, :up, :north, :south, :west, :east]
  defstruct moved_state: 0, direction: :up, extending: false, source: false, progress: 0.0

  def new(id, direction, extending, source, progress)
      when is_integer(id) and is_number(progress) and is_boolean(extending) and is_boolean(source) do
    snapshot = %__MODULE__{
      moved_state: id,
      direction: direction,
      extending: extending,
      source: source,
      progress: progress
    }

    unless valid?(snapshot), do: raise(ArgumentError, "invalid piston snapshot")
    <<rounded::float-32>> = <<progress::float-32>>
    %{snapshot | progress: rounded}
  end

  def new(_, _, _, _, _), do: raise(ArgumentError, "invalid piston snapshot")

  def valid?(%__MODULE__{} = p) do
    is_integer(p.moved_state) and p.moved_state >= 0 and
      p.moved_state < Valimc.Physics.BlockShapes.state_count() and
      Valimc.Physics.BlockShapes.fetch(p.moved_state) !=
        {:context_required, "minecraft:moving_piston"} and
      p.direction in @directions and is_boolean(p.extending) and is_boolean(p.source) and
      is_number(p.progress) and p.progress >= 0 and p.progress <= 1
  end

  def valid?(_), do: false
end
