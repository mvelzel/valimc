defmodule Valimc.PeriodicEffect do
  @moduledoc "Native active-head health requests before duration decrement; health/defenses remain owner work."
  alias Valimc.{PlayerHealth, StatusEffect}
  alias Valimc.Protocol.EffectTypes
  import Bitwise
  @regeneration EffectTypes.id("regeneration")
  @poison EffectTypes.id("poison")
  @wither EffectTypes.id("wither")
  @periods %{@regeneration => 50, @poison => 25, @wither => 40}

  def request(id, [_ | _] = effect, age, %PlayerHealth{} = health)
      when is_integer(age) and age in -2_147_483_648..2_147_483_647 do
    if EffectTypes.valid_id?(id) and StatusEffect.valid?(effect) and PlayerHealth.valid?(health) do
      [{duration, amplifier, _, _, _} | _] = effect
      phase = if duration == -1, do: age, else: duration
      period = Map.get(@periods, id)

      action =
        if period != nil and duration != 0 and due?(period, amplifier, phase),
          do: action(id, health),
          else: :none

      {:ok, action}
    else
      {:error, :invalid_periodic_effect}
    end
  end

  def request(_, _, _, _), do: {:error, :invalid_periodic_effect}

  defp due?(base, amplifier, phase) do
    # JVM ishr masks the distance even for native amplifier32..255.
    period = bsr(base, band(amplifier, 31))
    period <= 0 or rem(phase, period) == 0
  end

  defp action(@regeneration, %{value: value, maximum: maximum}) when value < maximum,
    do: {:heal, 1.0}

  defp action(@poison, %{value: value}) when value > 1, do: {:hurt, :magic, 1.0}
  defp action(@wither, _), do: {:hurt, :wither, 1.0}
  defp action(_, _), do: :none
end
