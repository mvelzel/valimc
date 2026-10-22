defmodule Valimc.Living.Packets do
  @moduledoc "The packets of a living entity's state (VMC-077r): effects, armor and attributes."
  alias Valimc.Protocol.{Packets, Wire}

  def update_effect(entity_id, effect_id, {ticks, level, ambient, particles, icon} = rung, blend) do
    Packets.life_entity_id!(entity_id)

    unless Valimc.Data.EffectTypes.valid_id?(effect_id) and
             Valimc.Living.Effects.valid_instance?([rung]) and
             is_boolean(blend),
           do: raise(ArgumentError, "invalid effect packet")

    flags =
      if(ambient, do: 1, else: 0) + if(particles, do: 2, else: 0) +
        if(icon, do: 4, else: 0) + if(blend, do: 8, else: 0)

    Packets.packet("update_mob_effect", [
      Wire.varint(entity_id),
      Wire.varint(effect_id),
      Wire.varint(level),
      Wire.varint(ticks),
      <<flags>>
    ])
  end

  def armor_break(entity_id, slot) when slot in [:head, :chest, :legs, :feet] do
    Packets.life_entity_id!(entity_id)

    Packets.packet(
      "entity_event",
      <<entity_id::signed-32, Valimc.Living.Armor.break_event(slot)>>
    )
  end

  def interaction_attributes(player) do
    attributes = Valimc.Living.Interaction.attributes(player.game_mode.current)
    Packets.attributes(player.entity_id, attributes)
  end

  def armor_attributes(entity_id, attributes),
    do: Packets.attributes(entity_id, Valimc.Living.Armor.protocol_attributes(attributes))
end
