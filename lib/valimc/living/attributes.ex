defmodule Valimc.Living.Attributes do
  @moduledoc """
  Attributes a living entity derives from its active effects (vanilla
  `AttributeMap` with the modifiers `MobEffect`s add): movement speed, safe
  fall distance and jump power, gravity and the fall reset of travel effects,
  maximum absorption, and the attributes only effects modify (maximum health,
  luck). Derived values carry the protocol form
  `{id, base, modifiers}` for replication. Only active (head) amplifiers matter,
  never durations.
  """
  alias Valimc.Data.Float32
  use Valimc.Data.Facts, "protocol/attributes.json"
  import Bitwise
  alias Valimc.Living.Effects
  alias Valimc.Data.EffectTypes

  @movement @facts["minecraft:movement_speed"]
  @safe_fall @facts["minecraft:safe_fall_distance"]
  @max_absorption @facts["minecraft:max_absorption"]
  @base_speed 0.10000000149011612
  @speed_effects [
    {EffectTypes.id("speed"), "minecraft:effect.speed", 0.20000000298023224},
    {EffectTypes.id("slowness"), "minecraft:effect.slowness", -0.15000000596046448}
  ]
  @sprint {"minecraft:sprinting", 0.30000001192092896, 2}
  @jump_boost EffectTypes.id("jump_boost")
  @slow_falling EffectTypes.id("slow_falling")
  @levitation EffectTypes.id("levitation")
  @absorption EffectTypes.id("absorption")
  @attack_speed @facts["minecraft:attack_speed"]
  # Native total-multiplier evaluation order, established by AttackSpeedOracle.
  @attack_effects [
    {EffectTypes.id("mining_fatigue"), "minecraft:effect.mining_fatigue", -0.10000000149011612},
    {EffectTypes.id("haste"), "minecraft:effect.haste", 0.10000000149011612}
  ]

  @doc "An attribute's registry facts (`id`, `default`, `min`, `max`) by name without namespace."
  def fetch(name), do: Map.fetch!(@facts, "minecraft:" <> name)
  def max_absorption, do: @max_absorption["max"]

  @doc """
  An attribute's value (`AttributeInstance.calculateValue`): `base` plus the
  additions, plus the base-multiplied additions of that sum, times each total
  multiplier, clamped to the attribute's range. `name` is namespaced;
  `modifiers` are `{id, amount, operation}`.
  """
  def value("minecraft:" <> name, base, modifiers) do
    fact = fetch(name)

    added =
      Enum.reduce(modifiers, base, fn {_, amount, op}, acc ->
        if op == 0, do: acc + amount, else: acc
      end)

    result =
      Enum.reduce(modifiers, added, fn {_, amount, op}, acc ->
        if op == 1, do: acc + added * amount, else: acc
      end)

    result =
      Enum.reduce(modifiers, result, fn {_, amount, op}, acc ->
        if op == 2, do: acc * (1.0 + amount), else: acc
      end)

    min(fact["max"], max(fact["min"], result))
  end

  @doc "The active amplifier of effect `id`, or nil."
  def amplifier(effects, id) do
    case effects[id] do
      nil -> nil
      [{_, amplifier, _, _, _} | _] -> amplifier
    end
  end

  @doc "Held-weapon and effect attack speed, shared by server strength and the client attribute."
  def attack_speed(mainhand, effects) do
    if Effects.valid?(effects) do
      name = "minecraft:attack_speed"
      base = Valimc.Living.Weapons.player_base(name)

      weapon =
        for {^name, id, amount, op} <- Valimc.Living.Weapons.modifiers(mainhand, :mainhand),
            do: {id, amount, op}

      modifiers =
        weapon ++
          Enum.flat_map(@attack_effects, fn {id, name, coefficient} ->
            case amplifier(effects, id) do
              nil -> []
              level -> [{name, coefficient * (level + 1), 2}]
            end
          end)

      {:ok,
       %{attribute: {@attack_speed["id"], base, modifiers}, value: value(name, base, modifiers)}}
    else
      {:error, :invalid_attack_speed}
    end
  end

  # ---- movement speed ----

  @doc "What the movement speed depends on: Speed and Slowness amplifiers and sprinting."
  def movement_signature(effects, sprinting),
    do: {Enum.map(@speed_effects, fn {id, _, _} -> amplifier(effects, id) end), sprinting}

  @doc "Movement speed from Speed, Slowness and sprinting, in native modifier order."
  def movement_speed(effects, sprint) when is_boolean(sprint) do
    if Effects.valid?(effects) do
      modifiers =
        Enum.flat_map(@speed_effects, fn {id, name, coefficient} ->
          case amplifier(effects, id) do
            nil -> []
            amp -> [{name, coefficient * (amp + 1), 2}]
          end
        end)

      modifiers = if sprint, do: [@sprint | modifiers], else: modifiers

      value =
        Enum.reduce(modifiers, @base_speed, fn {_, amount, 2}, value -> value * (1 + amount) end)

      value = min(@movement["max"], max(@movement["min"], value))
      travel_speed = Float32.round(value)

      {:ok,
       %{
         attribute: {@movement["id"], @base_speed, modifiers},
         value: value,
         travel_speed: travel_speed
       }}
    else
      {:error, :invalid_movement_speed}
    end
  end

  def movement_speed(_, _), do: {:error, :invalid_movement_speed}

  # ---- jump boost ----

  def jump_boost_level(effects), do: amplifier(effects, @jump_boost) || -1

  @doc "Jump Boost's safe fall distance attribute and jump bonus."
  def jump_boost(effects) do
    if Effects.valid?(effects) do
      amplifier = jump_boost_level(effects)

      modifiers =
        if amplifier < 0,
          do: [],
          else: [{"minecraft:effect.jump_boost", (amplifier + 1) * 1.0, 0}]

      {:ok,
       %{
         attribute: {@safe_fall["id"], 3.0, modifiers},
         safe_distance: 3.0 + if(amplifier < 0, do: 0, else: amplifier + 1),
         bonus: jump_bonus(amplifier)
       }}
    else
      {:error, :invalid_jump_boost}
    end
  end

  @doc "The native bonus is added after the material factor, with float32 rounding at each step."
  def jump_power(factor, amplifier)
      when is_number(factor) and factor >= 0 and factor <= 4 and
             is_integer(amplifier) and amplifier >= -1 and amplifier <= 255,
      do:
        {:ok,
         Float32.round(
           Float32.round(Float32.round(0.42) * Float32.round(factor)) + jump_bonus(amplifier)
         )}

  def jump_power(_, _), do: {:error, :invalid_jump_boost}
  defp jump_bonus(-1), do: 0.0
  defp jump_bonus(amplifier), do: Float32.round(Float32.round(0.1) * (amplifier + 1))

  # ---- travel effects ----

  @doc "What air travel depends on: Slow Falling's presence and Levitation's amplifier."
  def travel_signature(effects),
    do: {Map.has_key?(effects, @slow_falling), amplifier(effects, @levitation)}

  @doc "Whether travel effects reset the fall distance (before travel geometry is acquired)."
  def resets_fall?(effects) do
    {slow, levitation} = travel_signature(effects)
    slow or levitation != nil
  end

  @doc "Gravity and Levitation at the native gravity selection point."
  def travel(effects, velocity_y) do
    if Effects.valid?(effects) and is_number(velocity_y) and abs(velocity_y) <= 64 do
      {slow, levitation} = travel_signature(effects)
      {:ok, gravity} = gravity(0.08, velocity_y, slow)
      {:ok, %{gravity: gravity, levitation: levitation, reset_fall: slow or levitation != nil}}
    else
      {:error, :invalid_travel_effects}
    end
  end

  def gravity(base, velocity_y, slow)
      when is_number(base) and base >= -1 and base <= 1 and
             is_number(velocity_y) and abs(velocity_y) <= 64 and is_boolean(slow),
      do: {:ok, if(slow and velocity_y <= 0, do: min(0.01, base), else: base)}

  def gravity(_, _, _), do: {:error, :invalid_travel_effects}

  # ---- absorption ----

  def absorption_level(effects), do: amplifier(effects, @absorption)

  @doc "Maximum absorption from the Absorption effect."
  def absorption(effects, base \\ 0.0) do
    if Effects.valid?(effects) and is_number(base) and base >= 0 and
         base <= @max_absorption["max"] do
      modifiers =
        case absorption_level(effects) do
          nil -> []
          amplifier -> [{"minecraft:effect.absorption", (amplifier + 1) * 4.0, 0}]
        end

      value = Enum.reduce(modifiers, base, fn {_, amount, 0}, value -> value + amount end)

      {:ok,
       %{
         attribute: {@max_absorption["id"], base, modifiers},
         maximum: Float32.round(min(@max_absorption["max"], value))
       }}
    else
      {:error, :invalid_absorption}
    end
  end

  # ---- attributes only effects modify ----

  @doc """
  An attribute only effects modify (Health Boost's `minecraft:max_health`,
  Luck and Bad Luck's `minecraft:luck`): `base` with each active effect's
  generated modifiers (`MobEffect.addAttributeModifiers`), in effect order.
  """
  def effect_attribute(effects, "minecraft:" <> _ = name, base) when is_float(base) do
    if Effects.valid?(effects) do
      modifiers =
        for {id, [{_, amplifier, _, _, _} | _]} <- Enum.sort(effects),
            {^name, modifier, amount, op} <-
              Valimc.Data.HostileFacts.effect_modifiers(EffectTypes.name(id), amplifier),
            do: {modifier, amount, op}

      {:ok,
       %{attribute: {@facts[name]["id"], base, modifiers}, value: value(name, base, modifiers)}}
    else
      {:error, :invalid_effect_attribute}
    end
  end

  @doc "A player's maximum health under Health Boost (`getMaxHealth`, a float)."
  def max_health(effects) do
    {:ok, derived} = effect_attribute(effects, "minecraft:max_health", 20.0)
    Float32.round(derived.value)
  end

  @doc "A player's luck under Luck and Bad Luck (`getLuck`, a float)."
  def luck(effects) do
    {:ok, derived} = effect_attribute(effects, "minecraft:luck", 0.0)
    Float32.round(derived.value)
  end

  @doc "Whether a protocol input's sprint flag is set."
  def sprinting?(shared_flags), do: (shared_flags &&& 8) != 0
end
