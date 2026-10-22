defmodule Valimc.Text.Number do
  @moduledoc """
  Java's number formatting (VMC-077o), as vanilla prints numbers in messages:
  `fixed/2` is `String.format(Locale.ROOT, "%.Nf", value)` (the shortest
  decimal digits of the double rounded half up, not Erlang's exact binary
  rounding), `java/2` is `Float.toString` / `Double.toString`.
  """
  alias Valimc.Data.Float32

  @doc """
  `String.format(Locale.ROOT, "%.<decimals>f", value)`: the shortest decimal
  digits of the double rounded half up, keeping the sign of negative values.
  """
  def fixed(value, decimals) when is_float(value) do
    {digits, exponent} = decimal(abs(value))
    shift = exponent + decimals

    scaled =
      if shift >= 0 do
        digits * Integer.pow(10, shift)
      else
        divisor = Integer.pow(10, -shift)
        quotient = div(digits, divisor)
        if rem(digits, divisor) * 2 >= divisor, do: quotient + 1, else: quotient
      end

    text = Integer.to_string(scaled) |> String.pad_leading(decimals + 1, "0")
    {whole, fraction} = String.split_at(text, byte_size(text) - decimals)
    sign = if value < 0 or <<value::float>> == <<-0.0::float>>, do: "-", else: ""
    if decimals == 0, do: sign <> whole, else: sign <> whole <> "." <> fraction
  end

  # Shortest round-trip digits as `{integer, exponent}` (value = integer × 10^exponent).
  defp decimal(value) do
    [mantissa | exponent] = String.split(:erlang.float_to_binary(value, [:short]), ["e", "E"])
    exponent = if exponent == [], do: 0, else: String.to_integer(hd(exponent))

    case String.split(mantissa, ".") do
      [whole, fraction] ->
        {String.to_integer(whole <> fraction), exponent - byte_size(fraction)}

      [whole] ->
        {String.to_integer(whole), exponent}
    end
  end

  @doc "Java's `Float.toString` / `Double.toString` (shortest digits that read back)."
  def java(value, bits) do
    {digits, exponent} = shortest(value, bits)
    sign = if value < 0 or (value == 0 and <<value::float>> == <<-0.0::float>>), do: "-", else: ""
    magnitude = abs(value)

    if magnitude != 0 and (magnitude < 1.0e-3 or magnitude >= 1.0e7) do
      [first | rest] = String.graphemes(digits)
      fraction = if rest == [], do: "0", else: Enum.join(rest)
      "#{sign}#{first}.#{fraction}E#{exponent - 1}"
    else
      sign <> plain(digits, exponent)
    end
  end

  # Digits and decimal exponent (value = 0.digits × 10^exponent).
  defp shortest(value, _bits) when value == 0, do: {"0", 1}

  defp shortest(value, 64) do
    [mantissa, exponent] =
      :erlang.float_to_binary(abs(value), [:short]) |> String.downcase() |> scientific()

    {mantissa, exponent}
  end

  defp shortest(value, 32) do
    magnitude = abs(value)

    Enum.find_value(0..8, fn decimals ->
      text = :erlang.float_to_binary(magnitude, scientific: decimals)
      {parsed, _} = Float.parse(text)
      if Float32.round(parsed) == magnitude, do: scientific(text)
    end)
    |> then(fn [digits, exponent] -> {digits, exponent} end)
  end

  defp scientific(text) do
    {mantissa, exponent} =
      case String.split(text, "e") do
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
        [mantissa] -> {mantissa, 0}
      end

    {int, frac} =
      case String.split(mantissa, ".") do
        [int, frac] -> {int, frac}
        [int] -> {int, ""}
      end

    digits = String.trim_leading(int <> frac, "0")

    exponent =
      exponent + String.length(int) - (String.length(int <> frac) - String.length(digits))

    digits = String.trim_trailing(digits, "0")
    [if(digits == "", do: "0", else: digits), exponent]
  end

  defp plain(digits, exponent) when exponent <= 0,
    do: "0." <> String.duplicate("0", -exponent) <> digits

  defp plain(digits, exponent) do
    length = String.length(digits)

    if exponent >= length,
      do: digits <> String.duplicate("0", exponent - length) <> ".0",
      else: String.slice(digits, 0, exponent) <> "." <> String.slice(digits, exponent..-1//1)
  end
end
