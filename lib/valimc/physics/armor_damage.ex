defmodule Valimc.Physics.ArmorDamage do
  @moduledoc "Native armor/toughness reduction without weapon-dependent effects; source tags and wear belong to the owner."
  @float_max 3.4028234663852886e38

  def reduce(amount, armor, toughness)
      when is_number(amount) and amount >= 0 and amount <= @float_max and
             is_number(armor) and armor >= 0 and armor <= 30 and
             is_number(toughness) and toughness >= 0 and toughness <= 20 do
    amount = f32(amount)
    armor = f32(armor)
    divisor = f32(2.0 + f32(f32(toughness) / 4.0))
    effective = min(20.0, max(f32(armor * f32(0.2)), f32(armor - f32(amount / divisor))))
    {:ok, f32(amount * f32(1.0 - f32(effective / 25.0)))}
  end

  def reduce(_, _, _), do: {:error, :invalid_armor_damage}

  defp f32(number) do
    <<value::float-32>> = <<number::float-32>>
    value
  end
end
