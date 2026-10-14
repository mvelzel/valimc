defmodule Valimc.Auth.Profile do
  @moduledoc "Bounded native hasJoined identity and opaque signed property values."
  alias Valimc.Auth.HTTP

  def valid_name?(name),
    do: is_binary(name) and Regex.match?(~r/\A[A-Za-z0-9_]{1,16}\z/, name)

  def decode(body, requested_name) when is_binary(body) do
    with true <- byte_size(body) <= HTTP.max_body() and valid_name?(requested_name),
         {%{"id" => id} = value, 0, tail} <- :json.decode(body, 0, decoders()),
         true <- String.trim(tail) == "",
         {:ok, uuid} <- uuid(id),
         {:ok, properties} <- properties(Map.get(value, "properties", [])) do
      {:ok, %{uuid: uuid, name: requested_name, properties: properties}}
    else
      _ -> {:error, :invalid_session_profile}
    end
  rescue
    _ -> {:error, :invalid_session_profile}
  catch
    _, _ -> {:error, :invalid_session_profile}
  end

  def decode(_, _), do: {:error, :invalid_session_profile}

  defp uuid(id) when is_binary(id) do
    if Regex.match?(
         ~r/\A(?:[a-fA-F0-9]{32}|[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12})\z/,
         id
       ) do
      Base.decode16(String.replace(id, "-", ""), case: :mixed)
    else
      :error
    end
  end

  defp uuid(_), do: :error
  defp properties(nil), do: {:ok, []}
  defp properties(:null), do: {:ok, []}

  defp properties(values) when is_list(values) and length(values) <= 16 do
    {:ok,
     Enum.map(values, fn value ->
       %{"name" => name, "value" => content} = value
       true = text?(name, 64) and text?(content, 32_767)
       signature = Map.get(value, "signature")
       true = signature in [nil, :null] or text?(signature, 32_767)
       %{name: name, value: content, signature: if(signature == :null, do: nil, else: signature)}
     end)}
  end

  defp properties(_), do: :error

  defp text?(text, limit),
    do: is_binary(text) and byte_size(text) <= limit and String.valid?(text)

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
