defmodule Valimc.Protocol.ClientInformation do
  @moduledoc """
  The client's settings (`client_information`, configuration and play), as
  vanilla 26.3's `ClientInformation`: language (at most 16 characters), requested
  view distance (a signed byte), chat visibility, chat colours, skin parts, main
  hand, text filtering, server listing and particles. Only the view distance is
  used so far (VMC-070); the rest is decoded for later slices.
  """
  alias Valimc.Protocol.Wire

  def decode(payload) when is_binary(payload) and byte_size(payload) <= 69 do
    with {:ok, size, rest} when size <= 48 <- Wire.read_varint(payload),
         <<language::binary-size(^size), view_distance::signed-8, rest::binary>> <- rest,
         true <- String.valid?(language) and String.length(language) <= 16,
         {:ok, chat_visibility, <<chat_colors, skin_parts, rest::binary>>} <-
           Wire.read_varint(rest),
         {:ok, main_hand, <<text_filtering, allows_listing, rest::binary>>} <-
           Wire.read_varint(rest),
         {:ok, particles, <<>>} <- Wire.read_varint(rest) do
      {:ok,
       %{
         language: language,
         view_distance: view_distance,
         chat_visibility: chat_visibility,
         chat_colors: chat_colors != 0,
         skin_parts: skin_parts,
         main_hand: main_hand,
         text_filtering: text_filtering != 0,
         allows_listing: allows_listing != 0,
         particles: particles
       }}
    else
      _ -> {:error, :invalid_client_information}
    end
  end

  def decode(_), do: {:error, :invalid_client_information}
end
