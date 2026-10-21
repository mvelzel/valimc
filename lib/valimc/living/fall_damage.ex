defmodule Valimc.Living.FallDamage do
  @moduledoc "Pinned player/entity fall damage arithmetic; owners decide immunity, landing and health effects."
  defstruct safe_distance: 3.0, attribute_multiplier: 1.0, immune: false

  def calculate(distance, material, %__MODULE__{} = facts) do
    # Native pointed dripstone adds 2.5 before calculating a bounded owner fall.
    if bounded?(distance, 0, 60_000_003) and bounded?(material, 0, 4) and
         bounded?(facts.safe_distance, -1024, 1024) and
         bounded?(facts.attribute_multiplier, 0, 100) and is_boolean(facts.immune) do
      <<rounded::float-32>> = <<material::float-32>>
      raw = (distance + 1.0e-6 - facts.safe_distance) * rounded * facts.attribute_multiplier
      # Native calculateFallDamage returns a signed int, even below the threshold.
      # The caller damages only on positive values. Positive int overflow saturates.
      {:ok, if(facts.immune, do: 0, else: min(floor(raw), 2_147_483_647))}
    else
      {:error, :invalid_fall_damage}
    end
  end

  def calculate(_, _, _), do: {:error, :invalid_fall_damage}
  defp bounded?(n, lo, hi), do: is_number(n) and n >= lo and n <= hi
end
