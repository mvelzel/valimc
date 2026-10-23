defmodule Valimc.Blocks.Machine do
  @moduledoc """
  Hoppers, droppers and dispensers (`HopperBlock`, `DropperBlock`,
  `DispenserBlock`, VMC-049a): each owns a container entry (5 or 9 slots)
  that its owner moves items through; the block rules switch a hopper's
  `enabled` and fire a dispenser's tick on power.
  """
  use Valimc.Blocks.Behaviour
  alias Valimc.Data.Blocks

  @hoppers Blocks.states("hopper")
  @droppers Blocks.states("dropper")
  @dispensers Blocks.states("dispenser")
  @directions %{
    "down" => {0, -1, 0},
    "up" => {0, 1, 0},
    "north" => {0, 0, -1},
    "south" => {0, 0, 1},
    "west" => {-1, 0, 0},
    "east" => {1, 0, 0}
  }

  @impl true
  def block_entity(state) when state in @hoppers, do: :hopper
  def block_entity(state) when state in @droppers, do: :dropper
  def block_entity(state) when state in @dispensers, do: :dispenser
  def block_entity(_state), do: nil

  @doc "The machine kind of a state (`:hopper`, `:dropper`, `:dispenser`) or nil."
  def kind(state) when is_integer(state), do: block_entity(state)
  def kind(_), do: nil

  @doc "The unit step a machine's `facing` names."
  def facing(state), do: Map.fetch!(@directions, property(state, "facing"))

  @doc "Whether a hopper is enabled (no power on it)."
  def enabled?(state), do: property(state, "enabled") == "true"

  defp property(state, name), do: state |> Blocks.properties() |> List.keyfind(name, 0) |> elem(1)
end
