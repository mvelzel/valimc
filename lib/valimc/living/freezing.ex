defmodule Valimc.Living.Freezing do
  @moduledoc """
  A living entity's freezing (vanilla `Entity.ticksFrozen` and powder snow's
  cold damage): contact comes from complete body samples, the counter advances
  on the owner's admitted clock, and a due hit is consumed against a fresh
  sample and current gear.
  """
  alias Valimc.Living.Armor
  defstruct powder_snow: false, frozen_ticks: 0, damage_phase: 0, damage_due: false

  def valid_ticks?(value), do: is_integer(value) and value in 0..140
  def active?(%__MODULE__{} = env), do: env.powder_snow or env.frozen_ticks > 0

  @doc "Advance only on the player's admitted clock; delayed geometry retains at most one consequence."
  def tick(%__MODULE__{} = env, true) do
    phase = rem(env.damage_phase + 1, 40)
    %{env | damage_phase: phase, damage_due: env.damage_due or phase == 0}
  end

  def tick(%__MODULE__{} = env, false), do: %{env | damage_phase: 0, damage_due: false}

  @doc "Consume against a fresh body sample and current gear; body clock phase is deliberately unsaved."
  def consume_damage(%__MODULE__{damage_due: false} = env, _allowed), do: {false, env}

  def consume_damage(%__MODULE__{} = env, allowed) when is_boolean(allowed),
    do: {env.frozen_ticks >= 140 and allowed, %{env | damage_due: false}}

  def freeze_effect(ticks, allowed) when ticks in 0..140 and is_boolean(allowed),
    do: if(allowed, do: min(140, ticks + 1), else: ticks)

  @doc "Whether the entity can freeze: not a spectator and wearing no freeze-immune wearable."
  def can_freeze?(spectator, equipment) when is_boolean(spectator),
    do: not spectator and not Armor.freeze_immune?(equipment)

  def observe(%__MODULE__{} = env, powder, due, immune)
      when is_boolean(powder) and is_boolean(due) and is_boolean(immune) do
    next =
      if due do
        if powder and not immune,
          do: freeze_effect(env.frozen_ticks, true),
          else: max(0, env.frozen_ticks - 2)
      else
        env.frozen_ticks
      end

    %{env | powder_snow: powder, frozen_ticks: next}
  end
end
