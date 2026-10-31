defmodule Valimc.Blocks.BrewingStand do
  @moduledoc """
  Brewing stands (`BrewingStandBlock`, VMC-034o): an owned entry
  (`Valimc.World.Containers.create_owned/4` with `:brewing_stand`) whose
  `%Valimc.Blocks.Brewing{}` ticks with the furnaces. Its `has_bottle_0..2`
  properties show which bottle slots hold something (`serverTick`'s
  `setBlock`).
  """
  use Valimc.Blocks.Behaviour
  alias Valimc.Data.Blocks

  @states Blocks.states("brewing_stand")

  @impl true
  def block_entity(state) when state in @states, do: :brewing_stand
  def block_entity(_state), do: nil

  @doc "Whether a block state is a brewing stand."
  def stand?(state), do: is_integer(state) and state in @states

  @doc "The stand with its bottle properties set to `[b0, b1, b2]`."
  def with_bottles(state, [b0, b1, b2])
      when is_boolean(b0) and is_boolean(b1) and is_boolean(b2) do
    if stand?(state) do
      Blocks.state("brewing_stand", %{
        "has_bottle_0" => Atom.to_string(b0),
        "has_bottle_1" => Atom.to_string(b1),
        "has_bottle_2" => Atom.to_string(b2)
      })
    else
      state
    end
  end

  @doc "Whether two states are brewing stands differing at most in their bottles."
  def bottles_change?(from, to), do: stand?(from) and stand?(to)
end
