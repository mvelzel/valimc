defmodule Valimc.Living.DamageSource do
  @moduledoc """
  A damage source (vanilla `DamageSource`): its damage type, decided by the
  generated `damage_type` registry and tags (`Valimc.Data.DamageTypes`),
  and the entities that caused it once combat exists. Rules ask its tags
  (`bypasses_armor`, `is_fire`, ...) rather than listing types; the food
  exhaustion and death message keys come from the pinned facts.
  """
  use Valimc.Data.Facts, "protocol/damage_messages.json"
  alias Valimc.Data.DamageTypes
  @exhaustion Valimc.Living.Armor.exhaustion()
  @messages @facts["keys"]
  unless map_size(@messages) == 18, do: raise("Wrong native death message keys")

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
  def exhaustion(source), do: Map.get(@exhaustion, Atom.to_string(type(source)), 0.0)

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
