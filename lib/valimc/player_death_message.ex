defmodule Valimc.PlayerDeathMessage do
  @moduledoc "Native no-attacker environmental death translations; clients select their language."
  @path Path.expand("../../priv/protocol/damage_messages.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @keys @facts["keys"]
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
           map_size(@keys) == 14,
         do: raise("Wrong native death message keys")

  def component(name, source)
      when is_binary(name) and byte_size(name) in 1..64 and is_atom(source) do
    unless String.valid?(name), do: raise(ArgumentError, "invalid death name")

    {:compound,
     %{
       "translate" => {:string, Map.fetch!(@keys, Atom.to_string(source))},
       "with" => {:list, {:string, [name]}}
     }}
  end
end
