defmodule Valimc.LiveEffects do
  @moduledoc """
  The status effects the live game applies, by registry id; others are refused
  (login, commands, consumption).

  Besides the effects with server mechanics ValiMC implements, this holds those
  whose only effect on a server without mobs is to be stored, ticked and sent:
  night vision, blindness and darkness are drawn by the client. Glowing and
  invisibility need replicated entity flags; haste, strength and the like need
  their server mechanics, so they stay out.
  """
  alias Valimc.Protocol.EffectTypes

  @periodic Enum.sort(Enum.map(~w(regeneration hunger poison wither), &EffectTypes.id/1))
  @ids Enum.map(
         ~w(fire_resistance resistance absorption water_breathing speed slowness nausea
            jump_boost slow_falling levitation night_vision blindness darkness),
         &EffectTypes.id/1
       ) ++ @periodic

  def ids, do: @ids
  def periodic, do: @periodic
end
