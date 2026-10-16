defmodule Valimc.InstantEffect do
  @moduledoc "Native player drink health requests; callers own defenses, health and durable completion."
  import Bitwise
  alias Valimc.Protocol.EffectTypes
  @heal EffectTypes.id("instant_health")
  @harm EffectTypes.id("instant_damage")

  def drink_request(id, amplifier) when id in [@heal, @harm] and amplifier in 0..255 do
    amount = amount(if(id == @heal, do: 4, else: 6), amplifier)
    {:ok, if(id == @heal, do: {:heal, amount}, else: {:hurt, :indirect_magic, amount})}
  end

  def drink_request(_, _), do: {:error, :invalid_instant_effect}

  defp amount(base, amplifier) do
    unsigned = band(bsl(base, band(amplifier, 31)), 0xFFFFFFFF)
    signed = if unsigned >= 0x80000000, do: unsigned - 0x100000000, else: unsigned
    # Native instantaneous delivery rounds a signed int shift using double+0.5,
    # JVM d2i truncation, then casts the request to float (including negatives).
    integer = signed |> Kernel.+(0.5) |> trunc()
    <<result::float-32>> = <<integer::float-32>>
    result
  end
end
