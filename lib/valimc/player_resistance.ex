defmodule Valimc.PlayerResistance do
  @moduledoc "Native source-tagged Resistance reduction on a validated player effect map, before enchantments."
  alias Valimc.PlayerEffects
  alias Valimc.Protocol.{Data, EffectTypes}
  @path Path.expand("../../priv/protocol/tags.json", __DIR__)
  @external_resource @path
  @tags :json.decode(File.read!(@path))["minecraft:damage_type"]
  @sources Data.registries()["minecraft:damage_type"]
           |> Enum.with_index()
           |> Map.new(fn {name, id} ->
             {name |> String.replace_prefix("minecraft:", "") |> String.to_atom(), id}
           end)
  @bypass @tags["minecraft:bypasses_effects"] ++ @tags["minecraft:bypasses_resistance"]
  @resistance EffectTypes.id("resistance")
  @float_max 3.4028234663852886e38

  def reduce(amount, source, effects)
      when is_number(amount) and amount >= 0 and amount <= @float_max and is_atom(source) do
    if Map.has_key?(@sources, source) and PlayerEffects.valid?(effects) do
      amount = f32(amount)

      case effects[@resistance] do
        nil ->
          {:ok, amount}

        [{_, amplifier, _, _, _} | _] ->
          {:ok, if(@sources[source] in @bypass, do: amount, else: scale(amount, amplifier))}
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
