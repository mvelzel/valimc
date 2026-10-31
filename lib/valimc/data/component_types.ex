defmodule Valimc.Data.ComponentTypes do
  @moduledoc "Pure compiled index of every pinned 26.3 component type, independent of value codecs."
  use Valimc.Data.Facts, "protocol/component_types.json"
  @by_name @facts["components"]
  @by_id Map.new(@by_name, fn {name, id} -> {id, name} end)

  def name(id), do: @by_id[id]
  def id("minecraft:" <> _ = name), do: @by_name[name]
  def id(name) when is_binary(name), do: @by_name["minecraft:" <> name]
  def id(_), do: nil
  def count, do: map_size(@by_name)

  @enums Map.new(@facts["enums"], fn {name, values} ->
           {name, Map.new(values, fn [id, value] -> {id, value} end)}
         end)

  @doc "Stream id => serialized name of a generated component enum (`dye_color`, ...)."
  def enum(name), do: Map.fetch!(@enums, name)
  def names, do: @by_name |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
end
