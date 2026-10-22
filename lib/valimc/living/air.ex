defmodule Valimc.Living.Air do
  @moduledoc """
  A living entity's air supply (vanilla `LivingEntity.baseTick` air): eye
  contact with water, Respiration, the breathing effects, drowning and
  refilling. The owner supplies fresh contact, ticks and random draws.
  """
  alias Valimc.Data.EffectTypes
  alias Valimc.Data.Blocks
  @maximum 300
  @bubble_column Blocks.id("bubble_column")
  @water_breathing EffectTypes.id("water_breathing")
  @conduit EffectTypes.id("conduit_power")
  @nautilus EffectTypes.id("breath_of_the_nautilus")

  def maximum, do: @maximum
  def valid?(air), do: is_integer(air) and air in -20..@maximum
  def bubble_states, do: Enum.to_list(Blocks.states("bubble_column"))

  @doc "Whether an eye under water at a block of `state` is submerged (bubble columns are not)."
  def submerged?(eye_water, state), do: eye_water and Blocks.block_id(state) != @bubble_column

  @doc "The breathing effects' policy: `:none`, `:hold` (no drain) or `:refill`."
  def policy(effects) when is_map(effects) do
    if breathes?(effects), do: if(refills?(effects), do: :refill, else: :hold), else: :none
  end

  def breathes?(effects) when is_map(effects),
    do:
      Map.has_key?(effects, @water_breathing) or Map.has_key?(effects, @conduit) or
        Map.has_key?(effects, @nautilus)

  def refills?(effects) when is_map(effects),
    do:
      not Map.has_key?(effects, @nautilus) or Map.has_key?(effects, @water_breathing) or
        Map.has_key?(effects, @conduit)

  @doc "One tick of air: `{air, drowning damage}`."
  def tick(air, submerged, immune, oxygen, draw, policy \\ :none)

  def tick(air, true, false, oxygen, draw, :none) do
    decreased = decrease(air, oxygen, draw)
    if drowning?(decreased), do: {0, 2.0}, else: {decreased, 0.0}
  end

  def tick(air, true, _immune, _oxygen, _draw, :hold), do: {air, 0.0}

  def tick(air, _submerged, _immune, _oxygen, _draw, policy)
      when policy in [:none, :refill, :hold], do: {increase(air), 0.0}

  def decrease(air, oxygen, draw)
      when is_integer(air) and air in -20..@maximum and is_number(oxygen) and
             oxygen >= 0 and oxygen <= 1024 and is_number(draw) and draw >= 0 and draw < 1 do
    if oxygen > 0 and draw >= 1.0 / (oxygen + 1.0), do: air, else: air - 1
  end

  def increase(air) when is_integer(air) and air in -20..@maximum,
    do: min(@maximum, air + 4)

  def drowning?(air) when is_integer(air), do: air <= -20
end
