defmodule Valimc.Net.Auth.JSON do
  @moduledoc "Bounded untrusted authentication JSON; no atom creation or duplicate keys."
  def decode(body) when is_binary(body) and byte_size(body) <= 65_536 do
    {value, 0, tail} = :json.decode(body, 0, decoders())
    true = Regex.match?(~r/\A[\x20\t\r\n]*\z/, tail)
    {:ok, value}
  rescue
    _ -> {:error, :invalid_auth_json}
  catch
    _, _ -> {:error, :invalid_auth_json}
  end

  def decode(_), do: {:error, :invalid_auth_json}

  defp depth(value) when is_integer(value), do: value
  defp depth({depth, _, _}), do: depth

  defp start(old, initial) do
    next = depth(old) + 1
    if next > 8, do: throw(:json_depth)
    {next, 0, initial}
  end

  defp decoders do
    %{
      object_start: &start(&1, %{}),
      object_push: fn key, value, {depth, count, map} ->
        if count >= 64 or Map.has_key?(map, key), do: throw(:json_object_limit)
        {depth, count + 1, Map.put(map, key, value)}
      end,
      object_finish: fn {_, _, map}, old -> {map, old} end,
      array_start: &start(&1, []),
      array_push: fn value, {depth, count, items} ->
        if count >= 64, do: throw(:json_array_limit)
        {depth, count + 1, [value | items]}
      end,
      array_finish: fn {_, _, items}, old -> {Enum.reverse(items), old} end,
      string: fn text ->
        if byte_size(text) > 32_767, do: throw(:json_string_limit)
        text
      end,
      integer: fn text ->
        if byte_size(text) > 64, do: throw(:json_number_limit)
        String.to_integer(text)
      end,
      float: fn text ->
        if byte_size(text) > 64, do: throw(:json_number_limit)
        :erlang.binary_to_float(text)
      end
    }
  end
end
