defmodule Valimc.World.TickPipeline do
  @moduledoc """
  One region tick in fixed phases (VMC-066), on the owner's game tick:
  scheduled block ticks, random ticks, items, cooking, orb lifetime, then orbs
  and their deliveries. Block ticks and item motion run only in chunks a
  simulation ticket covers; cooking and orb ageing while any chunk does
  (VMC-077e). Phases never wait for storage (VMC-063); a full write queue defers
  their commits to a later tick.
  """
  alias Valimc.World.{CookingOrbDelivery, CookingOrbRuntime, RegionData, Tickets}

  def run(resource, tick, now) do
    resource
    |> RegionData.block_ticks(tick)
    |> RegionData.item_tick(now)
    |> simulated(&(&1 |> RegionData.cooking_tick(now) |> RegionData.orb_lifetime()))
    |> CookingOrbRuntime.tick(now)
    |> CookingOrbDelivery.tick(now)
  end

  # Cooking and orb ageing run while any of the region's chunks ticks (VMC-077e).
  defp simulated(resource, phases),
    do: if(Tickets.simulating?(resource.tickets), do: phases.(resource), else: resource)
end
