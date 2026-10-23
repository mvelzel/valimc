defmodule Valimc.Living.DamageSource do
  @moduledoc """
  A damage source (vanilla `DamageSource`): its damage type, decided by the
  generated `damage_type` registry and tags (`Valimc.Protocol.DamageTypes`),
  and the entities that caused it once combat exists. Rules ask its tags
  (`bypasses_armor`, `is_fire`, ...) rather than listing types; the food
  exhaustion, difficulty scaling and death message keys come from the pinned
  facts (`DamageMessageOracle`).
  """
  use Valimc.Data.Facts, "protocol/damage_messages.json"
  alias Valimc.Protocol.DamageTypes
  @messages @facts["keys"]
  @types @facts["types"]
  unless map_size(@messages) == 21 and Map.keys(@types) == Map.keys(@messages),
    do: raise("Wrong native death message keys")

  defstruct [:type, causing: nil, direct: nil]

  @doc "A source of damage type `type` (an atom such as `:in_fire`); an unknown type raises."
  def new(%__MODULE__{} = source), do: source

  def new(type) when is_atom(type) do
    DamageTypes.id(type)
    %__MODULE__{type: type}
  end

  def type(%__MODULE__{type: type}), do: type
  def type(type) when is_atom(type), do: type

  def known?(%__MODULE__{type: type}), do: DamageTypes.known?(type)
  def known?(type) when is_atom(type), do: DamageTypes.known?(type)
  def known?(_), do: false

  @doc "Whether the source's damage type has tag `tag` (an unknown tag raises)."
  def is?(source, tag), do: DamageTypes.tag?(type(source), tag)

  def id(source), do: DamageTypes.id(type(source))

  @doc "Armor applies (and wears) unless the type bypasses it."
  def wears_armor?(source), do: not is?(source, :bypasses_armor)

  @doc "Food exhaustion a player takes from a hit of this type."
  def exhaustion(source), do: get_in(@types, [Atom.to_string(type(source)), "exhaustion"]) || 0.0

  @doc """
  Whether a player's damage of this source scales with the difficulty
  (`DamageSource.scalesWithDifficulty`): always, or when a living entity that
  is not a player caused it (no source has a causing entity yet).
  """
  def scales_with_difficulty?(source) do
    case get_in(@types, [Atom.to_string(type(source)), "scaling"]) do
      "always" -> true
      _ -> false
    end
  end

  @doc "Death message text naming `name`: environmental, or self magic naming the held item."
  def death_message(name, {:self_magic, held}) do
    plain = death_message(name, :self_magic)

    case Valimc.Protocol.ItemData.named_display(held) do
      nil ->
        plain

      display ->
        %Valimc.Protocol.ServerText{
          tag:
            {:compound,
             %{
               "translate" => {:string, "death.attack.indirectMagic.item"},
               "with" => Valimc.Data.NBT.list([{:string, name}, {:string, name}, display])
             }}
        }
    end
  end

  def death_message(name, source)
      when is_binary(name) and byte_size(name) in 1..64 and is_atom(source) do
    unless String.valid?(name), do: raise(ArgumentError, "invalid death name")

    {key, names} =
      if source == :self_magic,
        do: {"death.attack.indirectMagic", [name, name]},
        else: {Map.fetch!(@messages, Atom.to_string(source)), [name]}

    {:compound,
     %{
       "translate" => {:string, key},
       "with" => {:list, {:string, names}}
     }}
  end
end
