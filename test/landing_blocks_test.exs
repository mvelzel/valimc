defmodule Valimc.Physics.LandingBlocksTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{FallDamage, LandingBlocks}

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
