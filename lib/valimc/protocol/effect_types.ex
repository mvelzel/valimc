defmodule Valimc.Protocol.EffectTypes do
  @moduledoc "Pinned built-in status-effect identities; catalog entries do not imply gameplay support."
  @path Path.expand("../../../priv/protocol/status_effects.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @names List.to_tuple(@facts["effects"])
  @ids @facts["effects"] |> Enum.with_index() |> Map.new()
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
           tuple_size(@names) == 40 and map_size(@ids) == 40,
         do: raise("Wrong native effect identities")

  def count, do: tuple_size(@names)
  def valid_id?(id), do: is_integer(id) and id >= 0 and id < tuple_size(@names)
  def id("minecraft:" <> _ = name), do: Map.fetch!(@ids, name)
  def id(name) when is_binary(name), do: id("minecraft:" <> name)
  def name(id) when is_integer(id) and id >= 0 and id < tuple_size(@names), do: elem(@names, id)
end
