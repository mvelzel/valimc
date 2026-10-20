defmodule Valimc.PlayerDeathMessage do
  @moduledoc "Native player death translations; clients select their language."
  @path Path.expand("../../priv/protocol/damage_messages.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @keys @facts["keys"]
  unless Valimc.Version.stamped?(@facts) and
           map_size(@keys) == 17,
         do: raise("Wrong native death message keys")

  @doc "Environmental messages or self magic; the original mainhand selects named-item text."
  def component(name, {:self_magic, held}) do
    plain = component(name, :self_magic)

    case Valimc.Protocol.ItemData.named_display(held) do
      nil ->
        plain

      display ->
        %Valimc.Protocol.ServerText{
          tag:
            {:compound,
             %{
               "translate" => {:string, "death.attack.indirectMagic.item"},
               "with" => Valimc.NBT.list([{:string, name}, {:string, name}, display])
             }}
        }
    end
  end

  def component(name, source)
      when is_binary(name) and byte_size(name) in 1..64 and is_atom(source) do
    unless String.valid?(name), do: raise(ArgumentError, "invalid death name")

    {key, names} =
      if source == :self_magic,
        do: {"death.attack.indirectMagic", [name, name]},
        else: {Map.fetch!(@keys, Atom.to_string(source)), [name]}

    {:compound,
     %{
       "translate" => {:string, key},
       "with" => {:list, {:string, names}}
     }}
  end
end
