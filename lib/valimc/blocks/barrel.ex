defmodule Valimc.Blocks.Barrel do
  @moduledoc """
  Barrels (`BarrelBlock`, VMC-032c1): a 27-slot storage entry
  (`Valimc.World.Containers.create_storage/4`) behind a three-row chest menu.
  Its `open` property shows whether anyone views it; the owner switches it as
  the viewer count leaves and returns to zero (`ContainerOpenersCounter`),
  with the open and close sounds at the centre of the barrel's front face.
  """
  use Valimc.Blocks.Behaviour
  alias Valimc.Data.Blocks

  @states Blocks.states("barrel")
  @directions %{
    "down" => {0, -1, 0},
    "up" => {0, 1, 0},
    "north" => {0, 0, -1},
    "south" => {0, 0, 1},
    "west" => {-1, 0, 0},
    "east" => {1, 0, 0}
  }

  @impl true
  def block_entity(state) when state in @states, do: :barrel
  def block_entity(_state), do: nil

  @doc "Whether a block state is a barrel."
  def barrel?(state), do: is_integer(state) and state in @states

  @doc "Whether a barrel state shows open."
  def open?(state), do: barrel?(state) and property(state, "open") == "true"

  @doc "The barrel state with `open` set (`BarrelBlockEntity.updateBlockState`)."
  def with_open(state, open) when is_boolean(open) do
    Blocks.state("barrel", %{
      "facing" => property(state, "facing"),
      "open" => Atom.to_string(open)
    })
  end

  @doc "Whether two states are the same barrel but for `open`: the container and its viewers stay."
  def open_change?(from, to),
    do:
      barrel?(from) and barrel?(to) and from != to and
        property(from, "facing") == property(to, "facing")

  @doc """
  Where a barrel's open and close sounds play (`BarrelBlockEntity.playSound`):
  the centre of the face it looks out of.
  """
  def sound_at(state, {x, y, z}) do
    {dx, dy, dz} = Map.fetch!(@directions, property(state, "facing"))
    {x + 0.5 + dx / 2, y + 0.5 + dy / 2, z + 0.5 + dz / 2}
  end

  defp property(state, name), do: state |> Blocks.properties() |> List.keyfind(name, 0) |> elem(1)
end
