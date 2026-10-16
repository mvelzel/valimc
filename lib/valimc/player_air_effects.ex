defmodule Valimc.PlayerAirEffects do
  @moduledoc "Native breathing/refill predicates on a validated owned effect map; no clocks or world authority."
  alias Valimc.Protocol.EffectTypes
  @water EffectTypes.id("water_breathing")
  @conduit EffectTypes.id("conduit_power")
  @nautilus EffectTypes.id("breath_of_the_nautilus")

  def policy(effects) when is_map(effects) do
    if breathes?(effects), do: if(refills?(effects), do: :refill, else: :hold), else: :none
  end

  def breathes?(effects) when is_map(effects),
    do:
      Map.has_key?(effects, @water) or Map.has_key?(effects, @conduit) or
        Map.has_key?(effects, @nautilus)

  def refills?(effects) when is_map(effects),
    do:
      not Map.has_key?(effects, @nautilus) or Map.has_key?(effects, @water) or
        Map.has_key?(effects, @conduit)
end
