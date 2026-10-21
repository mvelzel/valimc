defmodule Valimc.Admin.ListFile do
  @moduledoc """
  Vanilla's server list files (VMC-010a): `ops.json`, `whitelist.json`,
  `banned-players.json`, `banned-ips.json` and `usercache.json`.

  Files are written the way vanilla's Gson writes them (two-space indent,
  HTML-safe escapes, absent fields omitted) and replaced atomically. Dates use
  vanilla's `yyyy-MM-dd HH:mm:ss Z` in the server's local time zone. Entry
  order is ValiMC's own; vanilla keeps hash order, which carries no meaning.
  """

  @doc "Reads a JSON array of objects; a missing or unreadable file is `:missing`."
  def read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, entries} when is_list(entries) <- JSON.decode(text) do
      {:ok, Enum.filter(entries, &is_map/1)}
    else
      _ -> :missing
    end
  end

  @doc "Writes entries (lists of `{key, value}` in field order) pretty-printed: `:ok` or `{:error, _}`."
  def write(path, entries), do: Valimc.DurableFile.write(path, pretty(entries))

  @doc "Writes entries on one line, as vanilla's name cache does."
  def write_compact(path, entries) do
    body = Enum.map_join(entries, ",", &object(&1, ","))
    Valimc.DurableFile.write(path, "[" <> body <> "]")
  end

  def pretty([]), do: "[]"

  def pretty(entries) do
    body =
      Enum.map_join(entries, ",\n", fn fields ->
        "  {\n" <>
          Enum.map_join(fields, ",\n", fn {key, value} ->
            "    " <> string(key) <> ": " <> value(value)
          end) <>
          "\n  }"
      end)

    "[\n" <> body <> "\n]"
  end

  defp object(fields, separator),
    do:
      "{" <>
        Enum.map_join(fields, separator, fn {key, value} -> string(key) <> ":" <> value(value) end) <>
        "}"

  defp value(value) when is_binary(value), do: string(value)
  defp value(value) when is_boolean(value), do: to_string(value)
  defp value(value) when is_integer(value), do: Integer.to_string(value)

  # Gson's HTML-safe string escapes.
  defp string(text) do
    escaped =
      for <<char::utf8 <- text>>, into: "" do
        case char do
          ?" ->
            "\\\""

          ?\\ ->
            "\\\\"

          ?\n ->
            "\\n"

          ?\r ->
            "\\r"

          ?\t ->
            "\\t"

          ?\b ->
            "\\b"

          ?\f ->
            "\\f"

          char when char in [?<, ?>, ?&, ?=, ?'] or char < 0x20 or char in [0x2028, 0x2029] ->
            "\\u" <> String.pad_leading(String.downcase(Integer.to_string(char, 16)), 4, "0")

          char ->
            <<char::utf8>>
        end
      end

    "\"" <> escaped <> "\""
  end

  # ---- UUIDs ----

  defdelegate uuid_string(uuid), to: Valimc.UUID, as: :to_string
  defdelegate parse_uuid(text), to: Valimc.UUID, as: :parse

  # ---- dates ----

  @doc "Now in vanilla's list date format, with the local numeric offset."
  def now_text, do: format(System.os_time(:second))

  def format(unix) do
    {date, time} = :calendar.system_time_to_local_time(unix, :second)
    utc = :calendar.system_time_to_universal_time(unix, :second)

    offset =
      div(
        :calendar.datetime_to_gregorian_seconds({date, time}) -
          :calendar.datetime_to_gregorian_seconds(utc),
        60
      )

    {{y, mo, d}, {h, mi, s}} = {date, time}
    sign = if offset < 0, do: "-", else: "+"

    :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B ~s~2..0B~2..0B", [
      y,
      mo,
      d,
      h,
      mi,
      s,
      sign,
      div(abs(offset), 60),
      rem(abs(offset), 60)
    ])
    |> IO.iodata_to_binary()
  end

  @doc "Parses a list date to Unix seconds, or `:error`."
  def parse_date(text) when is_binary(text) do
    with [_, y, mo, d, h, mi, s, sign, oh, om] <-
           Regex.run(
             ~r/\A(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})\z/,
             text
           ),
         [y, mo, d, h, mi, s, oh, om] =
           Enum.map([y, mo, d, h, mi, s, oh, om], &String.to_integer/1),
         true <- :calendar.valid_date(y, mo, d) do
      local = :calendar.datetime_to_gregorian_seconds({{y, mo, d}, {h, mi, s}})
      offset = (oh * 60 + om) * 60 * if(sign == "-", do: -1, else: 1)
      {:ok, local - offset - :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})}
    else
      _ -> :error
    end
  end

  def parse_date(_), do: :error
end
