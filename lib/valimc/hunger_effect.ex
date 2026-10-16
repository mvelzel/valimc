defmodule Valimc.HungerEffect do
  @moduledoc "Pure active Hunger exhaustion request; ability gates and food processing stay on the player owner."
  alias Valimc.StatusEffect
  @coefficient 0.004999999888241291

  def request([head | _] = effect) do
    if StatusEffect.valid?(effect) do
      {ticks, amp, _, _, _} = head
      <<amount::float-32>> = <<@coefficient * (amp + 1)::float-32>>
      {:ok, if(ticks == 0, do: :none, else: {:exhaust, amount})}
    else
      {:error, :invalid_hunger_effect}
    end
  end

  def request(_), do: {:error, :invalid_hunger_effect}
end
