defmodule Valimc.Protocol.EffectTypes do
  @moduledoc "Pinned built-in status-effect identities; catalog entries do not imply gameplay support."
  use Valimc.Facts, "protocol/status_effects.json"
  @names List.to_tuple(@facts["effects"])
  @ids @facts["effects"] |> Enum.with_index() |> Map.new()
  unless tuple_size(@names) == 40 and map_size(@ids) == 40,
    do: raise("Wrong native effect identities")

  def count, do: tuple_size(@names)
  def valid_id?(id), do: is_integer(id) and id >= 0 and id < tuple_size(@names)
  def id("minecraft:" <> _ = name), do: Map.fetch!(@ids, name)
  def id(name) when is_binary(name), do: id("minecraft:" <> name)
  def name(id) when is_integer(id) and id >= 0 and id < tuple_size(@names), do: elem(@names, id)
end
