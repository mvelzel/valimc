defmodule Valimc.PlayerAbsorption do
  @moduledoc "Pure golden-heart state and effect hooks; the player owner commits and replicates outcomes."
  alias Valimc.{PlayerEffects, StatusEffect}
  alias Valimc.Protocol.EffectTypes
  @absorption EffectTypes.id("absorption")
  @path Path.expand("../../priv/protocol/attributes.json", __DIR__)
  @external_resource @path
  @attribute :json.decode(File.read!(@path))["minecraft:max_absorption"]
  @float_max 3.4028234663852886e38

  def valid?(pool), do: bounded?(pool, 0, @attribute["max"]) and f32(pool) == pool

  def reconcile(player, incoming_amplifier \\ nil) do
    {:ok, derived} = derive(player.effects)
    {:ok, pool} = set(Map.get(player, :absorption, 0.0), derived.maximum)

    pool =
      if incoming_amplifier == nil do
        pool
      else
        {:ok, started} = start(pool, derived.maximum, incoming_amplifier)
        started
      end

    Map.put(player, :absorption, pool)
  end

  def derive(effects, base \\ 0.0) do
    if PlayerEffects.valid?(effects) and bounded?(base, 0, @attribute["max"]) do
      modifiers =
        case effects[@absorption] do
          nil ->
            []

          [{_, amplifier, _, _, _} | _] ->
            [{"minecraft:effect.absorption", (amplifier + 1) * 4.0, 0}]
        end

      value = Enum.reduce(modifiers, base, fn {_, amount, 0}, value -> value + amount end)

      {:ok,
       %{
         attribute: {@attribute["id"], base, modifiers},
         maximum: f32(min(@attribute["max"], value))
       }}
    else
      {:error, :invalid_absorption}
    end
  end

  def set(amount, maximum) do
    if bounded?(amount, -@float_max, @float_max) and bounded?(maximum, 0, @attribute["max"]),
      do: {:ok, min(f32(maximum), max(0.0, f32(amount)))},
      else: {:error, :invalid_absorption}
  end

  @doc "Every accepted application starts its incoming dose, including an unchanged refresh."
  def start(pool, maximum, amplifier) when amplifier in 0..255 do
    if bounded?(pool, 0, @attribute["max"]),
      do: set(max(pool, (amplifier + 1) * 4.0), maximum),
      else: {:error, :invalid_absorption}
  end

  def start(_, _, _), do: {:error, :invalid_absorption}

  @doc "Spend after defenses using native float subtraction, retaining rounding at large damage."
  def spend(pool, damage) do
    if bounded?(pool, 0, @attribute["max"]) and bounded?(damage, 0, @float_max) do
      pool = f32(pool)
      damage = f32(damage)
      remaining = max(0.0, f32(damage - pool))
      consumed = f32(damage - remaining)
      {:ok, %{pool: max(0.0, f32(pool - consumed)), damage: remaining}}
    else
      {:error, :invalid_absorption}
    end
  end

  @doc "A depleted pool ends the whole instance before duration decrement or hidden promotion."
  def tick(effect, pool) do
    if StatusEffect.valid?(effect) and bounded?(pool, 0, @attribute["max"]) do
      if pool > 0, do: StatusEffect.tick(effect), else: {:ok, effect, false, false}
    else
      {:error, :invalid_absorption}
    end
  end

  defp bounded?(value, minimum, maximum),
    do: is_number(value) and value >= minimum and value <= maximum

  defp f32(value) do
    <<result::float-32>> = <<value::float-32>>
    result
  end
end
