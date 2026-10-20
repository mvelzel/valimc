defmodule Valimc.AnvilLightTest do
  @moduledoc "Stored vanilla light of imported chunks (VMC-021e5)."
  use ExUnit.Case, async: true
  import Bitwise
  alias Valimc.Anvil.Light
  alias Valimc.NBT
  alias Valimc.Protocol.Wire

  defp root(sections, on \\ 1),
    do:
      {:compound,
       %{"isLightOn" => {:byte, on}, "sections" => NBT.list(Enum.map(sections, &{:compound, &1}))}}

  test "without stored light a chunk is fully sky-lit, as flat chunks have always been" do
    full = (1 <<< 26) - 1

    assert IO.iodata_to_binary(Light.packet(nil)) ==
             IO.iodata_to_binary([
               <<4, full::little-32, 0, 0, 4, full::little-32, 26>>,
               List.duplicate([Wire.varint(2048), :binary.copy(<<255>>, 2048)], 26),
               <<0>>
             ])
  end

  test "stored arrays are sent for exactly their sections" do
    mixed = for i <- 0..2047, into: <<>>, do: <<rem(i, 251)>>

    image =
      Light.image(
        root([
          %{"Y" => {:byte, -5}, "BlockLight" => {:byte_array, mixed}},
          %{"Y" => {:byte, 3}, "SkyLight" => {:byte_array, :binary.copy(<<0>>, 2048)}},
          %{"Y" => {:byte, 7}, "SkyLight" => {:byte_array, :binary.copy(<<255>>, 2048)}},
          %{"Y" => {:byte, 30}, "SkyLight" => {:byte_array, mixed}}
        ])
      )

    assert Light.valid?(image)
    # Uniform arrays are kept as one byte.
    assert byte_size(image) < 2 * 26 + 2048 + 10

    # Masks: sky in sections 3 and 7 (bits 8 and 12), block in section -5 (bit 0).
    zeros = :binary.copy(<<0>>, 2048)
    full = :binary.copy(<<255>>, 2048)

    assert IO.iodata_to_binary(Light.packet(image)) ==
             <<2, 0x00, 0x11, 1, 1, 0, 0, 2, 0x80, 0x10, zeros::binary, 0x80, 0x10, full::binary,
               1, 0x80, 0x10, mixed::binary>>
  end

  test "chunks without valid light keep full sky; damaged images are refused" do
    assert Light.image(root([], 0)) == nil
    assert Light.image(root([%{"Y" => {:byte, 0}, "SkyLight" => {:byte_array, <<1, 2>>}}])) == nil
    refute Light.valid?(<<9>>)
    refute Light.valid?(:binary.copy(<<0>>, 51))
    assert Light.valid?(:binary.copy(<<0>>, 52))
  end
end
