defmodule Valimc.Auth.SessionService do
  @moduledoc "Mojang session verification foundation; invoke only in bounded cold workers."
  alias Valimc.Auth.{HTTP, Profile}
  @endpoint "https://sessionserver.mojang.com/session/minecraft/hasJoined"

  def url(name, digest) do
    if Profile.valid_name?(name) and is_binary(digest) and
         Regex.match?(~r/\A-?[0-9a-f]{1,40}\z/, digest) do
      {:ok, @endpoint <> "?" <> URI.encode_query(%{"username" => name, "serverId" => digest})}
    else
      {:error, :invalid_session_request}
    end
  end

  def lookup(name, digest, deadline) do
    with {:ok, url} <- url(name, digest),
         {:ok, status, body} <- HTTP.get(url, deadline) do
      response(status, body, name)
    end
  end

  def response(200, body, name), do: Profile.decode(body, name)
  def response(204, _, _), do: {:error, :unverified_session}
  def response(status, _, _) when status in [401, 403, 404], do: {:error, :unverified_session}
  def response(_, _, _), do: {:error, :session_unavailable}
end
