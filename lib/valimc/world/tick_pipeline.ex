defmodule Valimc.World.TickPipeline do
  @moduledoc """
  One region tick in fixed phases (VMC-066), on the owner's game tick:
  scheduled block ticks, random ticks, block events (VMC-048b), entities
  (VMC-077h), moving pistons' block entities (VMC-048b), hoppers (VMC-049a),
  then cooking. Block ticks and item motion run only in chunks a simulation ticket
  covers, including each cooking processor (VMC-080j). Phases never wait for
  storage (VMC-063); a full write queue defers their commits to a later tick.
  """
  alias Valimc.World.{RegionData, Tickets}

  # The group delivers a phase's sibling effects before entering the next,
  # so hoppers observe what this tick's dispensers changed across a section line.
  def phases, do: [:blocks, :events, :entities, :pistons, :hoppers, :cooking]
  def run(resource, :blocks, tick, _now), do: RegionData.block_ticks(resource, tick)
  def run(resource, :events, _tick, _now), do: RegionData.block_events(resource)
  def run(resource, :entities, _tick, now), do: RegionData.item_tick(resource, now)
  def run(resource, :pistons, _tick, _now), do: RegionData.moving_pistons(resource)
  def run(resource, :hoppers, _tick, _now), do: RegionData.hoppers(resource)

  def run(resource, :cooking, _tick, now),
    do: simulated(resource, &RegionData.cooking_tick(&1, now))

  # The runtime selects eligible processors within a partially active section.
  defp simulated(resource, phases),
    do: if(Tickets.simulating?(resource.tickets), do: phases.(resource), else: resource)
end
