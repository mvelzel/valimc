defmodule Valimc.Data.UUID do
  @moduledoc """
  UUIDs as vanilla writes and reads them (VMC-077o): `to_string/1` is Java's
  `UUID.toString`, `parse/1` its `UUID.fromString` (selectors, list files).
  """
  import Bitwise

  @doc "The dashed lower-case form of a 16-byte UUID."
  def to_string(<<a::32, b::16, c::16, d::16, e::48>>),
    do: Enum.map_join([{a, 8}, {b, 4}, {c, 4}, {d, 4}, {e, 12}], "-", &hex_digits/1)

  defp hex_digits({value, digits}),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(digits, "0")

  @doc "Java `UUID.fromString`: five hex groups split by four dashes, each at most 16 digits."
  def parse(text) when is_binary(text) do
    with parts when length(parts) == 5 <- String.split(text, "-"),
         true <- String.length(text) <= 36,
         [a, b, c, d, e] <- Enum.map(parts, &hex/1),
         true <- Enum.all?([a, b, c, d, e], &is_integer/1) do
      most =
        bor(
          bsl(band(a, 0xFFFFFFFF), 32),
          bor(bsl(band(b, 0xFFFF), 16), band(c, 0xFFFF))
        )

      least =
        bor(bsl(band(d, 0xFFFF), 48), band(e, 0xFFFFFFFFFFFF))

      {:ok, <<most::64, least::64>>}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  defp hex(""), do: nil

  defp hex(text) do
    {sign, digits} =
      case text do
        "-" <> rest -> {-1, rest}
        "+" <> rest -> {1, rest}
        _ -> {1, text}
      end

    with true <- digits != "" and Regex.match?(~r/\A[0-9a-fA-F]+\z/, digits),
         value = sign * String.to_integer(digits, 16),
         true <- value in -0x8000000000000000..0x7FFFFFFFFFFFFFFF do
      value
    else
      _ -> nil
    end
  end
end
