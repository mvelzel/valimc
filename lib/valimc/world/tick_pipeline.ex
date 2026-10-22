defmodule Valimc.World.TickPipeline do
  @moduledoc """
  One region tick in fixed phases (VMC-066), on the owner's game tick:
  scheduled block ticks, random ticks, entities (items and orbs, VMC-077h), then
  cooking. Block ticks and item motion run only in chunks a simulation ticket
  covers; cooking while any chunk does (VMC-077e). Phases never wait for
  storage (VMC-063); a full write queue defers their commits to a later tick.
  """
  alias Valimc.World.{RegionData, Tickets}

  def run(resource, tick, now) do
    resource
    |> RegionData.block_ticks(tick)
    |> RegionData.item_tick(now)
    |> simulated(&RegionData.cooking_tick(&1, now))
  end

  # Cooking runs while any of the region's chunks ticks (VMC-077e).
  defp simulated(resource, phases),
    do: if(Tickets.simulating?(resource.tickets), do: phases.(resource), else: resource)
end
