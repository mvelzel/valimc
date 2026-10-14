defmodule Valimc.PlayerInteractionTest do
  use ExUnit.Case, async: true
  alias Valimc.PlayerInteraction, as: Interaction

  test "mode-selected ranges retain native defaults and named transient modifiers" do
    assert Interaction.block_range(:creative) == 5.0
    assert Interaction.entity_range(:creative) == 5.0

    assert Interaction.attributes(:creative) == [
             {8, 4.5, [{"minecraft:creative_mode_block_range", 0.5, 0}]},
             {13, 3.0, [{"minecraft:creative_mode_entity_range", 2.0, 0}]}
           ]

    for mode <- [:survival, :adventure, :spectator] do
      assert Interaction.block_range(mode) == 4.5
      assert Interaction.entity_range(mode) == 3.0
      assert Interaction.attributes(mode) == [{8, 4.5, []}, {13, 3.0, []}]
    end
  end

  test "reach uses nearest box point, strict equality and the native verification buffer" do
    block = {-10, 64, -7}
    assert Interaction.block_distance_squared({-9.5, 64.5, -6.5}, block) == 0.0
    assert Interaction.within_block?(:creative, {-3.000000001, 64.5, -6.5}, block)
    refute Interaction.within_block?(:creative, {-3.0, 64.5, -6.5}, block)
    refute Interaction.within_block?(:creative, {-2.999999999, 64.5, -6.5}, block)
    assert Interaction.within_block?(:creative, {-3.1, 64.5, -6.5}, block)
    refute Interaction.within_block?(:survival, {-3.1, 64.5, -6.5}, block)
    refute Interaction.within_block?(:creative, {-3.1, 64.5, -6.5}, block, 0.0)
    assert Interaction.block_distance_squared({-8.0, 66.0, -5.0}, block) == 3.0

    assert elem(Interaction.standing_eye(%{x: 0.5, y: 64.0, z: 0.5}), 1) ==
             64.0 + 1.6200000047683716
  end

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
