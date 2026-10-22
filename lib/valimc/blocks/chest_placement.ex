defmodule Valimc.Blocks.ChestPlacement do
  @moduledoc """
  A placed chest's state (orientation and water, pinned facts) and whether
  vanilla would join it into a double chest, which ValiMC does not model yet.
  """
  import Bitwise
  alias Valimc.Data.BlockFacts
  use Valimc.Data.Facts, "physics/chest_placement.json"

  @states Map.new(@facts["by_heading"], fn {heading, states} ->
            {String.to_integer(heading), states}
          end)
  unless Enum.sort(Map.keys(@states)) == [2, 3, 4, 5] and
           Enum.all?(@states, fn {_, states} ->
             Enum.sort(Map.keys(states)) == ["dry", "wet"] and
               Enum.all?(Map.values(states), &Valimc.Blocks.Chest.single?/1)
           end),
         do: raise("Wrong single-chest placement facts")

  # The native floor-to-int saturates before its low two bits choose a direction.
  # Reducing an unbounded float angle modulo360 first gives different huge-yaw results.
  def horizontal(yaw) when is_number(yaw) and abs(yaw) <= 3.4028234663852886e38 do
    quarter = yaw / 90.0 + 0.5
    index = quarter |> floor() |> max(-2_147_483_648) |> min(2_147_483_647) |> band(3)
    {:ok, elem({3, 4, 2, 5}, index)}
  end

  def horizontal(_), do: {:error, :invalid_chest_yaw}

  def neighbors({x, y, z}), do: [{x - 1, y, z}, {x + 1, y, z}, {x, y, z - 1}, {x, y, z + 1}]

  # A single chest's facing (a direction id, 2..5): the opposite of the
  # heading of the player that placed it.
  @facing for {heading, states} <- @states,
              {_, state} <- states,
              into: %{},
              do: {state, %{2 => 3, 3 => 2, 4 => 5, 5 => 4}[heading]}

  @doc "The facing of a single chest state (2 north, 3 south, 4 west, 5 east), or nil."
  def facing(state), do: Map.get(@facing, state)

  @doc """
  Whether vanilla's `ChestBlock.getStateForPlacement` would join the single
  chest `state` placed at `position` into a double chest. Sneaking on a side
  face (`face` 2..5) joins the clicked chest when it faces across that face's
  axis; otherwise the chest joins a single chest beside it, clockwise or
  counter-clockwise of its facing, that faces the same way. `read` gives a
  position's block state.
  """
  def joins?(state, position, face, secondary, read) do
    facing = facing(state)

    cond do
      facing == nil ->
        false

      secondary and face in 2..5 ->
        partner = facing(read.(offset(position, opposite(face))))
        partner != nil and axis(partner) != axis(face)

      secondary ->
        false

      true ->
        facing(read.(offset(position, clockwise(facing)))) == facing or
          facing(read.(offset(position, counter_clockwise(facing)))) == facing
    end
  end

  defp opposite(2), do: 3
  defp opposite(3), do: 2
  defp opposite(4), do: 5
  defp opposite(5), do: 4

  defp clockwise(2), do: 5
  defp clockwise(5), do: 3
  defp clockwise(3), do: 4
  defp clockwise(4), do: 2

  defp counter_clockwise(direction), do: opposite(clockwise(direction))

  defp axis(direction) when direction in [2, 3], do: :z
  defp axis(direction) when direction in [4, 5], do: :x

  defp offset({x, y, z}, 2), do: {x, y, z - 1}
  defp offset({x, y, z}, 3), do: {x, y, z + 1}
  defp offset({x, y, z}, 4), do: {x - 1, y, z}
  defp offset({x, y, z}, 5), do: {x + 1, y, z}

  def single_state(yaw, target_state) do
    with {:ok, heading} <- horizontal(yaw),
         fluid = BlockFacts.fluid(target_state) do
      {:ok, @states[heading][if(fluid.kind == :water and fluid.source, do: "wet", else: "dry")]}
    end
  end
end
