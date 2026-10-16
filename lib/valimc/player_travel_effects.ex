defmodule Valimc.PlayerTravelEffects do
  @moduledoc "Pure current-head travel facts; callers supply velocity at the native gravity selection point."
  alias Valimc.PlayerEffects
  alias Valimc.Protocol.EffectTypes
  @slow EffectTypes.id("slow_falling")
  @levitation EffectTypes.id("levitation")

  def signature(effects) do
    levitation =
      case effects[@levitation] do
        nil -> nil
        [{_, amplifier, _, _, _} | _] -> amplifier
      end

    {Map.has_key?(effects, @slow), levitation}
  end

  def derive(effects, velocity_y) do
    if PlayerEffects.valid?(effects) and is_number(velocity_y) and abs(velocity_y) <= 64 do
      {slow, levitation} = signature(effects)
      {:ok, gravity} = gravity(0.08, velocity_y, slow)

      {:ok, %{gravity: gravity, levitation: levitation, reset_fall: slow or levitation != nil}}
    else
      {:error, :invalid_travel_effects}
    end
  end

  def gravity(base, velocity_y, slow)
      when is_number(base) and base >= -1 and base <= 1 and
             is_number(velocity_y) and abs(velocity_y) <= 64 and is_boolean(slow),
      do: {:ok, if(slow and velocity_y <= 0, do: min(0.01, base), else: base)}

  def gravity(_, _, _), do: {:error, :invalid_travel_effects}
end
