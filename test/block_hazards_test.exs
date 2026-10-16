defmodule Valimc.Physics.BlockHazardsTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.BlockHazards
  @still {0.0, 0.0, 0.0}

  test "magma careful stepping is separate from lit campfire/cactus requests" do
    assert BlockHazards.request(16826, false, true, @still, @still) == {:ok, {:hot_floor, 1.0}}
    assert BlockHazards.request(16826, true, true, @still, @still) == {:ok, nil}
    assert BlockHazards.request(24234, true, true, @still, @still) == {:ok, {:campfire, 1.0}}
    assert BlockHazards.request(24266, false, true, @still, @still) == {:ok, {:campfire, 2.0}}
    assert BlockHazards.request(24238, false, true, @still, @still) == {:ok, nil}
    assert BlockHazards.request(8599, true, true, @still, @still) == {:ok, {:cactus, 1.0}}
  end

  test "mature berries use the authoritative vector and native float-derived boundary" do
    moved = {0.003000000026077032, 0.0, 0.0}
    assert BlockHazards.request(24299, false, true, {0.003, 0, 0}, @still) == {:ok, nil}

    assert BlockHazards.request(24299, false, true, moved, @still) ==
             {:ok, {:sweet_berry_bush, 1.0}}

    assert BlockHazards.request(24299, false, false, moved, @still) == {:ok, nil}

    assert BlockHazards.request(24299, false, false, @still, moved) ==
             {:ok, {:sweet_berry_bush, 1.0}}

    assert BlockHazards.request(24299, false, true, {0, 64, 0}, @still) == {:ok, nil}
    assert BlockHazards.request(24298, false, true, moved, @still) == {:ok, nil}
  end

  test "ordinary states are inert; malformed or unbounded context is refused" do
    assert BlockHazards.request(1, false, true, @still, @still) == {:ok, nil}

    for {state, careful, client, known, previous} <- [
          {35_723, false, true, @still, @still},
          {16826, nil, true, @still, @still},
          {16826, false, :yes, @still, @still},
          {16826, false, true, {65, 0, 0}, @still},
          {16826, false, true, @still, nil}
        ] do
      assert BlockHazards.request(state, careful, client, known, previous) ==
               {:error, :invalid_hazard_context}
    end
  end
end
