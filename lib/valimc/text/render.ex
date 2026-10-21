defmodule Valimc.Text.Render do
  @moduledoc """
  A text component's plain English text (VMC-010f), vanilla's
  `Component.getString()` on the server: literal text, translations from the
  server's English strings (`priv/lang/en_us.json`, the `language` stage) with
  `TranslatableContents`' `%s`, `%1$s` and `%%` formats, and siblings in order.
  Keybinds print their key; scores, selectors and NBT print nothing, as they do
  unresolved. The console prints command feedback with it.
  """
  @key {__MODULE__, :strings}

  defp strings do
    case :persistent_term.get(@key, nil) do
      nil ->
        strings = Valimc.Facts.read!("lang/en_us.json")

        :persistent_term.put(@key, strings)
        strings

      strings ->
        strings
    end
  end

  def string({:compound, fields}) do
    own =
      case fields do
        %{"text" => {:string, text}} -> text
        %{"translate" => {:string, key}} -> translate(key, fields)
        %{"keybind" => {:string, key}} -> key
        _ -> ""
      end

    case fields["extra"] do
      nil -> own
      list -> own <> Enum.map_join(Valimc.NBT.items(list), &string/1)
    end
  end

  def string({:string, text}), do: text
  def string(_), do: ""

  defp translate(key, fields) do
    format =
      case {strings()[key], fields["fallback"]} do
        {nil, {:string, fallback}} -> fallback
        {nil, _} -> key
        {format, _} -> format
      end

    args =
      case fields["with"] do
        nil -> []
        list -> Valimc.NBT.items(list)
      end

    case decompose(format, args) do
      {:ok, parts} -> IO.iodata_to_binary(parts)
      :error -> format
    end
  end

  @pattern ~r/%(?:(\d+)\$)?([A-Za-z%]|$)/

  # `TranslatableContents.decomposeTemplate`: a stray `%`, an unknown format or
  # a missing argument leaves the whole format as it is.
  defp decompose(format, args), do: walk(format, args, 0, 0, [])

  defp walk(format, args, current, next, parts) do
    case Regex.run(@pattern, format, offset: current, return: :index) do
      nil ->
        tail = binary_part(format, current, byte_size(format) - current)
        if String.contains?(tail, "%"), do: :error, else: {:ok, [parts, tail]}

      [{start, length} | groups] ->
        prefix = binary_part(format, current, start - current)
        whole = binary_part(format, start, length)
        [position, type] = Enum.map(groups ++ [nil, nil], &group(format, &1)) |> Enum.take(2)

        cond do
          String.contains?(prefix, "%") ->
            :error

          type == "%" and whole == "%%" ->
            walk(format, args, start + length, next, [parts, prefix, "%"])

          type != "s" ->
            :error

          true ->
            {index, next} =
              if position, do: {String.to_integer(position) - 1, next}, else: {next, next + 1}

            if index >= 0 and index < length(args),
              do:
                walk(format, args, start + length, next, [
                  parts,
                  prefix,
                  argument(Enum.at(args, index))
                ]),
              else: :error
        end
    end
  end

  defp group(_format, nil), do: nil
  defp group(_format, {-1, 0}), do: nil
  defp group(format, {start, length}), do: binary_part(format, start, length)

  defp argument({:compound, _} = component), do: string(component)
  defp argument({:string, text}), do: text

  defp argument({type, value}) when type in [:byte, :short, :int, :long],
    do: Integer.to_string(value)

  defp argument({:float, <<value::float-32>>}), do: Valimc.Text.Number.java(value, 32)
  defp argument({:double, <<value::float-64>>}), do: Valimc.Text.Number.java(value, 64)
  defp argument({:float, bytes}), do: special(bytes)
  defp argument({:double, bytes}), do: special(bytes)
  defp argument(_), do: ""

  defp special(<<0x7F800000::32>>), do: "Infinity"
  defp special(<<0xFF800000::32>>), do: "-Infinity"
  defp special(<<0x7FF0000000000000::64>>), do: "Infinity"
  defp special(<<0xFFF0000000000000::64>>), do: "-Infinity"
  defp special(_), do: "NaN"
end
