defmodule Valimc.Protocol.ServerText do
  @moduledoc "Server-authored components may compose admitted data into item hovers."
  @enforce_keys [:tag]
  defstruct [:tag]

  def encode(%__MODULE__{tag: tag}), do: Valimc.Data.NBT.encode_server_component(tag)
end
