defmodule Valimc.Data.Version do
  @moduledoc """
  The pinned Minecraft release: name, data version, protocol and server jar SHA-1,
  generated into `priv/version.json` by `VersionMetadata`. Generated fact files
  carry the same stamps; their modules check them with `stamped?/2` at compile time.
  """
  @path Path.expand("../../../priv/version.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @stamps %{
    "version" => @facts["minecraft"],
    "data_version" => @facts["data_version"],
    "protocol" => @facts["protocol"],
    "server_sha1" => @facts["server_sha1"]
  }
  unless is_binary(@stamps["version"]) and is_integer(@stamps["data_version"]) and
           is_integer(@stamps["protocol"]) and byte_size(@stamps["server_sha1"]) == 40,
         do: raise("Invalid pinned version facts")

  def minecraft, do: unquote(@stamps["version"])
  def data_version, do: unquote(@stamps["data_version"])
  def protocol, do: unquote(@stamps["protocol"])
  def server_sha1, do: unquote(@stamps["server_sha1"])

  @doc "True when generated `facts` carry this release's value for each stamp key."
  def stamped?(facts, keys \\ ~w(version data_version server_sha1)) when is_map(facts),
    do: Enum.all?(keys, &(Map.fetch(facts, &1) == Map.fetch(@stamps, &1)))
end
