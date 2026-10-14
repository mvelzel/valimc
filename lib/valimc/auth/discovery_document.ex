defmodule Valimc.Auth.DiscoveryDocument do
  @moduledoc "Bounded SESSION/verify routing from Mojang's production discovery document."
  alias Valimc.Auth.JSON

  def decode(body) do
    with {:ok, %{} = doc} <- JSON.decode(body) do
      validate_schema(doc)

      if doc["environment"] == "offline" do
        {:ok, nil}
      else
        endpoint =
          doc
          |> object("discovery")
          |> object("session")
          |> object("endpoints")
          |> object("verify")

        uri = endpoint["uri"]
        if valid_endpoint?(uri), do: {:ok, uri}, else: {:ok, nil}
      end
    else
      _ -> {:error, :invalid_discovery}
    end
  rescue
    _ -> {:error, :invalid_discovery}
  end

  def valid_endpoint?(uri) when is_binary(uri) and byte_size(uri) <= 2048 do
    %URI{scheme: scheme, host: host, userinfo: userinfo, fragment: fragment} =
      parsed = URI.parse(uri)

    scheme == "https" and userinfo == nil and fragment == nil and
      is_binary(host) and Regex.match?(~r/\A[A-Za-z0-9.-]+\z/, host) and
      parsed.port in 1..65_535 and not Regex.match?(~r/[\x00-\x20\x7F]/, uri)
  end

  def valid_endpoint?(_), do: false

  # Authlib deserializes known fields before checking offline/route availability.
  # Malformed metadata or unused services must be a failed fetch, not a new cache.
  defp validate_schema(doc) do
    for key <- ["environment", "product"], do: primitive(doc[key])
    discovery = object(doc, "discovery")

    for name <- ["authentication", "session", "player", "profiles", "telemetry"] do
      service = object(discovery, name)

      for {_, value} <- object(service, "endpoints") do
        case value do
          nil ->
            :ok

          :null ->
            :ok

          %{} = endpoint ->
            primitive(endpoint["uri"])

            case endpoint["validUris"] do
              nil -> :ok
              :null -> :ok
              values when is_list(values) -> Enum.each(values, &primitive/1)
              _ -> raise ArgumentError, "invalid endpoint URI list"
            end

          _ ->
            raise ArgumentError, "invalid endpoint object"
        end
      end
    end
  end

  defp primitive(value)
       when is_binary(value) or is_number(value) or value in [nil, :null, true, false], do: :ok

  defp primitive(_), do: raise(ArgumentError, "invalid discovery text")

  defp object(map, key) do
    case Map.get(map, key) do
      nil -> %{}
      :null -> %{}
      %{} = value -> value
      _ -> raise ArgumentError, "invalid discovery object"
    end
  end

  def retry_delay(loaded, failures) do
    if loaded, do: 86_400_000, else: 60_000 * Integer.pow(2, min(failures, 6))
  end
end
