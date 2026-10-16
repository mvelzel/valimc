defmodule Valimc.PlayerJumpBoost do
  @moduledoc "Owned Jump Boost heads derive native jump power and safe-fall distance; no clock or state."
  alias Valimc.PlayerEffects
  alias Valimc.Protocol.EffectTypes
  @id EffectTypes.id("jump_boost")
  @path Path.expand("../../priv/protocol/attributes.json", __DIR__)
  @external_resource @path
  @attribute :json.decode(File.read!(@path))["minecraft:safe_fall_distance"]

  def level(effects) do
    case effects[@id] do
      nil -> -1
      [{_, amplifier, _, _, _} | _] -> amplifier
    end
  end

  def derive(effects) do
    if PlayerEffects.valid?(effects) do
      amplifier = level(effects)

      modifiers =
        if amplifier < 0,
          do: [],
          else: [{"minecraft:effect.jump_boost", (amplifier + 1) * 1.0, 0}]

      {:ok,
       %{
         attribute: {@attribute["id"], 3.0, modifiers},
         safe_distance: 3.0 + if(amplifier < 0, do: 0, else: amplifier + 1),
         bonus: bonus(amplifier)
       }}
    else
      {:error, :invalid_jump_boost}
    end
  end

  @doc "The native bonus is added after the material factor, with float32 rounding at each step."
  def power(factor, amplifier)
      when is_number(factor) and factor >= 0 and factor <= 4 and
             is_integer(amplifier) and amplifier >= -1 and amplifier <= 255,
      do: {:ok, f32(f32(f32(0.42) * f32(factor)) + bonus(amplifier))}

  def power(_, _), do: {:error, :invalid_jump_boost}
  defp bonus(-1), do: 0.0
  defp bonus(amplifier), do: f32(f32(0.1) * (amplifier + 1))

  defp f32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end
end
