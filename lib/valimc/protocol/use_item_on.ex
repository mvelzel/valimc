defmodule Valimc.Protocol.UseItemOn do
  @moduledoc "Bounded block-use decoding; hit, owner and gameplay admission are separate."
  alias Valimc.Protocol.Wire

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 25..37 do
    with {:ok, hand, rest} when hand in [0, 1] <- Wire.read_varint(bytes),
         <<x::signed-26, z::signed-26, y::signed-12, rest::binary>> <- rest,
         {:ok, face, rest} when face in 0..5 <- Wire.read_varint(rest),
         <<cx::float-32, cy::float-32, cz::float-32, inside, border, rest::binary>> <- rest,
         {:ok, sequence, <<>>} when sequence <= 2_147_483_647 <- Wire.read_varint(rest) do
      {:ok,
       %{
         hand: if(hand == 0, do: :main, else: :off),
         position: {x, y, z},
         face: face,
         cursor: {cx, cy, cz},
         inside: inside != 0,
         border: border != 0,
         sequence: sequence
       }}
    else
      _ -> {:error, :invalid_use_item_on}
    end
  end

  def decode(_), do: {:error, :invalid_use_item_on}
end
