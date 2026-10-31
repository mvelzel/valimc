defmodule Valimc.Protocol.PotionContents do
  @moduledoc "Bounded potion component codec, native equality and pure scaled delivery."
  alias Valimc.Data.Float32
  alias Valimc.Data.{EffectTypes, PotionTypes}
  alias Valimc.Protocol.Wire
  @max_custom 64
  @max_rungs 256
  @max_name_bytes 32_767
  @float_max 3.4028234663852886e38
  @int_min -2_147_483_648
  @int_max 2_147_483_647

  def empty, do: %{potion: nil, color: nil, effects: [], name: nil}

  # `PotionContents.BASE_POTION_COLOR`, a water bottle's blue.
  @base_color -13_083_194

  @doc """
  A potion's colour (`PotionContents.getColor`): its custom colour, else its
  visible effects' colours mixed by amplifier (opaque), else water's blue.
  """
  def color(%{color: color}) when is_integer(color), do: color

  def color(contents) do
    effects = effects(contents)

    {r, g, b, count} =
      Enum.reduce(effects, {0, 0, 0, 0}, fn
        {id, [{_, amplifier, _, true, _} | _]}, {r, g, b, count} ->
          color = Valimc.Data.EffectFacts.get(id).color
          weight = amplifier + 1

          {r + weight * Bitwise.band(Bitwise.bsr(color, 16), 255),
           g + weight * Bitwise.band(Bitwise.bsr(color, 8), 255),
           b + weight * Bitwise.band(color, 255), count + weight}

        _, acc ->
          acc
      end)

    if count == 0 do
      @base_color
    else
      argb = 0xFF000000 + div(r, count) * 65_536 + div(g, count) * 256 + div(b, count)
      argb - 0x100000000
    end
  end

  @doc "A stack's potion contents: its own, else its item's default, else none."
  def of(%Valimc.Protocol.ItemStack{} = stack) do
    case Map.fetch(stack.components, "minecraft:potion_contents") do
      {:ok, value} ->
        value

      :error ->
        case Valimc.Protocol.ItemTypes.defaults(stack.item_id).values["minecraft:potion_contents"] do
          nil ->
            empty()

          bytes ->
            {value, <<>>} = take(bytes)
            value
        end
    end
  end

  @doc "A stack's `potion_duration_scale` (a lingering potion's 0.25, a tipped arrow's 0.125)."
  def duration_scale(%Valimc.Protocol.ItemStack{} = stack) do
    case Map.fetch(stack.components, "minecraft:potion_duration_scale") do
      {:ok, scale} when is_number(scale) ->
        scale * 1.0

      _ ->
        case Valimc.Protocol.ItemTypes.defaults(stack.item_id).values[
               "minecraft:potion_duration_scale"
             ] do
          <<scale::float-32>> -> scale
          _ -> 1.0
        end
    end
  end

  def valid?(%{potion: potion, color: color, effects: effects, name: name} = value) do
    map_size(value) == 4 and (potion == nil or PotionTypes.valid_id?(potion)) and
      (color == nil or (is_integer(color) and color in @int_min..@int_max)) and
      (name == nil or
         (is_binary(name) and byte_size(name) <= @max_name_bytes and String.valid?(name))) and
      valid_effects?(effects, @max_custom, @max_rungs)
  end

  def valid?(_), do: false

  def identity_key(value) do
    validate!(value)

    {value.potion, value.color, Enum.map(value.effects, fn {id, rungs} -> {id, hd(rungs)} end),
     value.name}
  end

  def take(bytes) do
    {potion, rest} = take_optional(bytes, &Wire.take_varint/1)
    check(potion == nil or PotionTypes.valid_id?(potion))

    {color, rest} =
      take_optional(rest, fn <<color::signed-32, tail::binary>> -> {color, tail} end)

    {count, rest} = Wire.take_varint(rest)
    check(count <= @max_custom)
    {effects, rest} = take_effects(rest, count, @max_rungs, [])
    {name, rest} = take_optional(rest, &Wire.take_string(&1, @max_name_bytes))
    value = %{potion: potion, color: color, effects: effects, name: name}
    validate!(value)
    {value, rest}
  end

  def encode(value) do
    validate!(value)

    [
      optional(value.potion, &Wire.varint/1),
      optional(value.color, fn color -> <<color::signed-32>> end),
      Wire.varint(length(value.effects)),
      Enum.map(value.effects, fn {id, rungs} -> [Wire.varint(id), details(rungs)] end),
      optional(value.name, &Wire.string/1)
    ]
  end

  @doc "Base effects precede custom effects. Native copying drops suppressed rungs. No gameplay is applied."
  def effects(value, scale \\ 1.0) do
    validate!(value)
    unless valid_scale?(scale), do: raise(ArgumentError, "invalid potion duration scale")
    base = if value.potion == nil, do: [], else: PotionTypes.effects(value.potion)
    scale = Float32.round(scale)

    Enum.map(base ++ value.effects, fn {id, [{ticks, amp, ambient, particles, icon} | _]} ->
      {id, [{scaled_ticks(ticks, scale), amp, ambient, particles, icon}]}
    end)
  end

  defp scaled_ticks(ticks, _) when ticks in [-1, 0], do: ticks
  defp scaled_ticks(ticks, _) when ticks < 0, do: 1

  defp scaled_ticks(ticks, scale) do
    product = Float32.round(ticks) * scale

    if product > @float_max do
      @int_max
    else
      product |> Float32.round() |> floor() |> max(1) |> min(@int_max)
    end
  end

  defp valid_scale?(value), do: is_number(value) and value >= 0 and value <= @float_max

  defp valid_effects?([], _, _), do: true

  defp valid_effects?([{id, rungs} | rest], count, budget) when count > 0 do
    if EffectTypes.valid_id?(id) do
      case rung_budget(rungs, budget) do
        {:ok, remaining} -> valid_effects?(rest, count - 1, remaining)
        :error -> false
      end
    else
      false
    end
  end

  defp valid_effects?(_, _, _), do: false

  defp rung_budget([{ticks, amp, ambient, particles, icon} | rest], budget) when budget > 0 do
    if is_integer(ticks) and ticks in @int_min..@int_max and is_integer(amp) and
         amp in 0..255 and is_boolean(ambient) and is_boolean(particles) and is_boolean(icon) do
      if rest == [], do: {:ok, budget - 1}, else: rung_budget(rest, budget - 1)
    else
      :error
    end
  end

  defp rung_budget(_, _), do: :error

  defp take_optional(<<0, rest::binary>>, _), do: {nil, rest}
  defp take_optional(<<1, rest::binary>>, decoder), do: decoder.(rest)
  defp take_optional(_, _), do: throw({:item_error, :invalid_component_value})
  defp optional(nil, _), do: <<0>>
  defp optional(value, encoder), do: [<<1>>, encoder.(value)]
  defp take_effects(rest, 0, _, acc), do: {Enum.reverse(acc), rest}

  defp take_effects(bytes, count, budget, acc) do
    check(budget > 0)
    {id, rest} = Wire.take_varint(bytes)
    check(EffectTypes.valid_id?(id))
    {rungs, rest, remaining} = take_details(rest, budget)
    take_effects(rest, count - 1, remaining, [{id, rungs} | acc])
  end

  defp take_details(bytes, budget) do
    check(budget > 0)
    {amp, rest} = Wire.take_varint(bytes)
    check(amp <= 255)
    {duration, <<ambient, particles, icon, hidden, rest::binary>>} = Wire.take_varint(rest)
    check(ambient in [0, 1] and particles in [0, 1] and icon in [0, 1] and hidden in [0, 1])
    ticks = if duration > @int_max, do: duration - 4_294_967_296, else: duration
    head = {ticks, amp, ambient == 1, particles == 1, icon == 1}

    if hidden == 0 do
      {[head], rest, budget - 1}
    else
      {tail, rest, remaining} = take_details(rest, budget - 1)
      {[head | tail], rest, remaining}
    end
  end

  defp details([{ticks, amp, ambient, particles, icon} | rest]) do
    [
      Wire.varint(amp),
      Wire.varint(ticks),
      Wire.bool(ambient),
      Wire.bool(particles),
      Wire.bool(icon),
      if(rest == [], do: <<0>>, else: [<<1>>, details(rest)])
    ]
  end

  defp validate!(value), do: check(valid?(value))
  defp check(true), do: :ok
  defp check(false), do: throw({:item_error, :invalid_component_value})
end
