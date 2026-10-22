defmodule Valimc.Net.Auth.DiscoveryFetch do
  @moduledoc false
  alias Valimc.Net.Auth.{HTTP, DiscoveryDocument}
  @url "https://discovery.minecraftservices.com/minecraft/client"
  def fetch(deadline) do
    case HTTP.get(@url, deadline) do
      {:ok, 200, body} -> DiscoveryDocument.decode(body)
      _ -> {:error, :discovery_unavailable}
    end
  end
end
