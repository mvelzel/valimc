defmodule Valimc.Physics.BlockEntityContext do
  @moduledoc "Pure block-entity observations; owners must fence these with the block state."
  defstruct kind: :unavailable, progress_old: 0.0, progress: 0.0, piston: nil

  def unavailable, do: %__MODULE__{}
  def absent, do: %__MODULE__{kind: :absent}
  def other, do: %__MODULE__{kind: :other}

  def piston(%Valimc.Physics.PistonSnapshot{} = snapshot) do
    unless Valimc.Physics.PistonSnapshot.valid?(snapshot),
      do: raise(ArgumentError, "invalid piston snapshot")

    %__MODULE__{kind: :piston, piston: snapshot}
  end

  def piston(_), do: raise(ArgumentError, "invalid piston snapshot")

  def shulker(old, current) when is_number(old) and is_number(current) do
    c = %__MODULE__{kind: :shulker, progress_old: old, progress: current}
    unless valid?(c), do: raise(ArgumentError, "invalid shulker progress")
    %{c | progress_old: float32(old), progress: float32(current)}
  end

  def shulker(_, _), do: raise(ArgumentError, "invalid shulker progress")

  def valid?(%__MODULE__{kind: :shulker, progress_old: old, progress: current, piston: nil}),
    do: progress?(old) and progress?(current)

  def valid?(%__MODULE__{kind: :piston, progress_old: old, progress: current, piston: piston}),
    do:
      is_float(old) and old == 0.0 and is_float(current) and current == 0.0 and
        Valimc.Physics.PistonSnapshot.valid?(piston)

  def valid?(%__MODULE__{kind: kind, progress_old: old, progress: current, piston: nil})
      when kind in [:unavailable, :absent, :other],
      do: is_float(old) and old == 0.0 and is_float(current) and current == 0.0

  def valid?(_), do: false

  defp progress?(value), do: is_number(value) and value >= 0 and value <= 1

  defp float32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end
end
