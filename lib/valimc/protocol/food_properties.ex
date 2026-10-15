defmodule Valimc.Protocol.FoodProperties do
  @moduledoc "Bounded native food component values and wire encoding."
  alias Valimc.Protocol.Wire
  @float_max 3.4028234663852886e38

  def valid?(%{nutrition: nutrition, saturation: saturation, can_always_eat: always} = value),
    do:
      map_size(value) == 3 and is_integer(nutrition) and nutrition in 0..2_147_483_647 and
        is_number(saturation) and saturation >= 0 and saturation <= @float_max and
        is_boolean(always)

  def valid?(_), do: false

  def take(bytes) do
    {nutrition, <<saturation::float-32, always, rest::binary>>} = Wire.take_varint(bytes)
    if always not in [0, 1], do: throw({:item_error, :invalid_component_value})
    value = %{nutrition: nutrition, saturation: saturation, can_always_eat: always == 1}
    unless valid?(value), do: throw({:item_error, :invalid_component_value})
    {value, rest}
  end

  def encode(value) do
    unless valid?(value), do: raise(ArgumentError, "invalid food properties")

    [
      Wire.varint(value.nutrition),
      <<value.saturation::float-32>>,
      Wire.bool(value.can_always_eat)
    ]
  end
end
