defmodule Valimc.PlayerResistance do
  @moduledoc "Native source-tagged Resistance reduction on a validated player effect map, before enchantments."
  alias Valimc.PlayerEffects
  alias Valimc.Protocol.EffectTypes
  alias Valimc.Registry.DamageTypes
  @resistance EffectTypes.id("resistance")
  @float_max 3.4028234663852886e38

  def reduce(amount, source, effects)
      when is_number(amount) and amount >= 0 and amount <= @float_max and is_atom(source) do
    if DamageTypes.known?(source) and PlayerEffects.valid?(effects) do
      amount = f32(amount)

      case effects[@resistance] do
        nil ->
          {:ok, amount}

        [{_, amplifier, _, _, _} | _] ->
          bypass =
            DamageTypes.tag?(source, :bypasses_effects) or
              DamageTypes.tag?(source, :bypasses_resistance)

          {:ok, if(bypass, do: amount, else: scale(amount, amplifier))}
      end
    else
      {:error, :invalid_resistance_damage}
    end
  end

  def reduce(_, _, _), do: {:error, :invalid_resistance_damage}

  defp scale(_amount, amplifier) when amplifier >= 4, do: 0.0

  defp scale(amount, amplifier) do
    factor = 25 - (amplifier + 1) * 5

    case <<amount * factor::float-32>> do
      <<0x7F800000::32>> ->
        # Native overflows to +infinity. Saturate its lethal magnitude for bounded
        # owner health arithmetic; finite native results keep their exact bits.
        @float_max

      <<product::float-32>> ->
        max(0.0, f32(product / 25.0))
    end
  end

  defp f32(number) do
    <<value::float-32>> = <<number::float-32>>
    value
  end
end
