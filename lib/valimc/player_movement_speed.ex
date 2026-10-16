defmodule Valimc.PlayerMovementSpeed do
  @moduledoc "Derived player movement speed from owned Speed/Slowness heads and sprint intent."
  alias Valimc.PlayerEffects
  alias Valimc.Protocol.EffectTypes
  @path Path.expand("../../priv/protocol/attributes.json", __DIR__)
  @external_resource @path
  @attribute :json.decode(File.read!(@path))["minecraft:movement_speed"]
  @base 0.10000000149011612
  @effects [
    {EffectTypes.id("speed"), "minecraft:effect.speed", 0.20000000298023224},
    {EffectTypes.id("slowness"), "minecraft:effect.slowness", -0.15000000596046448}
  ]
  @sprint {"minecraft:sprinting", 0.30000001192092896, 2}

  def derive(effects, sprint) when is_boolean(sprint) do
    if PlayerEffects.valid?(effects) do
      modifiers =
        Enum.flat_map(@effects, fn {id, name, coefficient} ->
          case effects[id] do
            nil -> []
            [{_, amplifier, _, _, _} | _] -> [{name, coefficient * (amplifier + 1), 2}]
          end
        end)

      modifiers = if sprint, do: [@sprint | modifiers], else: modifiers
      # Native evaluation order for these three identities; no copied hash table.
      value = Enum.reduce(modifiers, @base, fn {_, amount, 2}, value -> value * (1 + amount) end)
      value = min(@attribute["max"], max(@attribute["min"], value))
      <<travel_speed::float-32>> = <<value::float-32>>

      {:ok,
       %{
         attribute: {@attribute["id"], @base, modifiers},
         value: value,
         travel_speed: travel_speed
       }}
    else
      {:error, :invalid_movement_speed}
    end
  end

  def derive(_, _), do: {:error, :invalid_movement_speed}
end
