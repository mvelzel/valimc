defmodule Valimc.Net.Auth.Profile do
  @moduledoc "Bounded native hasJoined identity and opaque signed property values."
  alias Valimc.Net.Auth.{HTTP, JSON}

  def valid_name?(name),
    do: is_binary(name) and Regex.match?(~r/\A[A-Za-z0-9_]{1,16}\z/, name)

  def decode(body, requested_name) when is_binary(body) do
    with true <- byte_size(body) <= HTTP.max_body() and valid_name?(requested_name),
         {:ok, %{"id" => id} = value} <- JSON.decode(body),
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

  def valid?(%{name: name, uuid: uuid, properties: values}, requested_name)
      when is_binary(uuid) and byte_size(uuid) == 16 and is_list(values) and length(values) <= 16 do
    name == requested_name and valid_name?(name) and
      Enum.all?(values, fn
        %{name: key, value: value, signature: signature} ->
          text?(key, 64) and text?(value, 32_767) and
            (signature == nil or text?(signature, 32_767))

        _ ->
          false
      end) and
      Enum.reduce(values, 0, fn p, count ->
        count + byte_size(p.name) + byte_size(p.value) +
          if(p.signature, do: byte_size(p.signature), else: 0)
      end) <= HTTP.max_body()
  end

  def valid?(_, _), do: false

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
end
