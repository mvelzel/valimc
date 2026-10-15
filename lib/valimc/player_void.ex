defmodule Valimc.PlayerVoid do
  @moduledoc "Native below-world damage request from an owned position; cadence/immunity belong to the owner."

  def damage(y, minimum)
      when is_number(y) and abs(y) <= 1_000_000 and is_integer(minimum) and
             abs(minimum) <= 1_000_000,
      do: if(y < minimum - 64, do: 4.0, else: 0.0)
end
