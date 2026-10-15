defmodule Valimc.Protocol.UseItem do
  @moduledoc "Bounded native use-item requests; gameplay permission belongs to the player owner."
  alias Valimc.Protocol.Wire

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 10..18 do
    with {:ok, hand, rest} when hand in [0, 1] <- Wire.read_varint(bytes),
         {:ok, sequence, rest} when sequence <= 2_147_483_647 <- Wire.read_varint(rest),
         <<yaw::float-32, pitch::float-32>> <- rest do
      {:ok,
       %{hand: if(hand == 0, do: :main, else: :off), sequence: sequence, yaw: yaw, pitch: pitch}}
    else
      _ -> {:error, :invalid_use_item}
    end
  end

  def decode(_), do: {:error, :invalid_use_item}
end
