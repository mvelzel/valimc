defmodule Valimc.World.TickPipeline do
  @moduledoc """
  One region tick in fixed phases (VMC-066), on the owner's game tick:
  scheduled block ticks, random ticks, items, cooking, then orbs and their
  deliveries. Phases never wait for storage (VMC-063); a full write queue defers
  their commits to a later tick.
  """
  alias Valimc.World.{CookingOrbDelivery, CookingOrbRuntime, RegionData}

  def run(resource, tick, now) do
    resource
    |> RegionData.block_ticks(tick)
    |> RegionData.item_tick(now)
    |> RegionData.cooking_tick(now)
    |> CookingOrbRuntime.tick(now)
    |> CookingOrbDelivery.tick(now)
  end
end
