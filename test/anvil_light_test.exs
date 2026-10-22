defmodule Valimc.AnvilLightTest do
  @moduledoc "Light packets from light images (VMC-021e5, VMC-077c)."
  use ExUnit.Case, async: true
  alias Valimc.Storage.Anvil.Light

  # A light image: per section (y -5..20) sky then block, absent unless given.
  defp image(layers) do
    for s <- 0..25, kind <- [:sky, :block], into: <<>> do
      case Map.get(layers, {s, kind}) do
        nil -> <<0>>
        <<byte>> -> <<1, byte>>
        bytes -> <<2, bytes::binary>>
      end
    end
  end

  test "only the image's layers are sent, all-zero ones in the empty masks" do
    mixed = for i <- 0..2047, into: <<>>, do: <<rem(i, 251)>>

    image =
      image(%{{0, :block} => mixed, {8, :sky} => <<0>>, {12, :sky} => <<255>>})

    # Masks: sky in section 7 (bit 12), block in section -5 (bit 0); the all-zero
    # sky array of section 3 goes in the empty sky mask (bit 8), as vanilla sends it.
    full = :binary.copy(<<255>>, 2048)

    assert IO.iodata_to_binary(Light.packet(image)) ==
             <<2, 0x00, 0x10, 1, 1, 2, 0x00, 0x01, 0, 1, 0x80, 0x10, full::binary, 1, 0x80, 0x10,
               mixed::binary>>
  end
end
