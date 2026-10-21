defmodule Valimc.Physics.ChestPlacement do
  @moduledoc "Pinned isolated single-chest orientation/water state; callers must separately admit placement and neighbors."
  import Bitwise
  alias Valimc.Registry.BlockFacts
  @path Path.expand("../../../priv/physics/chest_placement.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @states Map.new(@facts["by_heading"], fn {heading, states} ->
            {String.to_integer(heading), states}
          end)
  unless Valimc.Version.stamped?(@facts) and
           Enum.sort(Map.keys(@states)) == [2, 3, 4, 5] and
           Enum.all?(@states, fn {_, states} ->
             Enum.sort(Map.keys(states)) == ["dry", "wet"] and
               Enum.all?(Map.values(states), &Valimc.ChestAccess.single?/1)
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

  def single_state(yaw, target_state) do
    with {:ok, heading} <- horizontal(yaw),
         fluid = BlockFacts.fluid(target_state) do
      {:ok, @states[heading][if(fluid.kind == :water and fluid.source, do: "wet", else: "dry")]}
    end
  end
end
