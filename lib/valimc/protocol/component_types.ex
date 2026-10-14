defmodule Valimc.Protocol.ComponentTypes do
  @moduledoc "Pure compiled index of every pinned 26.3 component type, independent of value codecs."
  @path Path.expand("../../../priv/protocol/items.json", __DIR__)
  @external_resource @path
  @by_name :json.decode(File.read!(@path))["components"]
  @by_id Map.new(@by_name, fn {name, id} -> {id, name} end)

  def name(id), do: @by_id[id]
  def id("minecraft:" <> _ = name), do: @by_name[name]
  def id(name) when is_binary(name), do: @by_name["minecraft:" <> name]
  def id(_), do: nil
  def count, do: map_size(@by_name)
  def names, do: @by_name |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
end
