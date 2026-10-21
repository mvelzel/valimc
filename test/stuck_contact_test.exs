defmodule Valimc.Physics.StuckContactTest do
  use ExUnit.Case, async: true
  alias Valimc.World.View
  alias Valimc.Physics.{CollisionContext, StuckContact}

  defp frame(changes) do
    air = for x <- -2..6, y <- 61..70, z <- -2..2, into: %{}, do: {{x, y, z}, 0}
    View.of(Map.merge(air, changes))
  end

  defp context(y, fall \\ 5.0),
    do: CollisionContext.entity(y) |> CollisionContext.with_entity(fall, false, false)

  test "missing observations fail, while flight/spectator cannot create an effect" do
    from = {0.5, 64.0, 0.5}
    to = {3.5, 64.0, 0.5}
    f = frame(%{})
    f = %{f | supplied: Map.delete(f.supplied, {1, 64, 0})}

    assert {:error, :incomplete_stuck_frame} =
             StuckContact.sample(f, from, to, context(64.0), %StuckContact{feet: to})

    assert {:error, :invalid_stuck_context} =
             StuckContact.sample(f, from, to, CollisionContext.empty(), %StuckContact{feet: to})

    for facts <- [%StuckContact{flying: true}, %StuckContact{spectator: true}] do
      {:ok, effect} =
        StuckContact.sample(
          View.of(%{}),
          from,
          to,
          context(64.0),
          facts
        )

      assert effect.multiplier == nil and effect.last == nil and not effect.reset_fall
    end
  end
end
