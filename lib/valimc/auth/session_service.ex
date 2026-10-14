defmodule Valimc.Auth.SessionService do
  @moduledoc "Mojang session verification foundation; invoke only in bounded cold workers."
  alias Valimc.Auth.{HTTP, Profile, Discovery, DiscoveryDocument}

  def url(name, digest, endpoint) do
    if Profile.valid_name?(name) and is_binary(digest) and
         Regex.match?(~r/\A-?[0-9a-f]{1,40}\z/, digest) and
         DiscoveryDocument.valid_endpoint?(endpoint) do
      uri = URI.parse(endpoint)
      query = URI.encode_query(%{"username" => name, "serverId" => digest})
      query = if uri.query in [nil, ""], do: query, else: uri.query <> "&" <> query
      {:ok, URI.to_string(%{uri | query: query})}
    else
      {:error, :invalid_session_request}
    end
  end

  def lookup(name, digest, deadline) do
    with {:ok, endpoint} <- Discovery.endpoint(deadline),
         {:ok, url} <- url(name, digest, endpoint),
         {:ok, status, body} <- HTTP.get(url, deadline) do
      response(status, body, name)
    end
  end

  def response(200, body, name), do: Profile.decode(body, name)
  def response(204, _, _), do: {:error, :unverified_session}
  def response(status, _, _) when status in [401, 403, 404], do: {:error, :unverified_session}
  def response(_, _, _), do: {:error, :session_unavailable}
end
