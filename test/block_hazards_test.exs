defmodule Valimc.Physics.BlockHazardsTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.BlockHazards
  @still {0.0, 0.0, 0.0}

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
