defmodule Valimc.Blocks.Farmland do
  @moduledoc """
  Farmland trampled by a landing (VMC-039a, `FarmlandBlock.fallOn`): a
  living body landing on it from `distance` tramples it when the level
  random's `nextFloat()` falls under the distance less a half and the body
  is big enough (`width² × height` over 0.512, in floats). Who may trample
  (any player; a mob while the `mob_griefing` game rule allows) is the
  caller's, and so is the turn to dirt (the block rules' trample).
  """
  alias Valimc.Data.{Blocks, Float32}

  @farmland Blocks.states("farmland")
  @threshold Float32.round(0.512)

  @doc "Whether `state` is farmland."
  def farmland?(state), do: state in @farmland

  @doc """
  Whether a body `width` by `height` landing on `state` from `distance`
  tramples it, `roll` being the random's `nextFloat()`.
  """
  def tramples?(state, distance, {width, height}, roll) do
    farmland?(state) and roll < distance - 0.5 and
      Float32.round(Float32.round(width * width) * height) > @threshold
  end
end
