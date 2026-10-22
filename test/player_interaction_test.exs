defmodule Valimc.PlayerInteractionTest do
  use ExUnit.Case, async: true
  alias Valimc.Living.Interaction, as: Interaction

  test "hit locations use native tolerated boundaries in all three translated axes" do
    for block <- [{0, 64, -7}, {-12_345, 64, -7}, {30_000_000, 64, -7}] do
      for hit <- [{0.0, 1.0, 0.0}, {-0.5, 0.5, 0.5}, {1.5, 0.5, 0.5}] do
        assert Interaction.valid_hit?(block, hit)
      end

      for hit <- [{-0.500001, 0.5, 0.5}, {0.5, 1.500001, 0.5}, {0.5, 0.5, 1.500001}] do
        refute Interaction.valid_hit?(block, hit)
      end
    end
  end

  test "non-finite wire hit coordinates are ignored without treating them as malformed frames" do
    for bits <- [0x7FC00000, 0x7F800000, 0xFF800000], axis <- 0..2 do
      values =
        List.replace_at(
          [<<0.5::float-32>>, <<0.5::float-32>>, <<0.5::float-32>>],
          axis,
          <<bits::32>>
        )

      refute Interaction.valid_hit?({0, 64, 0}, IO.iodata_to_binary(values))
    end
  end
end
