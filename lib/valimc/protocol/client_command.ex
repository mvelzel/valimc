defmodule Valimc.Protocol.ClientCommand do
  @moduledoc "Bounded client lifecycle requests; gameplay authorization belongs to the player owner."
  alias Valimc.Protocol.Wire
  @actions %{0 => :respawn, 1 => :stats, 2 => :gamerules}

  def decode(payload) when is_binary(payload) and byte_size(payload) in 1..5 do
    with {:ok, id, <<>>} <- Wire.read_varint(payload),
         action when not is_nil(action) <- @actions[id],
         do: {:ok, action},
         else: (_ -> {:error, :invalid_client_command})
  end

  def decode(_), do: {:error, :invalid_client_command}
end
