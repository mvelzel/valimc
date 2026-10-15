defmodule Valimc.Physics.LandingBlocksTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{FallDamage, LandingBlocks}

  test "distance reduction and damage multipliers differ at the safe-fall threshold" do
    {:ok, bed} = LandingBlocks.call(2257, 6, false)
    {:ok, hay} = LandingBlocks.call(14741, 6, false)
    {:ok, honey} = LandingBlocks.call(25173, 6, true)
    assert bed == %{distance: 3.0, multiplier: 1.0, source: :fall}
    assert hay == honey
    assert hay.distance == 6.0 and hay.multiplier == 0.20000000298023224
    assert {:ok, 0} = FallDamage.calculate(bed.distance, bed.multiplier, %FallDamage{})
    assert {:ok, 0} = FallDamage.calculate(hay.distance, hay.multiplier, %FallDamage{})

    {:ok, bed} = LandingBlocks.call(2257, 16, false)
    {:ok, hay} = LandingBlocks.call(14741, 16, false)
    assert {:ok, 5} = FallDamage.calculate(bed.distance, bed.multiplier, %FallDamage{})
    assert {:ok, 2} = FallDamage.calculate(hay.distance, hay.multiplier, %FallDamage{})
  end

  test "native slime has zero multiplier without shift and no callback with shift; powder has none" do
    slime = 14379

    assert {:ok, call} = LandingBlocks.call(slime, 64, false)
    assert call == %{distance: 64.0, multiplier: 0.0, source: :fall}

    assert {:ok, nil} = LandingBlocks.call(slime, 64, true)
    assert {:ok, nil} = LandingBlocks.call(30519, 64, false)
    assert {:ok, nil} = LandingBlocks.call(30519, 64, true)
  end

  test "upward dripstone tips have a distinct distance/source rule; all states remain bounded" do
    count = LandingBlocks.state_count()

    tips =
      for id <- 0..(count - 1),
          {:ok, %{source: :stalagmite}} <- [LandingBlocks.call(id, 2, false)],
          do: id

    assert length(tips) == 2

    for id <- tips do
      assert {:ok, %{distance: 4.5, multiplier: 2.0, source: :stalagmite}} =
               LandingBlocks.call(id, 2, true)

      {:ok, call} = LandingBlocks.call(id, 60_000_000, false)

      assert {:ok, 119_999_999} =
               FallDamage.calculate(call.distance, call.multiplier, %FallDamage{})
    end

    for id <- [0, count - 1], do: assert({:ok, _} = LandingBlocks.call(id, 0, false))

    for args <- [
          {-1, 0, false},
          {count, 0, false},
          {1.0, 0, false},
          {1, -1, false},
          {1, 60_000_001, false},
          {1, 1, nil}
        ] do
      assert apply(LandingBlocks, :call, Tuple.to_list(args)) == {:error, :invalid_landing}
    end
  end
end
