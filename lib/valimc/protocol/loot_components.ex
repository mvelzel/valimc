defmodule Valimc.Protocol.LootComponents do
  @moduledoc """
  Item components container loot writes (VMC-072a) beyond those ValiMC held
  before: suspicious stew effects, goat horn instruments and map decorations.
  Stew effects and instruments travel on the network (effect registry ids,
  instrument holders as id + 1); map decorations are persistent only, as in
  vanilla, so they never reach the network.

  Values: stew effects are `[{effect, duration}]`, an instrument is its
  identifier, map decorations are `[{key, type, x, z, rotation}]` sorted by key.
  """
  alias Valimc.NBT
  alias Valimc.Protocol.{EffectTypes, Wire}

  @path Path.expand("../../../priv/protocol/registries.json", __DIR__)
  @external_resource @path
  @instruments :json.decode(File.read!(@path))["minecraft:instrument"]
  @instrument_ids @instruments |> Enum.with_index() |> Map.new()
  @max_entries 256
  # `SuspiciousStewEffects.Entry`'s default duration, left out when written.
  @default_duration 160

  def instruments, do: @instruments

  ## Stew effects

  def valid_stew?(effects) when is_list(effects) and length(effects) <= @max_entries,
    do:
      Enum.all?(effects, fn
        {"minecraft:" <> _ = effect, duration} when is_integer(duration) ->
          duration in -2_147_483_648..2_147_483_647 and effect_id(effect) != nil

        _ ->
          false
      end)

  def valid_stew?(_), do: false

  def encode_stew(effects) do
    [
      Wire.varint(length(effects)),
      Enum.map(effects, fn {effect, duration} ->
        [Wire.varint(EffectTypes.id(effect)), Wire.varint(duration)]
      end)
    ]
  end

  def take_stew(bytes) do
    {count, rest} = Wire.take_varint(bytes)
    unless count in 0..@max_entries, do: throw({:item_error, :invalid_component_value})

    {effects, rest} =
      Enum.reduce(1..count//1, {[], rest}, fn _, {acc, rest} ->
        {id, rest} = Wire.take_varint(rest)
        unless EffectTypes.valid_id?(id), do: throw({:item_error, :invalid_component_value})
        {duration, rest} = Wire.take_varint(rest)
        {[{EffectTypes.name(id), signed(duration)} | acc], rest}
      end)

    {Enum.reverse(effects), rest}
  end

  def stew_tag(effects) do
    NBT.list(
      Enum.map(effects, fn {effect, duration} ->
        fields = %{"id" => {:string, effect}}

        {:compound,
         if(duration == @default_duration,
           do: fields,
           else: Map.put(fields, "duration", {:int, duration})
         )}
      end)
    )
  end

  def stew_from_tag({:list, {:end, []}}), do: []

  def stew_from_tag({:list, {:compound, entries}}) do
    Enum.map(entries, fn entry ->
      {:string, effect} = entry["id"]

      duration =
        case entry["duration"] do
          nil -> @default_duration
          {:int, duration} -> duration
        end

      {qualified(effect), duration}
    end)
  end

  ## Instruments

  def valid_instrument?(name), do: Map.has_key?(@instrument_ids, name)
  def encode_instrument(name), do: Wire.varint(Map.fetch!(@instrument_ids, name) + 1)

  def take_instrument(bytes) do
    {holder, rest} = Wire.take_varint(bytes)
    # A direct instrument (holder 0) is not held.
    name = holder > 0 && Enum.at(@instruments, holder - 1)
    unless name, do: throw({:item_error, :invalid_component_value})
    {name, rest}
  end

  ## Map decorations

  def valid_decorations?(list) when is_list(list) and length(list) <= @max_entries,
    do:
      list == Enum.sort_by(list, &elem(&1, 0)) and
        Enum.all?(list, fn
          {key, type, x, z, rotation} ->
            is_binary(key) and is_binary(type) and is_float(x) and is_float(z) and
              is_float(rotation)

          _ ->
            false
        end)

  def valid_decorations?(_), do: false

  def decorations_key(list), do: :erlang.term_to_binary(list)

  def decorations_tag(list) do
    {:compound,
     Map.new(list, fn {key, type, x, z, rotation} ->
       {key,
        {:compound,
         %{
           "type" => {:string, type},
           "x" => NBT.double(x),
           "z" => NBT.double(z),
           "rotation" => NBT.float(rotation)
         }}}
     end)}
  end

  def decorations_from_tag({:compound, entries}) do
    entries
    |> Enum.map(fn {key, {:compound, fields}} ->
      {:string, type} = fields["type"]
      {key, qualified(type), number(fields["x"]), number(fields["z"]), number(fields["rotation"])}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp number({:double, <<value::float-64>>}), do: value
  defp number({:float, <<value::float-32>>}), do: value
  defp number({type, value}) when type in [:byte, :short, :int, :long], do: value * 1.0

  defp effect_id(name) do
    EffectTypes.id(name)
  rescue
    _ -> nil
  end

  defp signed(n) when n >= 2_147_483_648, do: n - 4_294_967_296
  defp signed(n), do: n

  defp qualified("minecraft:" <> _ = name), do: name
  defp qualified(name), do: if(String.contains?(name, ":"), do: name, else: "minecraft:" <> name)
end
