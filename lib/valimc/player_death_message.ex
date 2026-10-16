defmodule Valimc.PlayerDeathMessage do
  @moduledoc "Native player death translations; clients select their language."
  @path Path.expand("../../priv/protocol/damage_messages.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @keys @facts["keys"]
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
           map_size(@keys) == 16,
         do: raise("Wrong native death message keys")

  @doc "Environmental messages or self magic with an unnamed mainhand; named-item messages are separate."
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
