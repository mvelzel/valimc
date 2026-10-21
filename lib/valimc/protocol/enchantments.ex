defmodule Valimc.Protocol.Enchantments do
  @moduledoc "Bounded 26.3 enchantment maps using the negotiated core-pack holder IDs."
  alias Valimc.Protocol.Wire
  @names Valimc.Protocol.Data.registries()["minecraft:enchantment"]
  @by_id @names |> Enum.with_index() |> Map.new(fn {name, id} -> {id, name} end)
  @by_name @names |> Enum.with_index() |> Map.new()
  @max_entries 1024

  def names, do: @names
  def id(name), do: @by_name[name]
  def name(id), do: @by_id[id]
  def max_entries, do: @max_entries

  def valid?(values) when is_map(values) and map_size(values) <= map_size(@by_name),
    do:
      Enum.all?(values, fn {name, level} ->
        Map.has_key?(@by_name, name) and is_integer(level) and level in 0..255
      end)

  def valid?(_), do: false

  def take(bytes) do
    {count, rest} = Wire.take_varint(bytes)
    require!(count in 0..@max_entries, :enchantment_count_limit)
    {values, rest} = read(rest, count, %{})
    # Mojang validates final values after map decoding; overwritten levels do not survive.
    require!(valid?(values), :invalid_enchantment_level)
    {values, rest}
  end

  def encode(values) do
    require!(valid?(values), :invalid_enchantments)
    ordered = Enum.sort_by(values, fn {name, _} -> Map.fetch!(@by_name, name) end)

    [
      Wire.varint(map_size(values)),
      Enum.map(ordered, fn {name, level} ->
        [Wire.varint(Map.fetch!(@by_name, name)), Wire.varint(level)]
      end)
    ]
  end

  defp read(bytes, 0, values), do: {values, bytes}

  defp read(bytes, count, values) do
    {id, rest} = Wire.take_varint(bytes)
    name = @by_id[id]
    require!(name != nil, :unknown_enchantment)
    {level, rest} = Wire.take_varint(rest)
    read(rest, count - 1, Map.put(values, name, level))
  end

  defp require!(true, _), do: :ok
  defp require!(false, reason), do: throw({:enchantment_error, reason})
end
