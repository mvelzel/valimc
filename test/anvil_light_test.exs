defmodule Valimc.AnvilLightTest do
  @moduledoc "Stored vanilla light of imported chunks (VMC-021e5)."
  use ExUnit.Case, async: true
  alias Valimc.Anvil.Light
  alias Valimc.NBT

  defp root(sections, on \\ 1),
    do:
      {:compound,
       %{"isLightOn" => {:byte, on}, "sections" => NBT.list(Enum.map(sections, &{:compound, &1}))}}

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

    # Masks: sky in section 7 (bit 12), block in section -5 (bit 0); the all-zero
    # sky array of section 3 goes in the empty sky mask (bit 8), as vanilla sends it.
    full = :binary.copy(<<255>>, 2048)

    assert IO.iodata_to_binary(Light.packet(image)) ==
             <<2, 0x00, 0x10, 1, 1, 2, 0x00, 0x01, 0, 1, 0x80, 0x10, full::binary, 1, 0x80, 0x10,
               mixed::binary>>
  end

  test "chunks without valid light keep full sky; damaged images are refused" do
    assert Light.image(root([], 0)) == nil
    assert Light.image(root([%{"Y" => {:byte, 0}, "SkyLight" => {:byte_array, <<1, 2>>}}])) == nil
    refute Light.valid?(<<9>>)
    refute Light.valid?(:binary.copy(<<0>>, 51))
    assert Light.valid?(:binary.copy(<<0>>, 52))
  end
end
