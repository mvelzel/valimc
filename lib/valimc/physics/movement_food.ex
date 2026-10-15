defmodule Valimc.Physics.MovementFood do
  @moduledoc "Native travel exhaustion requests; the owner supplies accepted deltas and contact predicates."

  def amount({x, y, z}, contact)
      when is_number(x) and abs(x) <= 60_000_000 and is_number(y) and abs(y) <= 2_000_000 and
             is_number(z) and abs(z) <= 60_000_000 do
    cond do
      contact.passenger or (x == 0 and y == 0 and z == 0) -> 0.0
      contact.swimming or contact.underwater -> distance(x, y, z, f32(0.01))
      contact.water -> distance(x, 0.0, z, f32(0.01))
      contact.climbing -> 0.0
      contact.grounded and contact.sprinting -> distance(x, 0.0, z, f32(0.1))
      true -> 0.0
    end
  end

  defp distance(x, y, z, factor) do
    rounded = min(2_147_483_647, floor(f32(f32(:math.sqrt(x * x + y * y + z * z)) * 100.0) + 0.5))
    f32(f32(factor * f32(rounded)) * f32(0.01))
  end

  defp f32(number) do
    <<value::float-32>> = <<number::float-32>>
    value
  end
end
