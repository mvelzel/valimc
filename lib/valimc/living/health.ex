defmodule Valimc.Living.Health do
  @moduledoc """
  Health, its hurt timers and the golden-heart absorption pool of a living
  entity (vanilla `LivingEntity`). Damage selection (the hurt window), defenses
  and application are separate steps; the owner commits and replicates.
  """
  alias Valimc.Living.{Attributes, Effects}
  @float_max 3.4028234663852886e38
  @max_absorption Attributes.max_absorption()
  defstruct value: 20.0, maximum: 20.0, hurt_ticks: 0, death_ticks: 0, cooldown: 0, last_hurt: 0.0

  def valid?(%__MODULE__{} = state),
    do:
      canonical?(state.maximum, 1, 1024) and canonical?(state.value, 0, state.maximum) and
        is_integer(state.hurt_ticks) and state.hurt_ticks in 0..32767 and
        is_integer(state.death_ticks) and state.death_ticks in 0..32767 and
        is_integer(state.cooldown) and state.cooldown in 0..20 and
        canonical?(state.last_hurt, 0, @float_max)

  def valid?(_), do: false

  @doc "Advance hurt/cooldown once on the owner's admitted logical tick."
  def tick(%__MODULE__{} = state),
    do: %{
      state
      | hurt_ticks: max(0, state.hurt_ticks - 1),
        cooldown: max(0, state.cooldown - 1),
        death_ticks:
          if(state.value <= 0, do: min(20, state.death_ticks + 1), else: state.death_ticks)
    }

  def set(%__MODULE__{} = state, value) do
    if valid?(state) and bounded?(value, -@float_max, @float_max),
      do: {:ok, %{state | value: clamp(f32(value), 0.0, f32(state.maximum))}},
      else: {:error, :invalid_health}
  end

  @doc "Native float healing, including signed requests, without reviving the dead."
  def heal(%__MODULE__{} = state, amount) do
    if valid?(state) and bounded?(amount, -@float_max, @float_max) do
      if state.value > 0,
        do: set(state, f32(state.value + f32(amount))),
        else: {:ok, state}
    else
      {:error, :invalid_health}
    end
  end

  @doc "Select damage after blocking, before armor/absorption and owner commit."
  def hurt_window(%__MODULE__{} = state, amount, bypass_cooldown \\ false) do
    if valid?(state) and bounded?(amount, -@float_max, @float_max) and is_boolean(bypass_cooldown) do
      amount = max(0.0, f32(amount))
      protected = state.cooldown > 10 and not bypass_cooldown

      cond do
        state.value <= 0 or (protected and amount <= state.last_hurt) ->
          {:ok, %{state: state, accepted: false, damage: 0.0, notify: false}}

        protected ->
          {:ok,
           %{
             state: %{state | last_hurt: amount},
             accepted: true,
             damage: f32(amount - state.last_hurt),
             notify: false
           }}

        true ->
          {:ok,
           %{
             state: %{state | last_hurt: amount, cooldown: 20, hurt_ticks: 10},
             accepted: true,
             damage: amount,
             notify: true
           }}
      end
    else
      {:error, :invalid_health}
    end
  end

  @doc "Apply already-resolved damage; invulnerability, armor, absorption and death belong to the caller."
  def reduce(%__MODULE__{} = state, amount) do
    if valid?(state) and bounded?(amount, 0, @float_max),
      do: set(state, f32(state.value - f32(amount))),
      else: {:error, :invalid_health}
  end

  def saved(%__MODULE__{} = state) do
    if valid?(state),
      do:
        {:ok,
         %{value: f32(state.value), hurt_ticks: state.hurt_ticks, death_ticks: state.death_ticks}},
      else: {:error, :invalid_health}
  end

  def valid_saved?(%{value: value, hurt_ticks: hurt, death_ticks: death}),
    do:
      canonical?(value, 0, 1024) and is_integer(hurt) and hurt in 0..32767 and
        is_integer(death) and death in 0..32767

  def valid_saved?(_), do: false

  def restore(saved, maximum \\ 20.0)

  def restore(nil, maximum) do
    if bounded?(maximum, 1, 1024),
      do: {:ok, %__MODULE__{maximum: f32(maximum), value: f32(maximum)}},
      else: {:error, :invalid_health}
  end

  def restore(%{value: value, hurt_ticks: hurt, death_ticks: death} = saved, maximum) do
    if bounded?(maximum, 1, 1024) and valid_saved?(saved),
      do:
        set(
          %__MODULE__{maximum: f32(maximum), value: 0.0, hurt_ticks: hurt, death_ticks: death},
          value
        ),
      else: {:error, :invalid_health}
  end

  def restore(_, _), do: {:error, :invalid_health}

  # ---- absorption (golden hearts) ----

  def valid_absorption?(pool), do: bounded?(pool, 0, @max_absorption) and f32(pool) == pool

  @doc "Clamp the pool to the effects' maximum; `incoming` starts a newly applied dose's amplifier."
  def reconcile_absorption(pool, effects, incoming \\ nil) do
    {:ok, derived} = Attributes.absorption(effects)
    {:ok, pool} = set_absorption(pool, derived.maximum)

    if incoming == nil do
      pool
    else
      {:ok, started} = start_absorption(pool, derived.maximum, incoming)
      started
    end
  end

  def set_absorption(amount, maximum) do
    if bounded?(amount, -@float_max, @float_max) and bounded?(maximum, 0, @max_absorption),
      do: {:ok, min(f32(maximum), max(0.0, f32(amount)))},
      else: {:error, :invalid_absorption}
  end

  @doc "Every accepted application starts its incoming dose, including an unchanged refresh."
  def start_absorption(pool, maximum, amplifier) when amplifier in 0..255 do
    if bounded?(pool, 0, @max_absorption),
      do: set_absorption(max(pool, (amplifier + 1) * 4.0), maximum),
      else: {:error, :invalid_absorption}
  end

  def start_absorption(_, _, _), do: {:error, :invalid_absorption}

  @doc "Spend after defenses using native float subtraction, retaining rounding at large damage."
  def spend_absorption(pool, damage) do
    if bounded?(pool, 0, @max_absorption) and bounded?(damage, 0, @float_max) do
      pool = f32(pool)
      damage = f32(damage)
      remaining = max(0.0, f32(damage - pool))
      consumed = f32(damage - remaining)
      {:ok, %{pool: max(0.0, f32(pool - consumed)), damage: remaining}}
    else
      {:error, :invalid_absorption}
    end
  end

  @doc "A depleted pool ends the whole Absorption instance before duration decrement or promotion."
  def tick_absorption(effect, pool) do
    if Effects.valid_instance?(effect) and bounded?(pool, 0, @max_absorption) do
      if pool > 0, do: Effects.tick_instance(effect), else: {:ok, effect, false, false}
    else
      {:error, :invalid_absorption}
    end
  end

  defp clamp(value, lo, hi), do: min(max(value, lo), hi)
  defp bounded?(n, lo, hi), do: is_number(n) and n >= lo and n <= hi
  defp canonical?(n, lo, hi), do: bounded?(n, lo, hi) and f32(n) == n

  defp f32(n) do
    <<value::float-32>> = <<n::float-32>>
    value
  end
end
