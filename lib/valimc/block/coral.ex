defmodule Valimc.Block.Coral do
  @moduledoc """
  Living coral blocks (`CoralBlock`). Placed or disturbed away from water, a coral
  block schedules a tick 60–99 ticks later and dies then unless water touches it.
  """
  use Valimc.Block.Behaviour
  alias Valimc.Physics.FluidBlocks
  alias Valimc.Registry.Blocks

  @dead for {_, ids} <- Map.take(Blocks.classes(), ["CoralBlock"]),
            id <- ids,
            name = Blocks.name(id),
            into: %{},
            do: {Blocks.default_state(name), Blocks.default_state("dead_" <> name)}

  @impl true
  def shape_update(position, state, read, random) do
    if water_adjacent?(position, read),
      do: [],
      else: [{:schedule, position, state, 60 + random.(40), 0}]
  end

  @impl true
  def scheduled_tick(position, state, read, _random) do
    if water_adjacent?(position, read), do: [], else: [{:set, position, Map.fetch!(@dead, state)}]
  end

  @doc "Whether any of the six neighbours holds water (vanilla `scanForWater`)."
  def water_adjacent?({x, y, z}, read) do
    Enum.any?(
      [{x, y - 1, z}, {x, y + 1, z}, {x, y, z - 1}, {x, y, z + 1}, {x - 1, y, z}, {x + 1, y, z}],
      fn neighbour ->
        case read.(neighbour) do
          nil -> false
          block -> match?({:ok, %{kind: :water}}, FluidBlocks.fetch(block))
        end
      end
    )
  end
end
