defmodule Valimc.Protocol.PotionTypes do
  @moduledoc "Pinned potion holders and delivery facts; catalog entries do not imply gameplay support."
  @path Path.expand("../../../priv/protocol/potions.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @potions @facts["potions"] |> Enum.sort_by(& &1["id"]) |> List.to_tuple()
  @ids Map.new(@facts["potions"], &{&1["name"], &1["id"]})
  @effects Map.new(@facts["potions"], fn row ->
             {row["id"],
              Enum.map(row["effects"], fn effect ->
                {effect["id"], Enum.map(effect["rungs"], &List.to_tuple/1)}
              end)}
           end)
  unless Valimc.Version.stamped?(@facts) and
           Enum.map(Tuple.to_list(@potions), & &1["id"]) == Enum.to_list(0..45) and
           map_size(@ids) == 46,
         do: raise("Wrong native potion facts")

  def count, do: tuple_size(@potions)
  def valid_id?(id), do: is_integer(id) and id >= 0 and id < tuple_size(@potions)
  def id("minecraft:" <> _ = name), do: Map.fetch!(@ids, name)
  def id(name) when is_binary(name), do: id("minecraft:" <> name)

  def name(id) when is_integer(id) and id >= 0 and id < tuple_size(@potions),
    do: elem(@potions, id)["name"]

  def effects(id), do: Map.fetch!(@effects, id)
end
