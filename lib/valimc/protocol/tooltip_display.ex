defmodule Valimc.Protocol.TooltipDisplay do
  @moduledoc "Bounded vanilla tooltip presentation controls; hidden data remains owned item state."
  alias Valimc.Data.ComponentTypes
  alias Valimc.Protocol.Wire
  defstruct hide: false, hidden: MapSet.new()
  @max_entries 1024

  def max_entries, do: @max_entries

  def valid?(%__MODULE__{hide: hide, hidden: %MapSet{} = hidden}) when is_boolean(hide),
    do:
      MapSet.size(hidden) <= ComponentTypes.count() and
        Enum.all?(
          hidden,
          &(ComponentTypes.id(&1) != nil and ComponentTypes.name(ComponentTypes.id(&1)) == &1)
        )

  def valid?(_), do: false

  def take(<<hide, rest::binary>>) do
    {count, rest} = Wire.take_varint(rest)
    require!(count in 0..@max_entries, :tooltip_count_limit)
    {hidden, rest} = read(rest, count, MapSet.new())
    {%__MODULE__{hide: hide != 0, hidden: hidden}, rest}
  end

  def take(_), do: throw({:tooltip_error, :malformed_tooltip_display})

  def shows?(%__MODULE__{hide: hide, hidden: hidden} = value, name) do
    require!(valid?(value), :invalid_tooltip_display)
    id = ComponentTypes.id(name)
    require!(id != nil, :unknown_hidden_component)
    not hide and not MapSet.member?(hidden, ComponentTypes.name(id))
  end

  def identity_key(%__MODULE__{hide: hide, hidden: hidden} = value) do
    require!(valid?(value), :invalid_tooltip_display)
    {hide, Enum.sort(hidden)}
  end

  def encode(%__MODULE__{hide: hide, hidden: hidden} = value) do
    require!(valid?(value), :invalid_tooltip_display)
    ids = hidden |> Enum.map(&ComponentTypes.id/1) |> Enum.sort()
    [Wire.bool(hide), Wire.varint(length(ids)), Enum.map(ids, &Wire.varint/1)]
  end

  defp read(bytes, 0, hidden), do: {hidden, bytes}

  defp read(bytes, count, hidden) do
    {id, rest} = Wire.take_varint(bytes)
    name = ComponentTypes.name(id)
    require!(name != nil, :unknown_hidden_component)
    read(rest, count - 1, MapSet.put(hidden, name))
  end

  defp require!(true, _), do: :ok
  defp require!(false, reason), do: throw({:tooltip_error, reason})
end
