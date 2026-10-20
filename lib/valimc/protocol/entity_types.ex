defmodule Valimc.Protocol.EntityTypes do
  @moduledoc "Immutable entity/metadata facts extracted from the pinned Mojang 26.3 runtime."
  @path Path.expand("../../../priv/protocol/entities.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  unless Valimc.Version.stamped?(@facts, ~w(version protocol server_sha1)),
    do: raise("entity facts do not match the supported protocol")

  def id("minecraft:" <> _ = name), do: Map.fetch!(@facts["types"], name)
  def id(name) when is_binary(name), do: id("minecraft:" <> name)
  def names, do: unquote(Macro.escape(MapSet.new(Map.keys(@facts["types"]))))
  def field(name) when is_atom(name), do: @facts["fields"][Atom.to_string(name)]
  def serializer(name) when is_binary(name), do: Map.fetch!(@facts["serializers"], name)

  @doc "Vanilla's `clientTrackingRange` of a type, in chunks (VMC-070)."
  def tracking_range("minecraft:" <> _ = name), do: Map.fetch!(@facts["tracking_ranges"], name)
  def tracking_range(name) when is_binary(name), do: tracking_range("minecraft:" <> name)
end
