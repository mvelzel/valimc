defmodule Valimc.Command.ItemComponents do
  @moduledoc """
  Item component values from command SNBT (VMC-053g), decoded as vanilla's
  component codecs read NBT, into `Valimc.Protocol.ItemStack` values. Only the
  components ValiMC's stacks carry are accepted; others are `:unsupported`.
  """

  @int_max 2_147_483_647

  def decode("minecraft:damage", tag),
    do: int(tag, 0, @int_max, &"Value must be non-negative: #{&1}")

  def decode("minecraft:repair_cost", tag),
    do: int(tag, 0, @int_max, &"Value must be non-negative: #{&1}")

  def decode("minecraft:max_damage", tag),
    do: int(tag, 1, @int_max, &"Value must be positive: #{&1}")

  def decode("minecraft:max_stack_size", tag),
    do: int(tag, 1, 99, &"Value must be within range [1;99]: #{&1}")

  def decode("minecraft:unbreakable", _tag), do: {:ok, :unit}
  def decode("minecraft:enchantment_glint_override", tag), do: bool(tag)

  def decode("minecraft:custom_data", {:compound, _} = tag), do: {:ok, tag}
  def decode("minecraft:custom_data", _tag), do: :unsupported
  def decode(_id, _tag), do: :unsupported

  # `Codec.INT` over `NbtOps`: any number, as Java's `intValue()`.
  defp int(tag, min, max, message) do
    case number(tag) do
      nil -> {:error, "Not a number"}
      value -> if value in min..max, do: {:ok, value}, else: {:error, message.(value)}
    end
  end

  defp bool(tag) do
    case tag do
      {type, value} when type in [:byte, :short, :int, :long] ->
        {:ok, Bitwise.band(value, 0xFF) != 0}

      {:float, <<value::float-32>>} ->
        {:ok, Bitwise.band(trunc(value), 0xFF) != 0}

      {:double, <<value::float-64>>} ->
        {:ok, Bitwise.band(trunc(value), 0xFF) != 0}

      _ ->
        {:error, "Not a number"}
    end
  end

  defp number({type, value}) when type in [:byte, :short, :int], do: value

  defp number({:long, value}) do
    <<int::signed-32>> = <<value::32>>
    int
  end

  defp number({:float, <<value::float-32>>}), do: saturate(value)
  defp number({:double, <<value::float-64>>}), do: saturate(value)
  defp number(_), do: nil

  defp saturate(value), do: value |> trunc() |> max(-2_147_483_648) |> min(@int_max)
end
